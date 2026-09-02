import Testing
import ReloraSync
@testable import ReloraFeatures

/// Pins `SettingsSyncCopy.footer` — the Account section's always-present
/// sync sentence, one per `SyncStatus` / online combination.
struct SettingsSyncCopyTests {
    @Test func syncing() {
        #expect(SettingsSyncCopy.footer(.syncing, isOnline: true) == "Syncing…")
    }

    @Test func failedOnline() {
        #expect(SettingsSyncCopy.footer(.failed, isOnline: true) == "Sync failed. Relora will retry automatically.")
    }

    @Test func failedOffline() {
        #expect(SettingsSyncCopy.footer(.failed, isOnline: false) == "Offline. Relora will retry when you're back online.")
    }

    @Test func idleOnline() {
        #expect(SettingsSyncCopy.footer(.idle, isOnline: true) == "Synced.")
    }

    @Test func idleOffline() {
        #expect(SettingsSyncCopy.footer(.idle, isOnline: false) == "Offline. Relora syncs when you're back online.")
    }
}
