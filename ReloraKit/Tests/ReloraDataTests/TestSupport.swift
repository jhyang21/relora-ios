import Foundation
@testable import ReloraData
import ReloraCore

/// Shared fixtures for ReloraData tests. Every test opens its own in-memory
/// database (`AppDatabase.inMemory()` is a fresh `DatabaseQueue`), so tests
/// never share storage state — only `SearchIndexState.shared`'s process-wide
/// flag crosses test boundaries, and search-focused tests reset it explicitly.
enum Fixtures {
    static let defaultUserID = "user-1"

    static func makeDatabase() throws -> AppDatabase {
        try AppDatabase.inMemory()
    }

    static func makeContact(
        id: String = ReloraID.new(),
        userID: String = defaultUserID,
        name: String = "Ada Lovelace",
        descriptors: [String] = [],
        phoneNumber: String? = nil,
        email: String? = nil
    ) -> Contact {
        let now = ReloraTimestamp.now()
        return Contact(
            id: id,
            userID: userID,
            name: name,
            descriptors: descriptors,
            phoneNumber: phoneNumber,
            email: email,
            createdAt: now,
            updatedAt: now
        )
    }

    static func makeMemory(
        id: String = ReloraID.new(),
        contactID: String,
        userID: String = defaultUserID,
        text: String = "Had coffee together.",
        labels: [String] = [],
        transcript: String? = nil,
        source: EntrySource = .manual
    ) -> Memory {
        let now = ReloraTimestamp.now()
        return Memory(
            id: id,
            contactID: contactID,
            userID: userID,
            text: text,
            labels: labels,
            createdAt: now,
            updatedAt: now,
            transcript: transcript,
            source: source
        )
    }

    static func makeKeyThing(
        id: String = ReloraID.new(),
        contactID: String,
        userID: String = defaultUserID,
        text: String = "Allergic to shellfish.",
        source: EntrySource = .manual
    ) -> KeyThing {
        let now = ReloraTimestamp.now()
        return KeyThing(id: id, contactID: contactID, userID: userID, text: text, source: source, createdAt: now, updatedAt: now)
    }

    static func makeReminder(
        id: String = ReloraID.new(),
        contactID: String,
        userID: String = defaultUserID,
        memoryID: String? = nil,
        title: String = "Follow up",
        remindAt: String? = nil,
        status: ReminderStatus = .scheduled
    ) -> Reminder {
        let now = ReloraTimestamp.now()
        return Reminder(
            id: id,
            contactID: contactID,
            userID: userID,
            memoryID: memoryID,
            title: title,
            remindAt: remindAt ?? now,
            status: status,
            createdAt: now,
            updatedAt: now
        )
    }
}
