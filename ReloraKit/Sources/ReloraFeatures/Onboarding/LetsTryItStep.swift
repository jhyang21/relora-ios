import SwiftUI
import ReloraCore
import ReloraData
import ReloraDesign
import ReloraServices

/// Ports `letsTryItActions.ts`'s two actions and the phase machine
/// `LetsTryItStep.tsx` reads (`LetsTryItPhase`).
@MainActor
@Observable
public final class LetsTryItViewModel {
    public enum Phase: Equatable, Sendable {
        case idle, processing, saving, completed
    }

    public private(set) var phase: Phase = .idle
    public private(set) var isLoading = false

    private let database: AppDatabase
    private let identity: IdentityController
    private let storage: OnboardingStorage
    private let toasts: ReloraToastCenter

    public init(database: AppDatabase, identity: IdentityController, storage: OnboardingStorage, toasts: ReloraToastCenter) {
        self.database = database
        self.identity = identity
        self.storage = storage
        self.toasts = toasts
    }

    /// Mirrors `runLetsTryItAction`. Returns whether the step should advance
    /// to GetStarted — the view owns navigation, this only owns the write
    /// and the phase the status card reads.
    public func createExample() async -> Bool {
        guard !isLoading else { return false }
        isLoading = true
        defer { isLoading = false }

        do {
            if let contactID = reusableTutorialContactID() {
                try await settle(contactID: contactID, delayNanoseconds: 150_000_000)
                return true
            }

            phase = .processing
            try await Task.sleep(nanoseconds: 350_000_000)
            let userID = await identity.ensureLocalGuestSession()

            phase = .saving
            try await Task.sleep(nanoseconds: 450_000_000)

            let seeded = try OnboardingTutorialSeedWriter.seed(userID: userID, database: database, storage: storage)
            try await settle(contactID: seeded.contactID, delayNanoseconds: 300_000_000)
            return true
        } catch {
            phase = .idle
            toasts.showError("Could not create your example", message: "Please try again.")
            return false
        }
    }

    /// A stored example is reusable only if this build's persona seeded it
    /// (`TutorialState.isCurrent`) and the contact it points at still
    /// exists locally — mirrors `canReuseTutorialExample`.
    ///
    /// The `.unresolved` guard has no RN counterpart: RN's reuse branch
    /// never re-derives an identity because a stored tutorial contact can
    /// only exist under an identity that was already resolved to create it,
    /// and local data (tutorial state included) is wiped alongside identity
    /// on sign-out — so a *currently* `.unresolved` identity can never carry
    /// a reusable tutorial contact. The guard exists only to keep
    /// `identity.ownerUserID` (which traps on `.unresolved`) from being
    /// called at all in the one case it would be unsafe, not to add new
    /// behavior.
    private func reusableTutorialContactID() -> String? {
        guard case .unresolved = identity.identity else {
            let state = storage.readTutorialState()
            guard state.isCurrent, let contactID = state.contactID else { return nil }
            let userID = identity.identity.ownerUserID
            let matches = (try? ContactRepository(database: database).getContactsByIDs([contactID], userID: userID)) ?? []
            return matches.isEmpty ? nil : contactID
        }
        return nil
    }

    private func settle(contactID: String, delayNanoseconds: UInt64) async throws {
        storage.writeTutorialState(
            OnboardingStorage.TutorialState(
                completed: true,
                contactID: contactID,
                seedVersion: AppSettingsKey.onboardingTutorialSeedVersionValue
            )
        )
        storage.writeStep(OnboardingStep.getStarted.rawValue)
        phase = .completed
        try await Task.sleep(nanoseconds: delayNanoseconds)
    }

    /// Mirrors `runSkipLetsTryItAction`. Refused while a create is in
    /// flight: that create cannot be cancelled, so skipping mid-flight would
    /// navigate to GetStarted while the running create went on to take an
    /// identity, seed the example, and request the same navigation a second
    /// time on its own. Tutorial state is left untouched either way, so an
    /// example created on an earlier pass through this step stays reachable.
    public func skip() -> Bool {
        guard !isLoading else { return false }
        storage.writeStep(OnboardingStep.letsTryIt.skipDestination?.rawValue ?? OnboardingStep.getStarted.rawValue)
        return true
    }
}

/// Ports `LetsTryItStep.tsx`.
struct LetsTryItStepView: View {
    @State private var viewModel: LetsTryItViewModel
    let onAdvance: () -> Void

    init(
        database: AppDatabase,
        identity: IdentityController,
        storage: OnboardingStorage,
        toasts: ReloraToastCenter,
        onAdvance: @escaping () -> Void
    ) {
        _viewModel = State(wrappedValue: LetsTryItViewModel(database: database, identity: identity, storage: storage, toasts: toasts))
        self.onAdvance = onAdvance
    }

    private var statusCopy: (title: String, detail: String)? {
        switch viewModel.phase {
        case .idle:
            return nil
        case .processing:
            return ("Reading the example note...", "Turning the sample script into contact details, key things, and a reminder.")
        case .saving:
            return ("Saving your example...", "Saving \(TutorialSeed.contactName) to this device.")
        case .completed:
            return ("Example ready", "Your \(TutorialSeed.contactName) example is ready.")
        }
    }

    private var primaryLabel: String {
        viewModel.isLoading ? "Creating..." : "Create my example"
    }

    var body: some View {
        OnboardingStepContainer(
            stepIndex: OnboardingStep.letsTryIt.rawValue,
            totalSteps: OnboardingStep.allCases.count,
            onSkip: handleSkip,
            skipDisabled: viewModel.isLoading
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: ReloraSpacing.md) {
                    OnboardingHeroCard {
                        Text("Let's try it")
                            .font(ReloraFont.title3)
                            .foregroundStyle(ReloraColor.ink)
                        Text("Here's a made-up voice note. We'll turn it into an example on this device so you can see how Relora files things. You can skip this.")
                            .font(ReloraFont.body)
                            .foregroundStyle(ReloraColor.mutedInk)
                    }

                    labeledCard(label: "Sample voice note") {
                        Text(TutorialSeed.transcript)
                            .font(ReloraFont.body)
                            .foregroundStyle(ReloraColor.ink)
                    }

                    if let statusCopy {
                        VStack(alignment: .leading, spacing: ReloraSpacing.xs) {
                            Text(statusCopy.title)
                                .font(ReloraFont.body)
                                .fontWeight(.bold)
                                .foregroundStyle(ReloraColor.ink)
                            Text(statusCopy.detail)
                                .font(ReloraFont.body)
                                .foregroundStyle(ReloraColor.mutedInk)
                        }
                        .padding(ReloraSpacing.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .reloraSurface(ReloraColor.warmCard, radius: ReloraRadius.lg)
                        .accessibilityElement(children: .combine)
                    }

                    labeledCard(label: "What we'll create") {
                        VStack(alignment: .leading, spacing: ReloraSpacing.md) {
                            previewItem(title: "Contact", value: TutorialSeed.contactName)
                            previewItem(title: "Memory", value: TutorialSeed.Preview.standard.memoryText)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("KEY THINGS")
                                    .font(ReloraFont.footnote)
                                    .foregroundStyle(ReloraColor.mutedInk)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(TutorialSeed.Preview.standard.keyThingTexts, id: \.self) { text in
                                    Text(text)
                                        .font(ReloraFont.body)
                                        .foregroundStyle(ReloraColor.ink)
                                }
                            }
                            previewItem(title: "Reminder", value: TutorialSeed.reminderTitle)
                        }
                    }
                }
                .padding(.vertical, ReloraSpacing.md)
            }
        } footer: {
            // No accessibility label: the visible text carries the loading
            // state ("Creating..."), which a fixed label would hide.
            Button(primaryLabel, action: handleCreate)
                .buttonStyle(.reloraPrimary)
                .disabled(viewModel.isLoading)
        }
    }

    @ViewBuilder
    private func labeledCard<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: ReloraSpacing.md) {
            Text(label.uppercased())
                .font(ReloraFont.footnote)
                .foregroundStyle(ReloraColor.mutedInk)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(ReloraSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .reloraSurface(ReloraColor.card, radius: ReloraRadius.lg)
    }

    private func previewItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(ReloraFont.footnote)
                .foregroundStyle(ReloraColor.mutedInk)
            Text(value)
                .font(ReloraFont.body)
                .foregroundStyle(ReloraColor.ink)
        }
        // A caption and its value are one fact, not two swipes.
        .accessibilityElement(children: .combine)
    }

    private func handleCreate() {
        Task {
            if await viewModel.createExample() {
                onAdvance()
            }
        }
    }

    private func handleSkip() {
        if viewModel.skip() {
            onAdvance()
        }
    }
}
