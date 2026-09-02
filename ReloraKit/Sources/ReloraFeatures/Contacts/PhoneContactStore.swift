import Contacts
import Foundation

/// Reading the device address book.
///
/// The only place in the app that touches `Contacts.framework`. Everything above
/// it works in `ImportablePhoneContact`, which is why the matching rules can be
/// tested without a contact store.
public struct PhoneContactStore: Sendable {
    public enum Access: Sendable, Equatable {
        case granted
        /// iOS 18's limited access: the user picked which contacts the app may
        /// see. Nothing here needs to change — the fetch simply returns fewer
        /// people, and an import of "everyone I chose to share" is a coherent
        /// thing to offer. The distinction exists so the empty state can say
        /// *why* the list is short instead of implying an empty address book.
        case limited
        case denied
    }

    public init() {}

    /// Includes `CNContactFormatter`'s own descriptor. Reading a key that was
    /// not fetched raises an Objective-C exception rather than returning empty,
    /// so the formatter's requirements are asked for by name rather than
    /// guessed at from the name keys.
    private static let keysToFetch: [CNKeyDescriptor] = [
        CNContactIdentifierKey,
        CNContactGivenNameKey,
        CNContactFamilyNameKey,
        CNContactOrganizationNameKey,
        CNContactJobTitleKey,
        CNContactPhoneNumbersKey,
        CNContactEmailAddressesKey
    ].map { $0 as CNKeyDescriptor }
        + [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)]

    public func requestAccess() async -> Access {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)

        if status == .authorized {
            return .granted
        }
        if #available(iOS 18.0, *), status == .limited {
            return .limited
        }
        if status == .denied || status == .restricted {
            return .denied
        }

        let granted = (try? await store.requestAccess(for: .contacts)) ?? false
        guard granted else { return .denied }

        if #available(iOS 18.0, *), CNContactStore.authorizationStatus(for: .contacts) == .limited {
            return .limited
        }
        return .granted
    }

    /// Every contact the app is allowed to see, sorted by name.
    ///
    /// Enumerated rather than paged. `CNContactFetchRequest` streams, so an
    /// address book of any size costs one pass and no offset arithmetic — the
    /// page loop RN needed is an Expo API constraint, not a real one.
    public func fetchAll() throws -> [ImportablePhoneContact] {
        let store = CNContactStore()
        let request = CNContactFetchRequest(keysToFetch: Self.keysToFetch)
        request.sortOrder = .userDefault

        var results: [ImportablePhoneContact] = []
        try store.enumerateContacts(with: request) { contact, _ in
            if let mapped = Self.map(contact) {
                results.append(mapped)
            }
        }
        return results
    }

    /// Drops contacts with no usable name here rather than counting them as
    /// "skipped" later — a nameless row in the picker is a row nobody can
    /// choose on purpose.
    ///
    /// Every key is checked before it is read. This mapping also runs on
    /// contacts handed back by `CNContactPickerViewController`, which decides
    /// for itself which keys it fetched, and reading an absent one throws an
    /// Objective-C exception no `try` can catch.
    static func map(_ contact: CNContact) -> ImportablePhoneContact? {
        let name = displayName(for: contact)
        guard !name.isEmpty else { return nil }

        let company = contact.isKeyAvailable(CNContactOrganizationNameKey)
            ? contact.organizationName : ""
        let jobTitle = contact.isKeyAvailable(CNContactJobTitleKey) ? contact.jobTitle : ""

        return ImportablePhoneContact(
            id: contact.identifier,
            name: name,
            phoneNumbers: contact.isKeyAvailable(CNContactPhoneNumbersKey)
                ? contact.phoneNumbers.map(\.value.stringValue) : [],
            emails: contact.isKeyAvailable(CNContactEmailAddressesKey)
                ? contact.emailAddresses.map { $0.value as String } : [],
            company: company.isEmpty ? nil : company,
            jobTitle: jobTitle.isEmpty ? nil : jobTitle
        )
    }

    /// The formatter when its keys are there, the name parts when they are not,
    /// and the company as a last resort — a business contact with no person's
    /// name attached is still someone worth keeping notes about.
    private static func displayName(for contact: CNContact) -> String {
        let formatterDescriptor = CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        if contact.areKeysAvailable([formatterDescriptor]),
           let formatted = CNContactFormatter.string(from: contact, style: .fullName)?.trimmed,
           !formatted.isEmpty {
            return formatted
        }

        var parts: [String] = []
        if contact.isKeyAvailable(CNContactGivenNameKey) { parts.append(contact.givenName) }
        if contact.isKeyAvailable(CNContactFamilyNameKey) { parts.append(contact.familyName) }

        let joined = parts.filter { !$0.isEmpty }.joined(separator: " ").trimmed
        if !joined.isEmpty { return joined }

        if contact.isKeyAvailable(CNContactOrganizationNameKey) {
            return contact.organizationName.trimmed
        }
        return ""
    }

    /// Text a row is searched against. Ports `buildSearchIndex`.
    public static func searchIndex(_ contact: ImportablePhoneContact) -> String {
        ([contact.name, contact.company, contact.jobTitle].compactMap { $0 }
            + contact.phoneNumbers
            + contact.emails)
            .joined(separator: " ")
            .lowercased()
    }
}
