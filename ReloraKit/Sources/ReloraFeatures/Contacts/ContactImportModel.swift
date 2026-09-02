import Foundation
import ReloraCore

/// A phone contact, reduced to the five things Relora imports.
///
/// Ports `ImportablePhoneContact` (apps/mobile/src/features/contacts/contactBulkImport.ts).
/// Kept free of `Contacts.framework` types so the matching rules below can be
/// tested without a device contact store.
public struct ImportablePhoneContact: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var phoneNumbers: [String]
    public var emails: [String]
    public var company: String?
    public var jobTitle: String?

    public init(
        id: String,
        name: String,
        phoneNumbers: [String] = [],
        emails: [String] = [],
        company: String? = nil,
        jobTitle: String? = nil
    ) {
        self.id = id
        self.name = name
        self.phoneNumbers = phoneNumbers
        self.emails = emails
        self.company = company
        self.jobTitle = jobTitle
    }
}

public enum BulkImportDecision: String, Equatable, Sendable {
    case skip
    case importAsNew
}

public enum DuplicateReason: Equatable, Sendable {
    case phone
    case email
    case phoneAndEmail

    /// Wording for the review row. Ports `formatDuplicateReason`.
    public var phrase: String {
        switch self {
        case .phone: return "phone"
        case .email: return "email"
        case .phoneAndEmail: return "phone and email"
        }
    }
}

public struct BulkImportReviewItem: Equatable, Sendable, Identifiable {
    public var sourceContactID: String
    public var draft: NormalizedContactDraft
    public var duplicateMatch: Contact?
    public var duplicateReason: DuplicateReason?
    public var defaultDecision: BulkImportDecision

    public var id: String { sourceContactID }
}

public struct BulkImportPreparation: Equatable, Sendable {
    public var reviewItems: [BulkImportReviewItem]
    /// Selected contacts with no usable name. They cannot be imported and are
    /// counted rather than silently dropped.
    public var skippedInvalidCount: Int
}

public struct BulkImportSummary: Equatable, Sendable {
    public var importedCount: Int = 0
    public var skippedDuplicateCount: Int = 0
    public var skippedInvalidCount: Int = 0
    public var failedCount: Int = 0

    public init(
        importedCount: Int = 0,
        skippedDuplicateCount: Int = 0,
        skippedInvalidCount: Int = 0,
        failedCount: Int = 0
    ) {
        self.importedCount = importedCount
        self.skippedDuplicateCount = skippedDuplicateCount
        self.skippedInvalidCount = skippedInvalidCount
        self.failedCount = failedCount
    }
}

/// Everything about importing phone contacts that does not touch a database or
/// the Contacts framework.
///
/// Ports `contactImport.ts` and `contactBulkImport.ts`.
public enum ContactImportModel {
    /// 50 per run. Ports `MAX_BULK_IMPORT_CONTACTS`.
    ///
    /// The cap is a product decision, not a technical one: an unbounded import
    /// turns Relora into an address book, which is the thing it is deliberately
    /// not. Fifty is enough for the people you actually keep notes about.
    public static let maxBulkImportContacts = 50

    // MARK: Draft mapping

    /// Turns a phone contact into a Relora draft.
    ///
    /// Ports `mapImportedContactToDraft`. Descriptors come from the job title
    /// and company, in that order of preference, because "Designer at Figma" is
    /// the sentence a person would actually say about a contact.
    public static func draft(from contact: ImportablePhoneContact) -> ContactDraft {
        let company = (contact.company ?? "").trimmed
        let jobTitle = (contact.jobTitle ?? "").trimmed

        let descriptors: String
        if !company.isEmpty && !jobTitle.isEmpty {
            descriptors = "\(jobTitle) at \(company)"
        } else {
            descriptors = jobTitle.isEmpty ? company : jobTitle
        }

        let phone = contact.phoneNumbers.first { !$0.trimmed.isEmpty }?.trimmed ?? ""
        let email = contact.emails.first { !$0.trimmed.isEmpty }?.trimmed.lowercased() ?? ""

        return ContactDraft(
            name: contact.name.trimmed,
            descriptors: descriptors,
            phoneNumber: phone,
            email: email
        )
    }

    // MARK: Duplicate matching

    /// Digits only. Ports `normalizePhone` (`/\D+/g`).
    ///
    /// Crude on purpose: it is what makes "+1 (555) 010-9999" and "5550109999"
    /// the same person. It also makes two different country codes collide, which
    /// is why a match is a *review prompt* and never an automatic merge.
    public static func normalizePhone(_ value: String?) -> String {
        (value ?? "").filter(\.isNumber)
    }

    /// Ports `normalizeEmail`.
    public static func normalizeEmail(_ value: String?) -> String {
        (value ?? "").trimmed.lowercased()
    }

    /// Finds the existing contact a draft probably already is.
    ///
    /// Ports `findDuplicateMatch`. Matches on phone **or** email, only when the
    /// normalized value is non-empty — two contacts with no phone number are not
    /// duplicates of each other — and when several match, keeps the most
    /// recently updated one, which is the row the user has touched last.
    public static func findDuplicate(
        for draft: NormalizedContactDraft,
        in existing: [Contact]
    ) -> (match: Contact, reason: DuplicateReason)? {
        let draftPhone = normalizePhone(draft.phoneNumber)
        let draftEmail = normalizeEmail(draft.email)

        guard !draftPhone.isEmpty || !draftEmail.isEmpty else {
            return nil
        }

        var best: (match: Contact, reason: DuplicateReason)?

        for contact in existing where contact.deletedAt == nil {
            let phoneMatches = !draftPhone.isEmpty && normalizePhone(contact.phoneNumber) == draftPhone
            let emailMatches = !draftEmail.isEmpty && normalizeEmail(contact.email) == draftEmail

            let reason: DuplicateReason?
            switch (phoneMatches, emailMatches) {
            case (true, true): reason = .phoneAndEmail
            case (true, false): reason = .phone
            case (false, true): reason = .email
            case (false, false): reason = nil
            }

            guard let reason else { continue }

            if let current = best, current.match.updatedAt >= contact.updatedAt {
                continue
            }
            best = (contact, reason)
        }

        return best
    }

    // MARK: Preparation

    /// Builds the review step: one row per selected contact that has a name,
    /// each pre-decided.
    ///
    /// Ports `prepareBulkContactImport`. A duplicate defaults to Skip: the safe
    /// default when the app is unsure is to not create a second copy of someone.
    public static func prepare(
        selected: [ImportablePhoneContact],
        existing: [Contact]
    ) -> BulkImportPreparation {
        var reviewItems: [BulkImportReviewItem] = []
        var skippedInvalidCount = 0

        for contact in selected {
            let draft = draft(from: contact)
            guard let normalized = try? ContactEditForm.normalize(draft) else {
                skippedInvalidCount += 1
                continue
            }

            let duplicate = findDuplicate(for: normalized, in: existing)
            reviewItems.append(
                BulkImportReviewItem(
                    sourceContactID: contact.id,
                    draft: normalized,
                    duplicateMatch: duplicate?.match,
                    duplicateReason: duplicate?.reason,
                    defaultDecision: duplicate == nil ? .importAsNew : .skip
                )
            )
        }

        return BulkImportPreparation(
            reviewItems: reviewItems,
            skippedInvalidCount: skippedInvalidCount
        )
    }

    // MARK: Summary

    /// The lines of the "Import complete" alert.
    ///
    /// Ports `buildImportSummaryLines`: only non-zero outcomes appear. Telling
    /// someone "0 failed" invents a failure category they were not worried about.
    public static func summaryLines(_ summary: BulkImportSummary) -> [String] {
        var lines: [String] = []
        if summary.importedCount > 0 {
            lines.append("Imported: \(summary.importedCount)")
        }
        if summary.skippedDuplicateCount > 0 {
            lines.append("Skipped duplicates: \(summary.skippedDuplicateCount)")
        }
        if summary.skippedInvalidCount > 0 {
            lines.append("Skipped missing name: \(summary.skippedInvalidCount)")
        }
        if summary.failedCount > 0 {
            lines.append("Failed: \(summary.failedCount)")
        }
        return lines.isEmpty ? ["Nothing to import."] : lines
    }
}
