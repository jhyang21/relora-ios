import SwiftUI
import ReloraCore
import ReloraDesign

/// The voice composer: record, wait, review, save.
///
/// One sheet for the whole flow, as RN uses one screen. The alternative — a
/// recording sheet that dismisses into a review sheet — makes the review look
/// like a new task rather than the same note, and gives the user two chances
/// to lose it.
///
/// ## Sheet height
///
/// Recording sits at `.medium`: a focused moment with one control, and a
/// half-height sheet leaves the contact list visible behind it. The review is
/// a form, so reaching `.draft` raises the sheet to `.large`. The change is
/// driven by a selection binding, which animates rather than snapping.
public struct VoiceCaptureComposerView: View {
    @State private var model: VoiceCaptureViewModel
    @State private var detent: PresentationDetent = .medium

    public init(
        environment: VoiceCaptureEnvironment,
        initialContactID: String?,
        toasts: ReloraToastCenter,
        onSaved: @escaping (String) -> Void,
        onPaywall: @escaping (AppRouter.PaywallReason) -> Void,
        onSignIn: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        _model = State(
            initialValue: VoiceCaptureViewModel(
                environment: environment,
                initialContactID: initialContactID,
                toasts: toasts,
                onSaved: onSaved,
                onPaywall: onPaywall,
                onSignIn: onSignIn,
                onClose: onClose
            )
        )
    }

    public var body: some View {
        @Bindable var model = model

        NavigationStack {
            Group {
                if model.stage == .disclosure {
                    VoiceDisclosurePanel(
                        onContinue: { Task { await model.acknowledgeDisclosure() } },
                        onNotNow: { model.declineDisclosure() }
                    )
                } else if model.stage == .draft {
                    reviewShell
                } else {
                    captureShell
                }
            }
            .background(ReloraColor.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    header
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        model.requestClose()
                    } label: {
                        // No explicit size: the toolbar's own symbol metrics
                        // are what make this read as a system close button
                        // rather than a drawn one, and they scale already.
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(model.hasCaptureData)
        .task {
            await model.start()
        }
        .onDisappear {
            model.stop()
        }
        .onChange(of: model.stage) { _, stage in
            // The review is a form. Raising the sheet for it is the difference
            // between editing a note and peering at one through a slot.
            if stage == .draft {
                withReloraAnimation(.gentle) { detent = .large }
            }
        }
        .sheet(isPresented: $model.isPickerPresented) {
            VoiceContactPickerSheet(model: model)
        }
        .confirmationDialog(
            VoiceCaptureCopy.discardTitle,
            isPresented: $model.isDiscardConfirmPresented,
            titleVisibility: .visible
        ) {
            Button(VoiceCaptureCopy.discardConfirm, role: .destructive) { model.discard() }
            Button(VoiceCaptureCopy.discardKeep, role: .cancel) {}
        } message: {
            Text(VoiceCaptureCopy.discardMessage)
        }
        .alert(
            VoiceCaptureCopy.durationLimitTitle,
            isPresented: $model.isDurationLimitAlertPresented
        ) {
            if VoiceQuotaGate.offersUpgrade(for: model.planID) {
                Button(VoiceCaptureCopy.durationLimitSeePlans) { model.showDurationPaywall() }
            }
            Button(VoiceCaptureCopy.durationLimitContinue, role: .cancel) {}
        } message: {
            Text(VoiceQuotaGate.durationLimitMessage(for: model.planID))
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 2) {
            Text(VoiceCaptureCopy.stateLabel(stage: model.stage, recording: model.meter.state))
                .font(ReloraFont.footnote)
                .foregroundStyle(ReloraColor.mutedInk)

            if let status = statusLine {
                Text(status)
                    .font(ReloraFont.footnote)
                    .foregroundStyle(ReloraColor.accentText)
            }
        }
        // Read as one phrase. Two stacked labels make VoiceOver announce a
        // state and then a status as if they were separate controls.
        .accessibilityElement(children: .combine)
    }

    private var statusLine: String? {
        if model.stage == .draft, model.usedLocalGuestFallback {
            return VoiceCaptureCopy.localDraftStatus
        }
        return model.processingStatus
    }

    // MARK: Recording, processing, error

    private var captureShell: some View {
        VStack(spacing: ReloraSpacing.lg) {
            Spacer(minLength: 0)

            if model.stage != .error {
                meterCard
            }

            if model.stage == .recording && model.isLiveTranscribing {
                LiveTranscriptPreview(transcript: model.liveTranscript)
            }

            VStack(spacing: ReloraSpacing.sm) {
                Text(VoiceCaptureCopy.title(stage: model.stage))
                    .font(ReloraFont.title3)
                    .foregroundStyle(ReloraColor.ink)
                    .multilineTextAlignment(.center)

                if model.stage == .recording {
                    Text(VoiceCaptureCopy.recordingSubtitle(isLiveTranscribing: model.isLiveTranscribing))
                        .font(ReloraFont.body)
                        .foregroundStyle(ReloraColor.mutedInk)
                        .multilineTextAlignment(.center)
                }

                if model.stage == .processing {
                    Text(VoiceCaptureCopy.processingBody)
                        .font(ReloraFont.body)
                        .foregroundStyle(ReloraColor.mutedInk)
                        .multilineTextAlignment(.center)
                }
            }

            if model.stage == .recording {
                stopButton
            }

            if model.stage == .error {
                errorCard
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, ReloraLayout.screenHPadding)
        .padding(.vertical, ReloraSpacing.lg)
        .frame(maxWidth: ReloraLayout.contentMaxWidth)
        .frame(maxWidth: .infinity)
    }

    private var meterCard: some View {
        ReloraCard {
            VStack(spacing: ReloraSpacing.md) {
                VoiceLevelMeter(
                    levels: model.meter.history,
                    isActive: model.stage == .recording && model.meter.state != .finishing
                )

                Text(VoiceElapsedFormat.label(elapsed: model.elapsed, cap: model.durationCap))
                    .font(ReloraFont.footnote)
                    .monospacedDigit()
                    .foregroundStyle(ReloraColor.mutedInk)
                    .accessibilityLabel(
                        VoiceElapsedFormat.accessibilityLabel(
                            elapsed: model.elapsed,
                            cap: model.durationCap
                        )
                    )
            }
        }
    }

    /// The same circle as `ReloraRecordButton`, with a square where the
    /// microphone was. Sized off the same token so the control the user
    /// pressed to get here does not change size underneath them — which is
    /// also why this is not `ReloraRecordButton` itself: same shape, opposite
    /// meaning, and a mic glyph on a stop button would be a lie.
    private var stopButton: some View {
        Button {
            Task { await model.stopCapture() }
        } label: {
            RoundedRectangle(cornerRadius: ReloraRadius.sm, style: .continuous)
                .fill(ReloraColor.onAccent)
                .frame(width: 24, height: 24)
                .frame(
                    width: ReloraFloatingLayout.recordButtonSize,
                    height: ReloraFloatingLayout.recordButtonSize
                )
                .background(Circle().fill(ReloraColor.accent).reloraShadow(.accentGlow))
        }
        .buttonStyle(.plain)
        .disabled(model.meter.state == .finishing)
        .accessibilityLabel("Stop recording")
        .accessibilityHint("Ends the recording and turns it into a note")
    }

    private var errorCard: some View {
        ReloraCard {
            VStack(alignment: .leading, spacing: ReloraSpacing.md) {
                Text(model.errorMessage ?? VoiceErrorCopy.message(for: BackendError.transcribeFailed))
                    .font(ReloraFont.body)
                    .foregroundStyle(ReloraColor.ink)

                Text(
                    VoiceCaptureCopy.errorBody(
                        isAuthFailure: model.isAuthFailure,
                        hasRetryableAudio: model.hasRetryableAudio
                    )
                )
                .font(ReloraFont.footnote)
                .foregroundStyle(ReloraColor.mutedInk)

                errorActions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var errorActions: some View {
        VStack(spacing: ReloraSpacing.sm) {
            if model.isAuthFailure {
                Button("Sign in") { model.signInFromError() }
                    .buttonStyle(.reloraPrimary)
                Button("Retry") { Task { await model.retry() } }
                    .buttonStyle(.reloraSecondary)
                    .accessibilityLabel("Retry transcription")
            } else {
                Button("Retry") { Task { await model.retry() } }
                    .buttonStyle(.reloraPrimary)
                    .accessibilityLabel("Retry transcription")

                // Offered only when there is a recording to distinguish it
                // from. With nothing captured, Retry already starts a fresh
                // recording, and two buttons doing one thing is a choice
                // nobody can make correctly.
                if model.hasRetryableAudio {
                    Button("New recording") { Task { await model.beginCapture() } }
                        .buttonStyle(.reloraSecondary)
                        .accessibilityLabel("Start a new recording")
                }
            }
        }
    }

    // MARK: Review

    private var reviewShell: some View {
        ScrollView {
            VoiceCaptureReviewSection(model: model)
                .padding(.horizontal, ReloraLayout.screenHPadding)
                .padding(.vertical, ReloraSpacing.lg)
                .frame(maxWidth: ReloraLayout.contentMaxWidth)
                .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        // Save stays one thumb-reach away however long the review gets. A
        // primary action that scrolls off the bottom is a primary action the
        // user has to go looking for.
        .safeAreaInset(edge: .bottom) {
            saveBar
        }
    }

    private var saveBar: some View {
        Button {
            Task { await model.save() }
        } label: {
            Text(model.isSaving ? VoiceCaptureCopy.savingAction : VoiceCaptureCopy.saveAction)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.reloraPrimary)
        .disabled(!model.canSave)
        // The label stays "Save note" while the text says "Saving...", so the
        // control does not appear to rename itself mid-action.
        .accessibilityLabel(VoiceCaptureCopy.saveAction)
        .padding(.horizontal, ReloraLayout.screenHPadding)
        .padding(.vertical, ReloraSpacing.md)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}
