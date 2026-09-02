import Foundation
import Observation
import ReloraCore
import ReloraData
import ReloraDesign

/// Hooks for the notification work M8 owns.
///
/// Deleting a reminder hands back the OS notification id it held; restoring one
/// hands back enough to schedule it again. ReloraData deliberately holds no
/// UserNotifications dependency, so the handles surface here and a caller acts
/// on them. Until M8 the caller is a no-op — but it is an *explicit* no-op, so
/// the wiring exists and the ordering is already right.
public struct ReminderNotificationHooks: Sendable {
    public var cancel: @Sendable ([String]) async -> Void
    public var reschedule: @Sendable ([RestorableReminder]) async -> Void

    public init(
        cancel: @escaping @Sendable ([String]) async -> Void = { _ in },
        reschedule: @escaping @Sendable ([RestorableReminder]) async -> Void = { _ in }
    ) {
        self.cancel = cancel
        self.reschedule = reschedule
    }

    /// The M5 wiring: everything surfaces, nothing is scheduled yet.
    public static let noop = ReminderNotificationHooks()
}

public struct ContactDetailSnapshot: Equatable, Sendable {
    public var contact: Contact?
    public var memories: [Memory] = []
    public var keyThings: [KeyThing] = []
    public var reminders: [Reminder] = []
    public var counts = ContactRepository.ContentCounts(memories: 0, keyThings: 0, reminders: 0)
}

struct ContactDetailLoader: Sendable {
    let database: AppDatabase

    func load(contactID: String, userID: String) throws -> ContactDetailSnapshot {
        let contacts = try ContactRepository(database: database)
            .getContactsByIDs([contactID], userID: userID)

        var snapshot = ContactDetailSnapshot(contact: contacts.first)
        guard snapshot.contact != nil else { return snapshot }

        snapshot.memories = ContactDetailModel.sortedMemories(
            try MemoryRepository(database: database).list(contactID: contactID)
        )
        snapshot.keyThings = ContactDetailModel.sortedKeyThings(
            try KeyThingRepository(database: database).list(contactID: contactID)
        )
        snapshot.reminders = ContactDetailModel.sortedReminders(
            try ReminderRepository(database: database).list(contactID: contactID)
        )
        snapshot.counts = (try? ContactRepository(database: database)
            .countContent(contactID: contactID, userID: userID))
            ?? ContactDetailModel.unknownContentCounts

        return snapshot
    }
}

@MainActor
@Observable
public final class ContactDetailViewModel {
    public private(set) var snapshot = ContactDetailSnapshot()
    public var tab: ContactDetailTab = .memories
    /// Set when a contact delete needs a confirmation first.
    public var pendingDeleteConfirmation: ContactDetailModel.DeleteConfirmation?
    /// Set once the contact is gone, so the view can pop.
    public private(set) var contactWasDeleted = false

    @ObservationIgnored public let contactID: String
    @ObservationIgnored private let loader: ContactDetailLoader
    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let userID: String
    @ObservationIgnored private let toasts: ReloraToastCenter
    @ObservationIgnored private let hooks: ReminderNotificationHooks
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    public init(
        contactID: String,
        userID: String,
        database: AppDatabase,
        toasts: ReloraToastCenter,
        hooks: ReminderNotificationHooks = .noop
    ) {
        self.contactID = contactID
        self.userID = userID
        self.database = database
        self.loader = ContactDetailLoader(database: database)
        self.toasts = toasts
        self.hooks = hooks
    }

    public func start() {
        guard observationTask == nil else { return }
        let changes = database.observeContentChanges()
        observationTask = Task { [weak self] in
            for await _ in changes {
                self?.reload()
            }
        }
        reload()
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    public func reload() {
        let loader = self.loader
        let contactID = self.contactID
        let userID = self.userID
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                try? loader.load(contactID: contactID, userID: userID)
            }.value
            guard let loaded else { return }
            self?.snapshot = loaded
        }
    }

    // MARK: Item delete

    /// Deletes one memory, key thing, or reminder.
    ///
    /// No confirmation. The row goes, a toast appears, and Undo is there for a
    /// few seconds — that is the product's stance on destructive actions, and it
    /// is why an alert here would be a regression rather than a safeguard.
    public func deleteItem(id: String, kind: ContactItemKind) {
        let copy = ContactDetailModel.itemDeleteCopy(kind)

        do {
            let result = try softDelete(id: id, kind: kind)
            guard result.deleted else { return }

            // Step 1 of the two-step: cancel before anything forgets the id.
            let ids = result.canceledNotificationIDs
            if !ids.isEmpty {
                Task { await hooks.cancel(ids) }
            }

            let deletedAt = result.deletedAt
            toasts.show(
                copy.deletedMessage,
                variant: .success,
                actionLabel: "Undo",
                action: { [weak self] in
                    self?.restoreItem(id: id, kind: kind, deletedAt: deletedAt, copy: copy)
                }
            )
            reload()
        } catch {
            toasts.showError("Delete failed", message: copy.deleteFailedMessage)
        }
    }

    private func restoreItem(
        id: String,
        kind: ContactItemKind,
        deletedAt: String,
        copy: ContactDetailModel.ItemDeleteCopy
    ) {
        do {
            let result = try restore(id: id, kind: kind, deletedAt: deletedAt)
            guard result.restored else { return }

            if let reminder = result.reminderToReschedule {
                Task { await hooks.reschedule([reminder]) }
            }
            toasts.show(copy.restoredMessage, variant: .success)
            reload()
        } catch {
            toasts.showError("Undo failed", message: copy.undoFailedMessage)
        }
    }

    private func softDelete(id: String, kind: ContactItemKind) throws -> ContactItemDeleteResult {
        switch kind {
        case .memory:
            return try MemoryRepository(database: database)
                .softDelete(itemID: id, contactID: contactID, userID: userID)
        case .keyThing:
            return try KeyThingRepository(database: database)
                .softDelete(itemID: id, contactID: contactID, userID: userID)
        case .reminder:
            return try ReminderRepository(database: database)
                .softDelete(itemID: id, contactID: contactID, userID: userID)
        }
    }

    private func restore(
        id: String,
        kind: ContactItemKind,
        deletedAt: String
    ) throws -> ContactItemRestoreResult {
        switch kind {
        case .memory:
            return try MemoryRepository(database: database)
                .restore(itemID: id, contactID: contactID, userID: userID, deletedAt: deletedAt)
        case .keyThing:
            return try KeyThingRepository(database: database)
                .restore(itemID: id, contactID: contactID, userID: userID, deletedAt: deletedAt)
        case .reminder:
            return try ReminderRepository(database: database)
                .restore(itemID: id, contactID: contactID, userID: userID, deletedAt: deletedAt)
        }
    }

    // MARK: Contact delete

    /// Starts a contact delete, asking first only when there is something to
    /// lose.
    ///
    /// **This is the one confirmation in the product**, and it is deliberate.
    /// Deleting a contact cascades over memories and key things the user wrote;
    /// the plan's rule is that alerts are for lossy confirmation, and nothing
    /// else in Relora qualifies. A contact carrying only reminders — or nothing
    /// at all — deletes straight away with an Undo toast like any other row.
    public func requestDeleteContact() {
        guard let contact = snapshot.contact else { return }

        let counts = (try? ContactRepository(database: database)
            .countContent(contactID: contactID, userID: userID))
            // A failed count confirms rather than deletes silently. Ports the
            // fallback in contactDeleteActions.ts: not knowing what is at stake
            // is a reason to ask, never a reason to assume nothing is.
            ?? ContactDetailModel.unknownContentCounts

        guard ContactDetailModel.needsDeleteConfirmation(counts) else {
            deleteContact()
            return
        }

        pendingDeleteConfirmation = ContactDetailModel.deleteConfirmation(
            name: contact.name,
            counts: counts
        )
    }

    public func deleteContact() {
        pendingDeleteConfirmation = nil
        guard let contact = snapshot.contact else { return }

        do {
            let result = try ContactCascadeDelete.deleteContactCascade(
                database: database,
                contactID: contactID,
                userID: userID
            )

            if !result.canceledNotificationIDs.isEmpty {
                let ids = result.canceledNotificationIDs
                Task { await hooks.cancel(ids) }
            }

            contactWasDeleted = true
            let deletedAt = result.deletedAt
            toasts.show(
                "\(contact.name) deleted",
                variant: .success,
                actionLabel: "Undo",
                action: { [weak self] in
                    self?.restoreContact(deletedAt: deletedAt)
                }
            )
        } catch {
            toasts.showError("Delete failed", message: "Could not delete this contact.")
        }
    }

    private func restoreContact(deletedAt: String) {
        do {
            let result = try ContactCascadeDelete.restoreContactCascade(
                database: database,
                contactID: contactID,
                userID: userID,
                deletedAt: deletedAt
            )
            guard result.restoredContact else { return }

            if !result.remindersToReschedule.isEmpty {
                let reminders = result.remindersToReschedule
                Task { await hooks.reschedule(reminders) }
            }
            contactWasDeleted = false
            toasts.show("Contact restored", variant: .success)
        } catch {
            toasts.showError("Undo failed", message: "Could not restore this contact.")
        }
    }
}
