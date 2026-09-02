import Foundation
import Testing
import ReloraCore
import ReloraData
@testable import ReloraFeatures

private let now = "2026-08-31T12:00:00.000Z"

private func iso(daysFromNow days: Double) -> String {
    let base = ReloraTimestamp.parse(now)!
    return ReloraTimestamp.from(base.addingTimeInterval(days * 86_400))
}

private func existingContact(
    _ id: String,
    name: String,
    phone: String? = nil,
    email: String? = nil,
    updatedAt: String = now
) -> Contact {
    Contact(
        id: id,
        userID: "user-1",
        name: name,
        phoneNumber: phone,
        email: email,
        createdAt: now,
        updatedAt: updatedAt
    )
}

// MARK: - The form

@Suite("Contact form")
struct ContactEditFormTests {
    /// Trimming on save is a binding ruling: RN's schemas trim every
    /// user-visible string, and a name stored with a trailing space sorts and
    /// matches differently from the same name without one.
    @Test("Saving trims every field")
    func trimsEverything() throws {
        let normalized = try ContactEditForm.normalize(
            ContactDraft(
                name: "  Ana Vega  ",
                descriptors: " designer , climbs ",
                phoneNumber: "  555-0100 ",
                email: "  ANA@Example.COM "
            )
        )

        #expect(normalized.name == "Ana Vega")
        #expect(normalized.descriptors == ["designer", "climbs"])
        #expect(normalized.phoneNumber == "555-0100")
        #expect(normalized.email == "ana@example.com")
    }

    @Test("Blank optional fields become null, not empty strings")
    func blanksBecomeNil() throws {
        let normalized = try ContactEditForm.normalize(ContactDraft(name: "Ana", phoneNumber: "   "))
        #expect(normalized.phoneNumber == nil)
        #expect(normalized.email == nil)
        #expect(normalized.descriptors.isEmpty)
    }

    @Test("A name of only spaces is no name at all")
    func nameRequired() {
        #expect(throws: ContactDraftError.missingName) {
            try ContactEditForm.normalize(ContactDraft(name: "   "))
        }
        #expect(ContactEditForm.canSave(ContactDraft(name: "   ")) == false)
        #expect(ContactEditForm.canSave(ContactDraft(name: "Ana")))
    }

    @Test("Editing an existing contact fills the form from it")
    func draftFromContact() {
        var contact = existingContact("c1", name: "Ana", phone: "555", email: "ana@example.com")
        contact.descriptors = ["designer", "climbs"]

        let draft = ContactDraft(contact: contact)
        #expect(draft.descriptors == "designer, climbs")
        #expect(draft.phoneNumber == "555")
    }
}

// MARK: - Import matching

@Suite("Contact import")
struct ContactImportModelTests {
    @Test("Job title and company become one readable descriptor")
    func draftDescriptors() {
        let both = ContactImportModel.draft(
            from: ImportablePhoneContact(id: "p1", name: "Ana", company: "Figma", jobTitle: "Designer")
        )
        #expect(both.descriptors == "Designer at Figma")

        let companyOnly = ContactImportModel.draft(
            from: ImportablePhoneContact(id: "p2", name: "Ben", company: "Figma")
        )
        #expect(companyOnly.descriptors == "Figma")

        let neither = ContactImportModel.draft(from: ImportablePhoneContact(id: "p3", name: "Cy"))
        #expect(neither.descriptors.isEmpty)
    }

    /// Different spellings of one number are one person. This is the whole point
    /// of normalizing before comparing.
    @Test("Phone formatting does not hide a duplicate")
    func phoneMatchIgnoresFormatting() throws {
        let draft = try ContactEditForm.normalize(
            ContactDraft(name: "Ana", phoneNumber: "+1 (555) 010-9999")
        )
        let match = ContactImportModel.findDuplicate(
            for: draft,
            in: [existingContact("c1", name: "Ana Vega", phone: "15550109999")]
        )

        #expect(match?.match.id == "c1")
        #expect(match?.reason == .phone)
    }

    @Test("Matching on both channels says so")
    func phoneAndEmail() throws {
        let draft = try ContactEditForm.normalize(
            ContactDraft(name: "Ana", phoneNumber: "5550100", email: "ana@example.com")
        )
        let match = ContactImportModel.findDuplicate(
            for: draft,
            in: [existingContact("c1", name: "Ana", phone: "555-0100", email: "ANA@example.com")]
        )

        #expect(match?.reason == .phoneAndEmail)
    }

    /// Two contacts with no phone number are not duplicates of each other.
    @Test("Empty values never match")
    func emptyValuesNeverMatch() throws {
        let draft = try ContactEditForm.normalize(ContactDraft(name: "Ana"))
        let match = ContactImportModel.findDuplicate(
            for: draft,
            in: [existingContact("c1", name: "Someone else")]
        )
        #expect(match == nil)
    }

    @Test("The most recently updated match wins")
    func mostRecentMatchWins() throws {
        let draft = try ContactEditForm.normalize(ContactDraft(name: "Ana", email: "ana@example.com"))
        let match = ContactImportModel.findDuplicate(
            for: draft,
            in: [
                existingContact("old", name: "Ana", email: "ana@example.com", updatedAt: iso(daysFromNow: -10)),
                existingContact("new", name: "Ana", email: "ana@example.com", updatedAt: iso(daysFromNow: -1))
            ]
        )
        #expect(match?.match.id == "new")
    }

    @Test("A deleted contact is not something to be a duplicate of")
    func deletedContactsIgnored() throws {
        var deleted = existingContact("c1", name: "Ana", email: "ana@example.com")
        deleted.deletedAt = iso(daysFromNow: -1)

        let draft = try ContactEditForm.normalize(ContactDraft(name: "Ana", email: "ana@example.com"))
        #expect(ContactImportModel.findDuplicate(for: draft, in: [deleted]) == nil)
    }

    /// A duplicate defaults to Skip. When the app is unsure, the safe default is
    /// not to create a second copy of someone.
    @Test("Review pre-decides: duplicates skip, everything else imports")
    func reviewDefaults() {
        let preparation = ContactImportModel.prepare(
            selected: [
                ImportablePhoneContact(id: "p1", name: "Ana", emails: ["ana@example.com"]),
                ImportablePhoneContact(id: "p2", name: "Ben", emails: ["ben@example.com"]),
                ImportablePhoneContact(id: "p3", name: "   ")
            ],
            existing: [existingContact("c1", name: "Ana Vega", email: "ana@example.com")]
        )

        #expect(preparation.reviewItems.count == 2)
        #expect(preparation.skippedInvalidCount == 1)
        #expect(preparation.reviewItems[0].defaultDecision == .skip)
        #expect(preparation.reviewItems[0].duplicateReason == .email)
        #expect(preparation.reviewItems[1].defaultDecision == .importAsNew)
        #expect(preparation.reviewItems[1].duplicateMatch == nil)
    }

    @Test("Fifty at a time")
    func cap() {
        #expect(ContactImportModel.maxBulkImportContacts == 50)
    }

    /// Telling someone "0 failed" invents a failure they were not worried about.
    @Test("The summary lists only what happened")
    func summaryLines() {
        let lines = ContactImportModel.summaryLines(
            BulkImportSummary(importedCount: 3, skippedDuplicateCount: 2)
        )
        #expect(lines == ["Imported: 3", "Skipped duplicates: 2"])

        #expect(ContactImportModel.summaryLines(BulkImportSummary()) == ["Nothing to import."])
    }
}

// MARK: - Contact detail

@Suite("Contact detail")
struct ContactDetailModelTests {
    /// The one confirmation in the product, and only when there is something to
    /// lose. Reminders alone are not a reason to interrupt someone.
    @Test("Only memories or key things earn a confirmation")
    func deleteConfirmationRule() {
        #expect(
            ContactDetailModel.needsDeleteConfirmation(
                ContactRepository.ContentCounts(memories: 0, keyThings: 0, reminders: 4)
            ) == false
        )
        #expect(
            ContactDetailModel.needsDeleteConfirmation(
                ContactRepository.ContentCounts(memories: 1, keyThings: 0, reminders: 0)
            )
        )
        #expect(
            ContactDetailModel.needsDeleteConfirmation(
                ContactRepository.ContentCounts(memories: 0, keyThings: 2, reminders: 0)
            )
        )
    }

    /// A failed count asks rather than assumes. Not knowing what is at stake is
    /// a reason to confirm, never a reason to assume nothing is.
    @Test("An unreadable count still confirms")
    func unknownCountsConfirm() {
        #expect(ContactDetailModel.needsDeleteConfirmation(ContactDetailModel.unknownContentCounts))
    }

    @Test("The confirmation says what else goes")
    func summarizeContent() {
        #expect(
            ContactDetailModel.summarizeContent(
                ContactRepository.ContentCounts(memories: 2, keyThings: 1, reminders: 3)
            ) == "2 memories, a key thing, and 3 reminders"
        )
        #expect(
            ContactDetailModel.summarizeContent(
                ContactRepository.ContentCounts(memories: 1, keyThings: 0, reminders: 0)
            ) == "a memory"
        )
    }

    @Test("Delete copy names the kind of thing being deleted")
    func itemDeleteCopy() {
        #expect(ContactDetailModel.itemDeleteCopy(.keyThing).deleteLabel == "Delete key thing")
        #expect(ContactDetailModel.itemDeleteCopy(.memory).deletedMessage == "Memory deleted")
        #expect(ContactDetailModel.itemDeleteCopy(.reminder).restoredMessage == "Reminder restored")
    }
}

// MARK: - Wording

@Suite("Relative time")
struct RelativeTimeTests {
    @Test("Under 45 seconds is just now")
    func justNow() {
        let target = ReloraTimestamp.from(ReloraTimestamp.parse(now)!.addingTimeInterval(-30))
        #expect(ReloraRelativeTime.relative(target, now: now) == "just now")
    }

    @Test("A single day either way gets a word, not a number")
    func yesterdayAndTomorrow() {
        #expect(ReloraRelativeTime.relative(iso(daysFromNow: -1), now: now) == "yesterday")
        #expect(ReloraRelativeTime.relative(iso(daysFromNow: 1), now: now) == "tomorrow")
    }

    @Test("Past reads 'ago', future reads 'in'")
    func direction() {
        #expect(ReloraRelativeTime.relative(iso(daysFromNow: -3), now: now) == "3 days ago")
        #expect(ReloraRelativeTime.relative(iso(daysFromNow: 3), now: now) == "in 3 days")
        #expect(ReloraRelativeTime.relative(iso(daysFromNow: -21), now: now) == "3 weeks ago")
    }

    @Test("A duration carries no direction")
    func duration() {
        #expect(ReloraRelativeTime.duration(from: iso(daysFromNow: -56), to: now) == "8 weeks")
    }

    @Test("An unparseable timestamp says nothing")
    func unparseable() {
        #expect(ReloraRelativeTime.relative("not-a-date", now: now).isEmpty)
        #expect(ReloraRelativeTime.duration(from: "not-a-date", to: now).isEmpty)
        #expect(ReloraRelativeTime.friendlyDateTime("not-a-date", now: now).isEmpty)
    }

    @Test("Inside a week it stays relative")
    func friendlyStaysRelative() {
        #expect(ReloraRelativeTime.friendlyDateTime(iso(daysFromNow: -2), now: now) == "2 days ago")
    }
}
