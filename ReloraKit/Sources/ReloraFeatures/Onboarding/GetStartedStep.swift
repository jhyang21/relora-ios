import SwiftUI
import ReloraCore
import ReloraData
import ReloraDesign
import ReloraServices

/// Ports `getStartedActions.ts` and the state `GetStartedStep.tsx` loads on
/// appear.
@MainActor
@Observable
public final class GetStartedViewModel {
    public private(set) var isLoading = false
    public private(set) var copy: GetStartedCopy
    public private(set) var tutorialContactID: String?

    private let database: AppDatabase
    private let identity: IdentityController
    private let storage: OnboardingStorage
    private let router: AppRouter
    private let onFinish: () async -> Void

    public init(
        database: AppDatabase,
        identity: IdentityController,
        storage: OnboardingStorage,
        router: AppRouter,
        onFinish: @escaping () async -> Void
    ) {
        self.database = database
        self.identity = identity
        self.storage = storage
        self.router = router
        self.onFinish = onFinish
        // Matches RN's `DEFAULT_GET_STARTED_COPY`: rendered for the one
        // frame before `load()`'s async read of the personalization and
        // tutorial state returns.
        self.copy = GetStartedCopyBuilder.build(audience: [], exampleContactName: TutorialSeed.contactName, tutorialCompleted: false)
    }

    public func load() {
        // A device holding an older persona's contact still has that
        // contact — ignore it rather than open it or name the new persona
        // in the copy. Mirrors the `hasCurrentTutorialExample` check in
        // GetStartedStep.tsx's load effect.
        let tutorialState = storage.readTutorialState()
        let hasExample = tutorialState.isCurrent
        tutorialContactID = hasExample ? tutorialState.contactID : nil
        copy = GetStartedCopyBuilder.build(
            audience: storage.readAudience(),
            exampleContactName: TutorialSeed.contactName,
            tutorialCompleted: hasExample
        )
    }

    /// Mirrors `runSeeYourExampleAction`. Ensures a local identity exists
    /// (a skipper reaching this button has never created one), marks
    /// onboarding complete, then opens the app — landing directly on the
    /// tutorial contact when there is one to show.
    public func seeYourExample() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        _ = await identity.ensureLocalGuestSession()

        if let tutorialContactID, contactStillExists(tutorialContactID) {
            router.path = [.contactDetail(contactID: tutorialContactID)]
        }
        await onFinish()
    }

    private func contactStillExists(_ contactID: String) -> Bool {
        guard case .unresolved = identity.identity else {
            let userID = identity.identity.ownerUserID
            let matches = (try? ContactRepository(database: database).getContactsByIDs([contactID], userID: userID)) ?? []
            return !matches.isEmpty
        }
        return false
    }

    /// Mirrors `runOpenAccountAction`, minus the pending-auth-intent write:
    /// RN persists `{ action: 'sign-in', source: 'onboarding' }` so a
    /// resumed session can pick the sign-in flow back up; native's
    /// `IdentityController` has no matching resume-intent seam, and adding
    /// one is outside this milestone's file ownership. The auth sheet opens
    /// either way — only the "remember why it opened across a kill"
    /// behavior is missing. `AuthGateSource` also has no `.onboarding`
    /// case, so this uses `.settings`, the same choice already made for
    /// Settings' own account entry point.
    public func openAccount() {
        router.presentAuthGate(AuthGateContext(action: .signIn, source: .settings))
    }
}

/// Ports `GetStartedStep.tsx`.
struct GetStartedStepView: View {
    @State private var viewModel: GetStartedViewModel

    init(
        database: AppDatabase,
        identity: IdentityController,
        storage: OnboardingStorage,
        router: AppRouter,
        onFinish: @escaping () async -> Void
    ) {
        _viewModel = State(wrappedValue: GetStartedViewModel(
            database: database,
            identity: identity,
            storage: storage,
            router: router,
            onFinish: onFinish
        ))
    }

    private var primaryLabel: String {
        if viewModel.isLoading { return "Opening..." }
        return viewModel.tutorialContactID != nil ? "See your example" : "Enter Relora"
    }

    var body: some View {
        OnboardingStepContainer(
            stepIndex: OnboardingStep.getStarted.rawValue,
            totalSteps: OnboardingStep.allCases.count,
            // GetStarted offers no skip — ported faithfully; see
            // `OnboardingStep.skipDestination`'s doc comment.
            onSkip: nil
        ) {
            OnboardingHeroCard {
                Text(viewModel.copy.heading)
                    .font(ReloraFont.title3)
                    .foregroundStyle(ReloraColor.ink)
                Text(viewModel.copy.body)
                    .font(ReloraFont.body)
                    .foregroundStyle(ReloraColor.mutedInk)
                Text("\(QuotaPolicy.freeNoteLimit) notes still free")
                    .font(ReloraFont.footnote)
                    .fontWeight(.bold)
                    .foregroundStyle(ReloraColor.ink)
                    .padding(.horizontal, ReloraSpacing.md)
                    .padding(.vertical, ReloraSpacing.sm)
                    .background(Capsule().fill(ReloraColor.card))
            }
        } footer: {
            // No accessibility label: `primaryLabel` also reads "Enter Relora"
            // for a user who skipped the example, and "Opening..." while the
            // action runs. The visible text is the honest one.
            Button(primaryLabel) {
                Task { await viewModel.seeYourExample() }
            }
            .buttonStyle(.reloraPrimary)
            .disabled(viewModel.isLoading)

            Button("Create account / Sign in") {
                viewModel.openAccount()
            }
            .buttonStyle(.reloraSecondary)
            .disabled(viewModel.isLoading)
            .accessibilityLabel("Create account or sign in")
        }
        .task {
            viewModel.load()
        }
    }
}
