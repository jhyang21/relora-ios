import SwiftUI
import ReloraCore
import ReloraData
import ReloraDesign
import ReloraServices

/// The whole app, one level up from any screen.
///
/// Three jobs and no more: pick the root, own the single sheet slot, and mount
/// the toast layer above both so a toast outlives the navigation that caused it.
/// Everything else belongs to the screen below it.
public struct RootView: View {
    @Environment(AppRouter.self) private var router
    @Environment(IdentityController.self) private var identity
    @Environment(SyncOrchestrator.self) private var sync
    @Environment(ReloraToastCenter.self) private var toasts

    private let database: AppDatabase
    private let voice: VoiceCaptureEnvironment
    private let notifications: NotificationEnvironment
    private let billing: BillingService

    /// Read from `app_settings`, not from identity.
    ///
    /// The distinction is the point of this rebuild: signing out returns
    /// identity to `.unresolved`, and a root that keyed onboarding off identity
    /// would throw a returning user back into the welcome flow. See `RootGate`.
    @State private var onboardingCompleted = false
    @State private var hasReadOnboardingFlag = false

    /// - Parameter voice: the recorder, pipeline and quota source the composer
    ///   runs on. Passed in rather than built here so the app target keeps
    ///   every construction decision — the composition root is `AppBootstrap`,
    ///   and a root view that reached for `AVAudioRecorder` on its own would be
    ///   the first crack in that.
    /// - Parameter notifications: the notification scheduler, reconciler and
    ///   priming store the reminder screens and `ContactDetailView`'s delete/
    ///   restore flows run their cancel/reschedule hooks through. Built once
    ///   in `AppBootstrap`, the same reasoning as `voice`.
    /// - Parameter billing: the RevenueCat session, entitlement snapshot and
    ///   product catalog `PaywallView` reads. Built once in `AppBootstrap`;
    ///   `handleIdentityChange` is wired there, not here.
    public init(database: AppDatabase, voice: VoiceCaptureEnvironment, notifications: NotificationEnvironment, billing: BillingService) {
        self.database = database
        self.voice = voice
        self.notifications = notifications
        self.billing = billing
    }

    /// What `ContactDetailView`'s reminder delete/restore and the reminders
    /// screen both call into for cancel/reschedule. Built here rather than
    /// inside `NotificationEnvironment` (ReloraServices) because
    /// `ReminderNotificationHooks` is a ReloraFeatures type — ReloraServices
    /// does not, and must not, depend on ReloraFeatures.
    private var reminderHooks: ReminderNotificationHooks {
        ReminderNotificationHooks(
            cancel: { [notifications] ids in await notifications.scheduler.cancel(ids) },
            reschedule: { [notifications] restorable in await notifications.scheduler.reschedule(restorable) }
        )
    }

    private var destination: RootDestination {
        RootGate.destination(
            identity: identity.identity,
            isBootstrapped: identity.isBootstrapped && hasReadOnboardingFlag,
            onboardingCompleted: onboardingCompleted
        )
    }

    /// The id owning rows on screen, or nil when there is no identity yet.
    ///
    /// Never `identity.identity.ownerUserID` unguarded — that traps while
    /// `.unresolved`, which is a state Home renders in.
    private var activeUserID: String? {
        if case .unresolved = identity.identity { return nil }
        return identity.identity.ownerUserID
    }

    public var body: some View {
        @Bindable var router = router

        ZStack {
            ReloraColor.background.ignoresSafeArea()

            switch destination {
            case .launching:
                // Deliberately empty. Bootstrap is two local reads; a spinner
                // that appears for one frame is worse than a still screen.
                Color.clear

            case .onboarding:
                OnboardingCoordinatorView(
                    database: database,
                    identity: identity,
                    toasts: toasts,
                    router: router,
                    onFinish: { await completeOnboarding() }
                )

            case .home:
                NavigationStack(path: $router.path) {
                    HomeView(database: database, identity: identity)
                        .navigationDestination(for: AppRouter.Route.self) { route in
                            destinationView(route)
                        }
                }
            }
        }
        .reloraToastLayer(toasts)
        .sheet(item: $router.sheet) { sheet in
            sheetView(sheet)
        }
        .onOpenURL { url in
            Task { await router.handle(url, identity: identity) }
        }
        .task {
            await readOnboardingFlag()
            // Bootstrap may already have finished by the time this task
            // runs (identity restores fast); this is the belt to
            // `AppBootstrap.start()`'s suspenders for the notification-tap
            // launch path — either one replaying first leaves nothing for
            // the other to find.
            await router.replayPendingDeepLink(identity: identity)
        }
        .onChange(of: identity.identity) { _, _ in
            // Sign-out and account switches both rewrite what onboarding means
            // for this install, so the flag is re-read rather than cached for
            // the process lifetime.
            Task { await readOnboardingFlag() }
        }
    }

    // MARK: Routes

    @ViewBuilder
    private func destinationView(_ route: AppRouter.Route) -> some View {
        switch route {
        case .contactDetail(let contactID):
            if let userID = activeUserID {
                ContactDetailView(
                    contactID: contactID,
                    userID: userID,
                    database: database,
                    toasts: toasts,
                    hooks: reminderHooks
                )
            } else {
                // Only reachable through a deep link that arrives before any
                // identity exists. There is nothing to show, and saying so beats
                // an empty screen.
                ReloraEmptyState.signedOut { router.present(.authGate) }
            }

        case .reminders:
            RemindersView(database: database, identity: identity, toasts: toasts, hooks: reminderHooks)
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetView(_ sheet: AppRouter.Sheet) -> some View {
        switch sheet {
        case .contactEdit(let target):
            ContactEditView(
                target: target,
                database: database,
                toasts: toasts,
                userIDProvider: { await writableUserID() },
                onSaved: { contactID in
                    if case .new = target {
                        router.showNewlySavedContact(contactID)
                    }
                }
            )

        case .contactPicker:
            ContactPickerSheet { draft in
                // Straight from the system picker into the form, prefilled. The
                // sheet slot holds one thing at a time, so the picker hands over
                // rather than stacking a second modal on itself.
                router.present(.contactEdit(.new(prefill: draft)))
            }

        case .contactImport:
            ContactImportView(
                database: database,
                toasts: toasts,
                userIDProvider: { await writableUserID() }
            )

        case .settings:
            SettingsView(
                database: database,
                identity: identity,
                sync: sync,
                billing: billing,
                voiceAccess: voice.access,
                notifications: notifications,
                toasts: toasts,
                router: router
            )

        case .voiceComposer(let contactID):
            VoiceCaptureComposerView(
                environment: voice,
                initialContactID: contactID,
                toasts: toasts,
                // Each of these hands the single sheet slot to whatever comes
                // next. The composer never dismisses itself and then presents
                // — one slot, one owner, and the router does the swap.
                onSaved: { savedContactID in
                    router.showNewlySavedContact(savedContactID)
                    // A voice-saved reminder lands with notification_id =
                    // NULL on purpose (docs/milestone-notes.md, "M6
                    // outcomes") — nothing schedules it until a
                    // reconciliation pass does, so save triggers one
                    // explicitly here rather than waiting on anything else to
                    // notice.
                    if let userID = activeUserID {
                        Task { await notifications.reconciler.rescheduleAll(userID: userID, trigger: .voiceCaptureSaved) }
                    }
                },
                onPaywall: { reason in
                    router.present(.paywall(reason: reason))
                },
                onSignIn: {
                    // The one call site this milestone was asked to wire:
                    // RN's "Sign in to finish this note" copy
                    // (`AuthGateSource.voiceCapture`) becomes reachable here.
                    router.presentAuthGate(AuthGateContext(action: .signIn, source: .voiceCapture))
                },
                onClose: {
                    router.dismissSheet()
                }
            )

        case .paywall(let reason):
            PaywallView(reason: reason, billing: billing, identity: identity, toasts: toasts)

        case .authGate:
            AuthGateView(context: router.authGateContext, identity: identity, toasts: toasts)

        case .setNewPassword:
            SetNewPasswordView(identity: identity, toasts: toasts)

        case .addReminder(let contactID, let contactName):
            AddReminderView(
                contactID: contactID,
                contactName: contactName,
                database: database,
                notifications: notifications,
                userIDProvider: { await writableUserID() },
                onCancel: { router.dismissSheet() },
                onSaved: { router.dismissSheet() }
            )
        }
    }

    // MARK: Identity and settings

    /// The id a write should belong to, minting a local guest identity if this
    /// install has none.
    ///
    /// Identity appears the first time someone creates something — never at
    /// launch, and never to render a screen.
    private func writableUserID() async -> String {
        if let activeUserID { return activeUserID }
        return await identity.ensureLocalGuestSession()
    }

    private func readOnboardingFlag() async {
        let database = self.database
        let completed = await Task.detached(priority: .userInitiated) {
            (try? AppSettingsStore(database: database)
                .getBooleanStrict(.onboardingCompleted)) ?? false
        }.value

        onboardingCompleted = completed
        hasReadOnboardingFlag = true
    }

    private func completeOnboarding() async {
        let database = self.database
        await Task.detached(priority: .userInitiated) {
            try? AppSettingsStore(database: database)
                .setBoolean(.onboardingCompleted, true)
        }.value
        onboardingCompleted = true
    }
}

// MARK: - Placeholders
//
// `OnboardingPlaceholderView` and `MilestonePlaceholderSheet` were removed by
// M10: the real onboarding flow, Settings screen, and set-new-password
// screen replaced their last call sites (`.onboarding`, `.settings`,
// `.setNewPassword` above) — grepped before deleting, nothing else in the
// app target referenced either.
