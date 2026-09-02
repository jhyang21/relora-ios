import Foundation
import Observation
import ReloraCore
import ReloraData
import ReloraDesign
import ReloraServices

/// The database side of the reminders screen, kept `Sendable` and free of
/// view state so it can run off the main actor. Ported from the query
/// `reminderListModel.ts`'s screen-level loader runs: every active reminder
/// for the user, joined against the contacts they belong to.
struct RemindersDataLoader: Sendable {
    let database: AppDatabase

    func load(userID: String, nowISO: String) throws -> [ReminderSection] {
        let reminders = try ReminderRepository(database: database).listFullByUser(userID: userID)
        guard !reminders.isEmpty else { return [] }

        // The full set the reminders on screen belong to — never
        // `ContactRepository.list`'s 2000-row cap, which this screen has no
        // reason to inherit; a reminder already names its contact id, so
        // there is no ranking or search happening here, just a lookup.
        let contactIDs = Array(Set(reminders.map(\.contactID)))
        let contacts = try ContactRepository(database: database).getContactsByIDs(contactIDs, userID: userID)
        let names = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0.name) })

        return ReminderListModel.sections(reminders: reminders, contactNames: names, nowISO: nowISO)
    }
}

/// The reminders screen's state: what Home's bell opens.
///
/// Mirrors `HomeViewModel`'s identity handling exactly — `activeUserID`
/// never traps on `.unresolved`, and every write re-derives the row it needs
/// from the database rather than trusting a cached copy, the same
/// cancel-then-clear-locally two-step `ContactDetailViewModel` already runs
/// for reminders inside a contact.
@MainActor
@Observable
public final class RemindersViewModel {
    public private(set) var sections: [ReminderSection] = []

    public var isSignedOut: Bool {
        activeUserID == nil
    }

    @ObservationIgnored private let loader: RemindersDataLoader
    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let identity: IdentityController
    @ObservationIgnored private let toasts: ReloraToastCenter
    @ObservationIgnored private let hooks: ReminderNotificationHooks
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    public init(
        database: AppDatabase,
        identity: IdentityController,
        toasts: ReloraToastCenter,
        hooks: ReminderNotificationHooks
    ) {
        self.loader = RemindersDataLoader(database: database)
        self.database = database
        self.identity = identity
        self.toasts = toasts
        self.hooks = hooks
    }

    private var activeUserID: String? {
        if case .unresolved = identity.identity { return nil }
        return identity.identity.ownerUserID
    }

    // MARK: Lifecycle

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
        loadTask?.cancel()
    }

    /// Signing in or out changes whose reminders these are, and neither is a
    /// database write the content observation would notice on its own.
    public func identityChanged() {
        reload()
    }

    public func reload() {
        loadTask?.cancel()

        guard let userID = activeUserID else {
            sections = []
            return
        }

        let loader = self.loader
        let nowISO = ReloraTimestamp.now()
        loadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                try? loader.load(userID: userID, nowISO: nowISO)
            }.value

            guard !Task.isCancelled, let loaded else { return }
            self?.sections = loaded
        }
    }

    // MARK: Complete / undo

    /// Marks a reminder done in place — `status = .dismissed`, `remindAt`
    /// untouched. Deliberately not the tombstone path: RN's "complete"
    /// action is a status write, not a delete, so the row keeps its place in
    /// the contact's reminder history instead of becoming a restorable
    /// tombstone.
    public func complete(_ reminder: Reminder) {
        var updated = reminder
        updated.status = .dismissed
        updated.updatedAt = ReloraTimestamp.now()

        do {
            try ReminderRepository(database: database).upsert(updated)

            // Two-step: cancel the OS notification, then clear the row's
            // notification_id locally — same order as every other caller of
            // this pair, per docs/milestone-notes.md.
            if let notificationID = reminder.notificationID {
                Task { await self.hooks.cancel([notificationID]) }
                try? ReminderRepository(database: database).clearNotificationIDs([notificationID])
            }

            toasts.show(
                ReloraToast(
                    title: "Reminder marked done",
                    variant: .success,
                    duration: Self.undoToastDuration,
                    actionLabel: "Undo",
                    action: { [weak self] in self?.undoComplete(reminder) }
                )
            )
            reload()
        } catch {
            toasts.showError("Couldn't update", message: "Try again.")
        }
    }

    /// 5 seconds — RN's `UNDO_TOAST_DURATION_MS` for this screen's Undo,
    /// longer than `ReloraToast.defaultDuration`'s 4. Reading "done" and
    /// deciding to take it back needs the extra second the rest of the app's
    /// toasts don't.
    static let undoToastDuration: TimeInterval = 5

    /// Restores the exact prior reminder object — a full round-trip, not a
    /// tombstone-timestamp match, since `complete` never tombstoned anything.
    /// Only `updatedAt` moves.
    private func undoComplete(_ original: Reminder) {
        var restored = original
        restored.updatedAt = ReloraTimestamp.now()

        do {
            try ReminderRepository(database: database).upsert(restored)
            if restored.status == .scheduled {
                let restorable = RestorableReminder(
                    id: restored.id,
                    contactID: restored.contactID,
                    title: restored.title,
                    remindAt: restored.remindAt,
                    status: restored.status
                )
                Task { await self.hooks.reschedule([restorable]) }
            }
            toasts.show("Reminder restored", variant: .success)
            reload()
        } catch {
            toasts.showError("Couldn't restore", message: "Try again.")
        }
    }

    // MARK: Delete / undo

    /// Tombstones a reminder from this screen. **A deviation from RN**,
    /// which has no delete action on its reminders list — only inside
    /// `ContactDetailScreen`. Built anyway per the milestone brief's
    /// explicit ask; ports the exact-tombstone-timestamp undo
    /// `ContactDetailViewModel.deleteItem`/`restoreItem` already use for a
    /// reminder, kind for kind.
    public func delete(_ reminder: Reminder) {
        do {
            let result = try ReminderRepository(database: database).softDelete(
                itemID: reminder.id,
                contactID: reminder.contactID,
                userID: reminder.userID
            )
            guard result.deleted else { return }

            let ids = result.canceledNotificationIDs
            if !ids.isEmpty {
                Task { await self.hooks.cancel(ids) }
            }

            let deletedAt = result.deletedAt
            toasts.show(
                "Reminder deleted",
                variant: .success,
                actionLabel: "Undo",
                action: { [weak self] in self?.restore(reminder, deletedAt: deletedAt) }
            )
            reload()
        } catch {
            toasts.showError("Delete failed", message: "Try again.")
        }
    }

    private func restore(_ reminder: Reminder, deletedAt: String) {
        do {
            let result = try ReminderRepository(database: database).restore(
                itemID: reminder.id,
                contactID: reminder.contactID,
                userID: reminder.userID,
                deletedAt: deletedAt
            )
            guard result.restored else { return }

            if let toReschedule = result.reminderToReschedule {
                Task { await self.hooks.reschedule([toReschedule]) }
            }
            toasts.show("Reminder restored", variant: .success)
            reload()
        } catch {
            toasts.showError("Undo failed", message: "Try again.")
        }
    }
}
