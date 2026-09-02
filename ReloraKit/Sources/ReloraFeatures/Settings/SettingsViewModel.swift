import Foundation
import ReloraCore
import ReloraData
import ReloraServices

/// Drives `SettingsView`. Ports the state and actions `SettingsScreen.tsx`
/// builds from `useAppState`/`useSyncState` plus `settingsActions.ts`'s
/// `run*Action` helpers, collapsed into one `@Observable` model since native
/// has no equivalent app-wide context to read them from directly.
@MainActor
@Observable
public final class SettingsViewModel {
    public enum ActiveSetting: Equatable, Sendable {
        case reminders, transcripts
    }

    public private(set) var reminderNotificationsEnabled: Bool
    public private(set) var saveVoiceTranscriptsEnabled: Bool
    public private(set) var activeSetting: ActiveSetting?
    public private(set) var syncing = false
    public private(set) var restoring = false
    public private(set) var deletingAccount = false
    public private(set) var planSummary: SettingsPlanCopy.Summary
    public private(set) var exportedFileURL: URL?

    /// Set true when the OS refuses notification permission on enable —
    /// mirrors RN's `Alert.alert('Notifications permission needed', ...)`
    /// branch. The view reads and clears this to drive its own `.alert`.
    public var showNotificationPermissionAlert = false

    private let database: AppDatabase
    private let identity: IdentityController
    private let sync: SyncOrchestrator
    private let billing: BillingService
    private let voiceAccess: any VoiceAccessProviding
    private let notifications: NotificationEnvironment
    private let toasts: ReloraToastCenter
    private let router: AppRouter
    private let settings: AppSettingsStore

    public init(
        database: AppDatabase,
        identity: IdentityController,
        sync: SyncOrchestrator,
        billing: BillingService,
        voiceAccess: any VoiceAccessProviding,
        notifications: NotificationEnvironment,
        toasts: ReloraToastCenter,
        router: AppRouter
    ) {
        self.database = database
        self.identity = identity
        self.sync = sync
        self.billing = billing
        self.voiceAccess = voiceAccess
        self.notifications = notifications
        self.toasts = toasts
        self.router = router
        self.settings = AppSettingsStore(database: database)

        reminderNotificationsEnabled = (try? settings.reminderNotificationsEnabled()) ?? AppSettingsDefaults.reminderNotificationsEnabled
        saveVoiceTranscriptsEnabled = (try? settings.saveVoiceTranscripts()) ?? AppSettingsDefaults.saveVoiceTranscripts
        planSummary = SettingsPlanCopy.build(subscription: billing.subscriptionSnapshot, evaluation: VoiceAccessSnapshot.freeAndUnused.evaluation)
    }

    // MARK: - Identity-derived state

    public var isAccount: Bool {
        if case .account = identity.identity { return true }
        return false
    }

    /// The real RevenueCat entitlement, for the "Upgrade your plan" row's
    /// visibility — matches RN's `accessSnapshot.planId !== 'pro'`, and
    /// `SettingsPlanCopy.build`'s own choice to key off the real
    /// subscription rather than `evaluation.planID` (see its doc comment).
    public var planID: QuotaPolicy.PlanID {
        billing.subscriptionSnapshot.planID
    }

    public var accountEmail: String? {
        if case .account(_, let email) = identity.identity { return email }
        return nil
    }

    private var resolvedUserID: String? {
        guard case .unresolved = identity.identity else { return identity.identity.ownerUserID }
        return nil
    }

    // MARK: - Load

    /// Refreshes the plan summary against the real evaluation. Called from
    /// `.task` — `accessSnapshot` reads local usage, which can change while
    /// Settings is closed.
    public func load() async {
        let snapshot = await voiceAccess.accessSnapshot(userID: resolvedUserID)
        planSummary = SettingsPlanCopy.build(subscription: billing.subscriptionSnapshot, evaluation: snapshot.evaluation)
    }

    // MARK: - Sync

    /// Qualitative status copy in place of RN's `Last synced: {formatted}` —
    /// `SyncOrchestrator` exposes `status`/`isOnline` but no last-sync
    /// timestamp (no equivalent to RN's `sync_state.last_sync_at` read), a
    /// gap flagged in the M10 report rather than silently worked around.
    public var syncStatusLabel: String {
        switch sync.status {
        case .syncing:
            return "Syncing..."
        case .failed:
            return sync.isOnline ? "Sync failed. Will retry automatically." : "Sync failed while offline. Will retry when back online."
        case .idle:
            return sync.isOnline ? "Synced" : "Offline. Will sync when back online."
        }
    }

    public func syncNow() async {
        guard isAccount else {
            router.presentAuthGate(AuthGateContext(action: .signIn, source: .settings))
            return
        }
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        await sync.sync(reason: "settings-manual")
    }

    // MARK: - Toggles

    /// Mirrors `onToggleReminderNotifications`. An `.unresolved` identity
    /// (post sign-out, or before onboarding ever minted one) has no owned
    /// reminders reachable by id — sign-out keeps local rows on disk but
    /// under an identity nothing here can address — so the flag is simply
    /// persisted with no scheduling side effect, the same no-op RN's own
    /// null-`userId` path effectively produces.
    public func toggleReminderNotifications(_ value: Bool) async {
        guard activeSetting == nil else { return }
        activeSetting = .reminders
        defer { activeSetting = nil }

        guard let userID = resolvedUserID else {
            do {
                try settings.setBoolean(.reminderNotificationsEnabled, value)
                reminderNotificationsEnabled = value
            } catch {
                toasts.showError("Setting failed", message: "Could not update reminder notifications.")
            }
            return
        }

        do {
            if value {
                try await ReminderNotificationsToggle.enable(userID: userID, database: database, settings: settings, notifications: notifications)
            } else {
                try await ReminderNotificationsToggle.disable(userID: userID, database: database, settings: settings, notifications: notifications)
            }
            reminderNotificationsEnabled = value
        } catch ReminderNotificationsToggle.ToggleError.permissionDenied {
            showNotificationPermissionAlert = true
        } catch {
            toasts.showError("Setting failed", message: "Could not update reminder notifications.")
        }
    }

    public func toggleSaveVoiceTranscripts(_ value: Bool) async {
        guard activeSetting == nil else { return }
        activeSetting = .transcripts
        defer { activeSetting = nil }
        do {
            try settings.setBoolean(.saveVoiceTranscripts, value)
            saveVoiceTranscriptsEnabled = value
        } catch {
            toasts.showError("Setting failed", message: "Could not update transcript retention.")
        }
    }

    // MARK: - Export

    /// Mirrors `runExportAction`: a no-op with no identity to export under,
    /// same as RN's early return on a null `userId`.
    public func exportData() {
        guard let userID = resolvedUserID else { return }
        do {
            exportedFileURL = try DataExport.export(userID: userID, database: database)
        } catch {
            toasts.showError("Export failed", message: "Could not export data.")
        }
    }

    public func clearExportedFile() {
        exportedFileURL = nil
    }

    // MARK: - Account

    /// Mirrors `runSignOutAction`. No explicit navigation reset: identity
    /// dropping to `.unresolved` is exactly the change `RootGate` now reacts
    /// to on its own (the M10 fix — see the report), landing on signed-out
    /// Home. Only the sheet needs dismissing so that Home is what's visible.
    public func confirmSignOut() async {
        do {
            try await identity.signOut()
            router.dismissSheet()
        } catch {
            toasts.showError("Sign out failed", message: "Could not sign out.")
        }
    }

    /// Mirrors `runDeleteAccountAction`.
    public func confirmDeleteAccount() async {
        guard !deletingAccount else { return }
        deletingAccount = true
        do {
            try await identity.deleteAccount()
            deletingAccount = false
            router.dismissSheet()
        } catch {
            deletingAccount = false
            toasts.showError("Delete failed", message: "Could not delete account.")
        }
    }

    public func openAccountAuth() {
        router.presentAuthGate(AuthGateContext(action: .signIn, source: .settings))
    }

    public func openUpgrade() {
        router.present(.paywall(reason: .manual))
    }

    public func openContactImport() {
        router.present(.contactImport)
    }

    /// Mirrors the `showAlert` fallback every `run*Action` in
    /// `settingsActions.ts` takes when opening a URL (browser, mailto)
    /// fails — a manual "open this yourself" message on the one toast slot.
    public func reportLinkOpenFailure(_ title: String, _ message: String) {
        toasts.showError(title, message: message)
    }

    // MARK: - Restore purchases

    /// Mirrors `runRestorePurchasesAction`. RN persists a pending restore
    /// intent so the auth gate can resume the restore automatically once
    /// signed in; `IdentityController` has no matching resume-intent seam
    /// (the same gap `GetStartedViewModel.openAccount()` notes), so a guest
    /// who taps this is sent to sign in and must tap Restore again
    /// afterward — flagged in the M10 report.
    public func restorePurchases() async {
        guard isAccount else {
            router.presentAuthGate(AuthGateContext(action: .restore, source: .settings))
            return
        }
        guard !restoring else { return }
        restoring = true
        defer { restoring = false }

        switch await billing.restorePurchases() {
        case .restored(let snapshot):
            toasts.show("Purchases restored", message: "Your \(Self.planName(snapshot.planID)) plan is active on this device.", variant: .success)
        case .noPurchasesFound:
            toasts.show("No purchases found", message: "We could not find an active subscription to restore.", variant: .info)
        case .requiresAccount:
            router.presentAuthGate(AuthGateContext(action: .restore, source: .settings))
        case .failed(let message):
            toasts.show("Restore unavailable", message: message, variant: .error)
        }
    }

    private static func planName(_ planID: QuotaPolicy.PlanID) -> String {
        switch planID {
        case .free: return "Free"
        case .plus: return "Plus"
        case .pro: return "Pro"
        }
    }
}
