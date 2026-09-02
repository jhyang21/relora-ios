import Foundation
import ReloraCore

/// What the contact form holds while it is being typed into: strings, exactly as
/// entered, with no cleanup applied yet.
///
/// Ports `ContactEditDraft` in `apps/mobile/src/features/contacts/contactEditForm.ts`.
/// `descriptors` is one comma-separated field rather than a list editor, because
/// that is what RN ships and what the data is — two or three words about who
/// someone is, not a tag taxonomy.
public struct ContactDraft: Hashable, Sendable {
    public var name: String
    public var descriptors: String
    public var phoneNumber: String
    public var email: String

    public init(name: String = "", descriptors: String = "", phoneNumber: String = "", email: String = "") {
        self.name = name
        self.descriptors = descriptors
        self.phoneNumber = phoneNumber
        self.email = email
    }

    /// Fills a form from a saved contact.
    public init(contact: Contact) {
        self.name = contact.name
        self.descriptors = contact.descriptors.joined(separator: ", ")
        self.phoneNumber = contact.phoneNumber ?? ""
        self.email = contact.email ?? ""
    }
}

/// A draft after cleanup, in the shape the repository takes.
public struct NormalizedContactDraft: Equatable, Sendable {
    public var name: String
    public var descriptors: [String]
    public var phoneNumber: String?
    public var email: String?

    public init(name: String, descriptors: [String], phoneNumber: String?, email: String?) {
        self.name = name
        self.descriptors = descriptors
        self.phoneNumber = phoneNumber
        self.email = email
    }
}

public enum ContactDraftError: Error, Equatable, Sendable {
    case missingName
}

public enum ContactEditForm {
    /// Trims everything, splits descriptors on commas, lowercases the email,
    /// and turns blanks into nulls.
    ///
    /// Ports `normalizeContactEditDraft`. The trimming is not cosmetic: the
    /// milestone notes make save-path text hygiene a binding ruling, because
    /// RN's Zod schemas `.trim()` every user-visible string and a name saved
    /// with a trailing space sorts and matches differently from the same name
    /// without one.
    public static func normalize(_ draft: ContactDraft) throws -> NormalizedContactDraft {
        let name = draft.name.trimmed
        guard !name.isEmpty else {
            throw ContactDraftError.missingName
        }

        let descriptors = draft.descriptors
            .split(separator: ",")
            .map { String($0).trimmed }
            .filter { !$0.isEmpty }

        let phoneNumber = draft.phoneNumber.trimmed
        let email = draft.email.trimmed.lowercased()

        return NormalizedContactDraft(
            name: name,
            descriptors: descriptors,
            phoneNumber: phoneNumber.isEmpty ? nil : phoneNumber,
            email: email.isEmpty ? nil : email
        )
    }

    /// Whether Save should be enabled. Name is the only required field.
    public static func canSave(_ draft: ContactDraft) -> Bool {
        !draft.name.trimmed.isEmpty
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
