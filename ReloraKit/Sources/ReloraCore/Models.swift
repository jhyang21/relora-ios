import Foundation

/// Whether a `KeyThing` or `Memory` was entered by hand or produced by the
/// voice pipeline. Mirrors `source TEXT NOT NULL CHECK(source IN ('manual',
/// 'voice'))` on both tables in apps/mobile/src/db/schema.ts.
public enum EntrySource: String, Codable, Equatable, Sendable {
    case manual
    case voice
}

/// A reminder's lifecycle state. Mirrors `status TEXT NOT NULL
/// CHECK(status IN ('scheduled', 'fired', 'dismissed'))` on the `reminders`
/// table. There is no separate "completed" timestamp anywhere in the
/// schema or in `@relora/shared`'s `Reminder` type — a reminder's state is
/// fully captured by this status plus `remindAt`.
public enum ReminderStatus: String, Codable, Equatable, Sendable {
    case scheduled
    case fired
    case dismissed
}

/// Mirrors the `contacts` table (apps/mobile/src/db/schema.ts) and the
/// `Contact` interface in packages/shared/src/contracts/types.ts.
public struct Contact: Equatable, Sendable {
    public var id: String
    public var userID: String
    public var name: String
    public var avatarURL: String?
    public var descriptors: [String]
    public var phoneNumber: String?
    public var email: String?
    public var createdAt: String
    public var updatedAt: String
    public var isDirty: Bool
    public var dirtyAt: String?
    public var lastInteractionAt: String?
    public var deletedAt: String?

    public init(
        id: String,
        userID: String,
        name: String,
        avatarURL: String? = nil,
        descriptors: [String] = [],
        phoneNumber: String? = nil,
        email: String? = nil,
        createdAt: String,
        updatedAt: String,
        isDirty: Bool = false,
        dirtyAt: String? = nil,
        lastInteractionAt: String? = nil,
        deletedAt: String? = nil
    ) {
        self.id = id
        self.userID = userID
        self.name = name
        self.avatarURL = avatarURL
        self.descriptors = descriptors
        self.phoneNumber = phoneNumber
        self.email = email
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDirty = isDirty
        self.dirtyAt = dirtyAt
        self.lastInteractionAt = lastInteractionAt
        self.deletedAt = deletedAt
    }
}

/// Mirrors the `memories` table. `audioLocalURI` is mobile-only replay
/// metadata (`StoredMemory` in apps/mobile/src/db/types.ts) folded into the
/// same struct rather than kept as a separate type — ReloraCore has no
/// reason to distinguish "the row as stored on this device" from "the row"
/// the way the RN client/server split does.
public struct Memory: Equatable, Sendable {
    public var id: String
    public var contactID: String
    public var userID: String
    public var text: String
    public var labels: [String]
    public var createdAt: String
    public var updatedAt: String
    public var isDirty: Bool
    public var dirtyAt: String?
    public var audioURL: String?
    public var audioLocalURI: String?
    public var transcript: String?
    public var source: EntrySource
    public var deletedAt: String?

    public init(
        id: String,
        contactID: String,
        userID: String,
        text: String,
        labels: [String] = [],
        createdAt: String,
        updatedAt: String,
        isDirty: Bool = false,
        dirtyAt: String? = nil,
        audioURL: String? = nil,
        audioLocalURI: String? = nil,
        transcript: String? = nil,
        source: EntrySource,
        deletedAt: String? = nil
    ) {
        self.id = id
        self.contactID = contactID
        self.userID = userID
        self.text = text
        self.labels = labels
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDirty = isDirty
        self.dirtyAt = dirtyAt
        self.audioURL = audioURL
        self.audioLocalURI = audioLocalURI
        self.transcript = transcript
        self.source = source
        self.deletedAt = deletedAt
    }
}

/// Mirrors the `key_things` table. NOTE: unlike `Memory`, this table (and
/// the shared `KeyThing` contract type) has no `labels` column — a key
/// thing is plain text plus a source, nothing more.
public struct KeyThing: Equatable, Sendable {
    public var id: String
    public var contactID: String
    public var userID: String
    public var text: String
    public var source: EntrySource
    public var createdAt: String
    public var updatedAt: String
    public var isDirty: Bool
    public var dirtyAt: String?
    public var deletedAt: String?

    public init(
        id: String,
        contactID: String,
        userID: String,
        text: String,
        source: EntrySource,
        createdAt: String,
        updatedAt: String,
        isDirty: Bool = false,
        dirtyAt: String? = nil,
        deletedAt: String? = nil
    ) {
        self.id = id
        self.contactID = contactID
        self.userID = userID
        self.text = text
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDirty = isDirty
        self.dirtyAt = dirtyAt
        self.deletedAt = deletedAt
    }
}

/// Mirrors the `reminders` table.
public struct Reminder: Equatable, Sendable {
    public var id: String
    public var contactID: String
    public var userID: String
    public var memoryID: String?
    public var title: String
    public var remindAt: String
    public var status: ReminderStatus
    public var createdAt: String
    public var updatedAt: String
    public var isDirty: Bool
    public var dirtyAt: String?
    public var notificationID: String?
    public var deletedAt: String?

    public init(
        id: String,
        contactID: String,
        userID: String,
        memoryID: String? = nil,
        title: String,
        remindAt: String,
        status: ReminderStatus,
        createdAt: String,
        updatedAt: String,
        isDirty: Bool = false,
        dirtyAt: String? = nil,
        notificationID: String? = nil,
        deletedAt: String? = nil
    ) {
        self.id = id
        self.contactID = contactID
        self.userID = userID
        self.memoryID = memoryID
        self.title = title
        self.remindAt = remindAt
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDirty = isDirty
        self.dirtyAt = dirtyAt
        self.notificationID = notificationID
        self.deletedAt = deletedAt
    }
}

/// Mirrors the `voice_note_usage_events` table. This table carries no
/// `is_dirty` / `dirty_at` / `deleted_at` columns — it is an append-only
/// billing ledger synced by insert, not a syncable/tombstonable entity like
/// the four structs above.
public struct UsageEvent: Equatable, Sendable {
    public var id: String
    public var userID: String
    public var processedAt: String
    public var source: String
    public var serverSyncedAt: String?

    public init(
        id: String,
        userID: String,
        processedAt: String,
        source: String,
        serverSyncedAt: String? = nil
    ) {
        self.id = id
        self.userID = userID
        self.processedAt = processedAt
        self.source = source
        self.serverSyncedAt = serverSyncedAt
    }
}
