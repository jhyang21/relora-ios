import Foundation
import ReloraCore
import ReloraData
import ReloraDesign
import ReloraServices
import ReloraSync

/// What Settings opens on top of itself.
///
/// Settings is a modal that is also a workspace: every one of these is a
/// sub-screen of it, and closing one has to come back here rather than to
/// Home. So they use a local sheet slot instead of the router's single
/// app-wide one. See `AppRouter`'s note on the exception.
public enum SettingsSheet: Identifiable, Equatable, Sendable {
    case paywall(reason: AppRouter.PaywallReason)
    case authGate(AuthGateContext)
    case contactImport
    case export(URL)

    public var id: String {
        switch self {
        case .paywall(let reason):
            return "paywall-\(reason.rawValue)"
        case .authGate(let context):
            return "authGate-\(context.action)-\(context.source)"
        case .contactImport:
            return "contactImport"
        case .export(let url):
            return "export-\(url.absoluteString)"
        }
    }
}

/// Drives `SettingsView`: the toggles, the plan and sync copy, and every
/// action a row can take.
@MainActor
@Observable
public final class SettingsViewModel {
    public private(set) var reminderNotificationsEnabled: Bool
    public private(set) var saveVoiceTranscriptsEnabled: Bool
    public private(set) var togglingReminders = false
    public private(set) var syncing = false
    public private(set) var restoring = false
    public private(set) var deletingAccount = false
    public private(set) var planName: String
    public private(set) var usageFooter: String

    /// The sub-screen showing over Settings, if any.
    public var presentedSheet: SettingsSheet?

    /// Set true when the OS refuses notification permission on enable. The
    /// view reads and clears this to drive its own alert.
    public var showNotificationPermissionAlert = false

    /// Re-entrancy guard only. The transcripts toggle writes one row and
    /// comes back immediately, so it never disables itself on screen.
    private var togglingTranscripts = false

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

        let subscription = billing.subscriptionSnapshot
        planName = SettingsPlanCopy.planName(subscription)
        // Placeholder until `load()` reads real usage. See
        // `SettingsPlanCopy.usageFooter` for why this is not `?? 0`.
        usageFooter = SettingsPlanCopy.usageFooter(
            subscription: subscription,
            evaluation: VoiceAccessSnapshot.freeAndUnused.evaluation
        )
    }

    // MARK: - Identity-derived state

    public var isAccount: Bool {
        if case .account = identity.identity { return true }
        return false
    }

    /// The real RevenueCat entitlement, which decides whether the See Plans
    /// and Manage Subscription rows appear.
    private var planID: QuotaPolicy.PlanID {
        billing.subscriptionSnapshot.planID
    }

    public var accountEmail: String? {
        if case .account(_, let email) = identity.identity { return email }
        return nil
    }

    public var showsSeePlans: Bool { planID != .pro }

    public var showsManageSubscription: Bool { planID != .free }

    /// There is nothing to export before an identity owns rows.
    public var canExport: Bool { resolvedUserID != nil }

    public var syncFooter: String {
        SettingsSyncCopy.footer(sync.status, isOnline: sync.isOnline)
    }

    private var resolvedUserID: String? {
        if case .unresolved = identity.identity { return nil }
        return identity.identity.ownerUserID
    }

    // MARK: - Load

    /// Refreshes the plan copy against real usage. Called from `.task` and
    /// after any sub-screen closes — usage and entitlement both change while
    /// Settings is covered.
    public func load() async {
        let snapshot = await voiceAccess.accessSnapshot(userID: resolvedUserID)
        let subscription = billing.subscriptionSnapshot
        planName = SettingsPlanCopy.planName(subscription)
        usageFooter = SettingsPlanCopy.usageFooter(subscription: subscription, evaluation: snapshot.evaluation)
    }

    // MARK: - Sync

    public func syncNow() async {
        guard isAccount else {
            presentedSheet = .authGate(AuthGateContext(action: .signIn, source: .settings))
            return
        }
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        await sync.sync(reason: "settings-manual")
    }

    // MARK: - Toggles

    /// The switch moves first and moves back if the write fails, so the row
    /// never lags a tap.
    ///
    /// An `.unresolved` identity (post sign-out, or before onboarding ever
    /// minted one) has no owned reminders reachable by id, so the flag is
    /// persisted with no scheduling side effect.
    public func toggleReminderNotifications(_ value: Bool) async {
        guard !togglingReminders else { return }
        togglingReminders = true
        defer { togglingReminders = false }

        let previous = reminderNotificationsEnabled
        reminderNotificationsEnabled = value

        guard let userID = resolvedUserID else {
            do {
                try settings.setBoolean(.reminderNotificationsEnabled, value)
            } catch {
                reminderNotificationsEnabled = previous
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
        } catch ReminderNotificationsToggle.ToggleError.permissionDenied {
            reminderNotificationsEnabled = previous
            showNotificationPermissionAlert = true
        } catch {
            reminderNotificationsEnabled = previous
            toasts.showError("Setting failed", message: "Could not update reminder notifications.")
        }
    }

    public func toggleSaveVoiceTranscripts(_ value: Bool) async {
        guard !togglingTranscripts else { return }
        togglingTranscripts = true
        defer { togglingTranscripts = false }

        let previous = saveVoiceTranscriptsEnabled
        saveVoiceTranscriptsEnabled = value
        do {
            try settings.setBoolean(.saveVoiceTranscripts, value)
        } catch {
            saveVoiceTranscriptsEnabled = previous
            toasts.showError("Setting failed", message: "Could not update transcript retention.")
        }
    }

    // MARK: - Export

    /// A no-op with no identity to export under. The row is hidden in that
    /// case; this guard is the belt to it.
    public func exportData() {
        guard let userID = resolvedUserID else { return }
        do {
            let url = try DataExport.export(userID: userID, database: database)
            presentedSheet = .export(url)
        } catch {
            toasts.showError("Export failed", message: "Could not export data.")
        }
    }

    // MARK: - Account

    /// No explicit navigation reset: identity dropping to `.unresolved` is
    /// exactly the change `RootGate` reacts to on its own, landing on
    /// signed-out Home. Only the sheet needs dismissing so Home is visible.
    public func confirmSignOut() async {
        do {
            try await identity.signOut()
            router.dismissSheet()
        } catch {
            toasts.showError("Sign out failed", message: "Could not sign out.")
        }
    }

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
        presentedSheet = .authGate(AuthGateContext(action: .signIn, source: .settings))
    }

    public func openUpgrade() {
        presentedSheet = .paywall(reason: .manual)
    }

    public func openContactImport() {
        presentedSheet = .contactImport
    }

    /// What the view calls when opening a URL (browser, mail) is refused —
    /// a manual "open this yourself" message on the one toast slot.
    public func reportLinkOpenFailure(_ title: String, _ message: String) {
        toasts.showError(title, message: message)
    }

    // MARK: - Restore purchases

    /// `IdentityController` has no resume-intent seam, so a guest who taps
    /// this is sent to sign in and must tap Restore again afterward. RN
    /// persisted the intent and resumed it; flagged in the M10 report.
    public func restorePurchases() async {
        guard isAccount else {
            presentedSheet = .authGate(AuthGateContext(action: .restore, source: .settings))
            return
        }
        guard !restoring else { return }
        restoring = true
        defer { restoring = false }

        switch await billing.restorePurchases() {
        case .restored(let snapshot):
            toasts.show(
                "Purchases restored",
                message: "Your \(SettingsPlanCopy.planName(snapshot)) plan is active on this device.",
                variant: .success
            )
        case .noPurchasesFound:
            toasts.show("No purchases found", message: "We could not find an active subscription to restore.", variant: .info)
        case .requiresAccount:
            presentedSheet = .authGate(AuthGateContext(action: .restore, source: .settings))
        case .failed(let message):
            toasts.show("Restore unavailable", message: message, variant: .error)
        }
    }
}
