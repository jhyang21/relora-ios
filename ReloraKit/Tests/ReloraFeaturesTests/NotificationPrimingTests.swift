import Foundation
import Testing
import ReloraData
import ReloraServices

// MARK: - decide(_:) decision order

@Suite("ReminderNotificationPriming.decide")
struct NotificationPrimingDecisionTests {
    private func context(
        notificationsEnabled: Bool = true,
        authorizationStatus: NotificationAuthorizationStatus = .notDetermined,
        primedThisSession: Bool = false,
        declineCount: Int = 0
    ) -> ReminderNotificationPrimingContext {
        ReminderNotificationPrimingContext(
            notificationsEnabled: notificationsEnabled,
            authorizationStatus: authorizationStatus,
            primedThisSession: primedThisSession,
            declineCount: declineCount
        )
    }

    @Test("Every condition satisfied primes")
    func primesWhenEverythingSaysYes() {
        #expect(ReminderNotificationPriming.decide(context()) == .prime)
    }

    @Test("The reminder_notifications_enabled setting being off skips before anything else is checked")
    func settingOffSkipsFirst() {
        #expect(ReminderNotificationPriming.decide(context(notificationsEnabled: false)) == .skip)
    }

    @Test("Any settled OS authorization — authorized, provisional, or denied — skips; only notDetermined can prime")
    func settledAuthorizationSkips() {
        #expect(ReminderNotificationPriming.decide(context(authorizationStatus: .authorized)) == .skip)
        #expect(ReminderNotificationPriming.decide(context(authorizationStatus: .provisional)) == .skip)
        #expect(ReminderNotificationPriming.decide(context(authorizationStatus: .denied)) == .skip)
        #expect(ReminderNotificationPriming.decide(context(authorizationStatus: .notDetermined)) == .prime)
    }

    @Test("Already primed this session skips, so the sheet never doubles up in one launch")
    func primedThisSessionSkips() {
        #expect(ReminderNotificationPriming.decide(context(primedThisSession: true)) == .skip)
    }

    @Test("A decline count at or past the max of 3 skips for good")
    func maxDeclinesSkips() {
        #expect(ReminderNotificationPriming.decide(context(declineCount: 2)) == .prime)
        #expect(ReminderNotificationPriming.decide(context(declineCount: 3)) == .skip)
        #expect(ReminderNotificationPriming.decide(context(declineCount: 4)) == .skip)
    }
}

// MARK: - ReminderNotificationPrimingStore

@Suite("ReminderNotificationPrimingStore")
struct NotificationPrimingStoreTests {
    @Test("declineCount reads 0 when no row has ever been written")
    func declineCountDefaultsToZero() throws {
        let database = try AppDatabase.inMemory()
        let store = ReminderNotificationPrimingStore(database: database)
        #expect(store.declineCount() == 0)
    }

    @Test("recordDecline increments and persists across a new store instance")
    func recordDeclineIncrementsAndPersists() throws {
        let database = try AppDatabase.inMemory()
        let store = ReminderNotificationPrimingStore(database: database)

        store.recordDecline()
        store.recordDecline()
        #expect(store.declineCount() == 2)

        // A fresh instance over the same database sees the same count — the
        // counter lives in app_settings, not in-memory state on the store.
        #expect(ReminderNotificationPrimingStore(database: database).declineCount() == 2)
    }

    @Test("reset clears the counter back to 0, as a grant does")
    func resetClearsCounter() throws {
        let database = try AppDatabase.inMemory()
        let store = ReminderNotificationPrimingStore(database: database)

        store.recordDecline()
        store.recordDecline()
        store.recordDecline()
        #expect(store.declineCount() == 3)

        store.reset()
        #expect(store.declineCount() == 0)
    }
}
