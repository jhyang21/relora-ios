import Foundation
import Observation
import ReloraCore
import ReloraData
import ReloraDesign
import ReloraServices

/// Everything the composer needs that is not state: the recorder, the
/// pipeline, the database, and the two questions only the app can answer.
///
/// Bundled into one value because the composer is presented from a sheet case
/// in `RootView`, and threading seven arguments through a `switch` is how a
/// sheet ends up constructing its own dependencies.
public struct VoiceCaptureEnvironment {
    public var database: AppDatabase
    public var identity: IdentityController
    public var recorder: RecordingController
    public var pipeline: any VoiceTranscriptionPipeline
    public var access: any VoiceAccessProviding
    public var isOnline: @MainActor () -> Bool

    public init(
        database: AppDatabase,
        identity: IdentityController,
        recorder: RecordingController,
        pipeline: any VoiceTranscriptionPipeline,
        access: any VoiceAccessProviding,
        isOnline: @escaping @MainActor () -> Bool
    ) {
        self.database = database
        self.identity = identity
        self.recorder = recorder
        self.pipeline = pipeline
        self.access = access
        self.isOnline = isOnline
    }
}

/// The voice composer's state and the order things happen in.
///
/// Ports `VoiceCaptureComposerScreen.tsx` and the parts of `useVoiceRecorder.ts`
/// that are not the recorder itself. The screen above this file draws; every
/// decision — when to gate, when to stop, what a failure means, what a save
/// writes — is here, and the pure pieces it leans on (`VoiceMeter`,
/// `VoiceReview`, `VoiceQuotaGate`, `VoiceSaveTransaction`) are testable
/// without it.
///
/// ## Identity
///
/// The composer can open while identity is `.unresolved`. Nothing here reads
/// `ownerUserID` unguarded — the quota gate takes an optional, and
/// `prepareForWrite()` mints the local guest session at the one moment a row
/// needs an owner, which is the save. Same rule, same reason, as
/// `HomeViewModel`.
@MainActor
@Observable
public final class VoiceCaptureViewModel {

    // MARK: Stage

    /// Assigned in `init`, not on appear. Reading the disclosure flag from
    /// the database before the first frame is what keeps someone who has
    /// already seen the panel from watching the meter flash behind it.
    public private(set) var stage: VoiceCaptureStage
    public private(set) var meter = VoiceMeter()
    public private(set) var elapsed: Duration = .zero
    public private(set) var durationCap = Duration.milliseconds(QuotaPolicy.freeNoteDurationLimitMs)
    public private(set) var planID: QuotaPolicy.PlanID = .free
    /// The escalating "still working" line, or nil while nothing is slow.
    public private(set) var processingStatus: String?

    // MARK: Failure

    public private(set) var errorMessage: String?
    public private(set) var errorCode: String?
    public var isAuthFailure: Bool {
        errorCode.map(VoiceErrorCopy.isAuthFailure) ?? false
    }
    /// Whether there is a file a Retry could re-send. With nothing captured,
    /// Retry and "start a new recording" would be the same button twice.
    public var hasRetryableAudio: Bool { audio != nil }
    /// The recorded file, once there is one. Scope D's replay control reads
    /// this on the review screen; nil until a capture actually finishes.
    public var audioFileURL: URL? { audio?.fileURL }

    // MARK: Live transcript (M7)

    /// The transcript as it builds during a realtime capture. Empty for a
    /// batch capture — the composer gates the live-transcript panel on
    /// `isLiveTranscribing`, not on this being non-empty, since "connected
    /// but nothing said yet" and "not connected at all" both start empty.
    public private(set) var liveTranscript = ""
    /// Whether this capture resolved to realtime *and* connected. Set once,
    /// before recording starts, and never flips back to false mid-capture —
    /// a dropped socket is a fallback `process()` resolves after `stop()`,
    /// not a reason to hide the panel while still recording.
    public private(set) var isLiveTranscribing = false

    // MARK: Review

    public private(set) var transcript = ""
    public private(set) var usedLocalGuestFallback = false
    public var reviewItems: [VoiceReviewItem] = []
    public private(set) var reminderSuggestion: ExtractionReminderSuggestion?
    public var acceptReminder = false
    /// The reminder's date, editable. A deviation from RN, which offers the
    /// suggested time or nothing — see the M6 report.
    public var reminderDate = Date()
    /// The transcript disclosure. Closed on arrival: the draft is the thing to
    /// check, and the raw transcript is there for the person who disagrees
    /// with it.
    public var isTranscriptExpanded = false

    // MARK: Contact resolution

    public private(set) var matchResult = MatchResult(candidates: [], defaultSelection: .notSet, status: .idle)
    public private(set) var contacts: [Contact] = []
    public var selectedChip: VoiceContactChip.Kind?
    public var newContactName = ""
    public var pickerQuery = ""
    public var isPickerPresented = false

    // MARK: Modals

    public var isDiscardConfirmPresented = false
    public var isDurationLimitAlertPresented = false
    public private(set) var isSaving = false

    // MARK: Dependencies and private state

    @ObservationIgnored private let environment: VoiceCaptureEnvironment
    @ObservationIgnored private let initialContactID: String?
    @ObservationIgnored private let toasts: ReloraToastCenter
    @ObservationIgnored private let onSaved: (String) -> Void
    @ObservationIgnored private let onPaywall: (AppRouter.PaywallReason) -> Void
    @ObservationIgnored private let onSignIn: () -> Void
    @ObservationIgnored private let onClose: () -> Void
    @ObservationIgnored private let disclosure: VoiceDisclosureStorage

    @ObservationIgnored private var audio: RecordingArtifact?
    @ObservationIgnored private var ids = VoiceSaveIDs()
    @ObservationIgnored private var saveUserID: String?
    /// The newest RMS sample, cleared as each tick consumes it. Nil at a tick
    /// means the recorder reported nothing this interval — which is not the
    /// same as silence. See `VoiceMeter.tick`.
    @ObservationIgnored private var latestRMS: Float?
    @ObservationIgnored private var isStopping = false

    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    @ObservationIgnored private var liveTranscriptTask: Task<Void, Never>?

    public init(
        environment: VoiceCaptureEnvironment,
        initialContactID: String?,
        toasts: ReloraToastCenter,
        onSaved: @escaping (String) -> Void,
        onPaywall: @escaping (AppRouter.PaywallReason) -> Void,
        onSignIn: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        // Built from the parameter, before the first stored property is
        // assigned: a `@MainActor` type could not be constructed here, which
        // is why `VoiceDisclosureStorage` is a plain `Sendable` struct.
        let disclosure = VoiceDisclosureStorage(database: environment.database)
        let seen = disclosure.readSeen()

        self.environment = environment
        self.initialContactID = initialContactID
        self.toasts = toasts
        self.onSaved = onSaved
        self.onPaywall = onPaywall
        self.onSignIn = onSignIn
        self.onClose = onClose
        self.disclosure = disclosure
        self.stage = VoiceDisclosureGate.decide(hasSeenDisclosure: seen) == .disclose ? .disclosure : .recording
    }

    // MARK: - Lifecycle

    /// The sheet's entry point. Does nothing while the disclosure is up:
    /// it runs ahead of the quota gate and the microphone both, so neither
    /// may start until Continue is tapped.
    public func start() async {
        guard stage != .disclosure else { return }
        await gateAndBeginCapture()
    }

    /// Continue on the disclosure: records that it was seen, then does what
    /// `start()` would have done. The flag is written here and nowhere else
    /// — a swipe or the X is a dismissal, not consent, so someone who backs
    /// out sees the panel again on their next attempt.
    public func acknowledgeDisclosure() async {
        guard stage == .disclosure else { return }
        disclosure.writeSeen()
        await gateAndBeginCapture()
    }

    /// "Not now": the same exit as the X. Nothing has been captured at this
    /// stage, so `requestClose()` closes without a confirmation.
    public func declineDisclosure() {
        requestClose()
    }

    /// Gates, loads, and starts recording — in that order.
    ///
    /// The gate runs before the microphone does. RN checks
    /// `canCreateVoiceNote` in an effect that replaces the route the moment
    /// the screen mounts; here the composer hands its sheet slot to the
    /// paywall instead of opening, which is the same refusal without the
    /// screen appearing and vanishing.
    private func gateAndBeginCapture() async {
        let snapshot = await environment.access.accessSnapshot(userID: activeUserID)
        planID = snapshot.planID
        durationCap = snapshot.durationCap

        switch VoiceQuotaGate.decide(snapshot) {
        case .paywall(let reason):
            onPaywall(reason)
            return
        case .record(let cap):
            durationCap = cap
        }

        await loadContacts()

        // No offline gate, deliberately (manager ruling over the M6 draft,
        // which refused to record offline). A local guest's whole flow works
        // with no network — transcription throws AUTH_REQUIRED before any
        // request and the note is written by hand. For a signed-in user the
        // audio is kept on failure and Retry re-sends it, so recording
        // offline is "capture the thought now, send it later", which RN also
        // allows. `environment.isOnline` stays: M7 reads it to resolve
        // realtime-vs-batch before recording starts.
        await beginCapture()
    }

    /// Tears down every stream. Called when the sheet goes away.
    public func stop() {
        levelTask?.cancel()
        tickTask?.cancel()
        eventTask?.cancel()
        processingTask?.cancel()
        liveTranscriptTask?.cancel()
        levelTask = nil
        tickTask = nil
        eventTask = nil
        processingTask = nil
        liveTranscriptTask = nil
    }

    private var activeUserID: String? {
        if case .unresolved = environment.identity.identity { return nil }
        return environment.identity.identity.ownerUserID
    }

    /// True for every identity RN calls `'anonymous'`, plus the unresolved
    /// state the composer can open in. Only these may end a capture on an
    /// empty transcript instead of an `AUTH_REQUIRED` failure.
    private var allowsLocalGuestFallback: Bool {
        switch environment.identity.identity {
        case .account: return false
        case .unresolved, .localGuest, .anonymous: return true
        }
    }

    private func loadContacts() async {
        guard let userID = activeUserID else {
            contacts = []
            return
        }
        let database = environment.database
        contacts = await Task.detached(priority: .userInitiated) {
            (try? ContactRepository(database: database).list(userID: userID)) ?? []
        }.value
    }

    // MARK: - Recording

    public func beginCapture() async {
        stop()
        stage = .recording
        meter = VoiceMeter()
        elapsed = .zero
        latestRMS = nil
        isStopping = false
        errorMessage = nil
        errorCode = nil
        processingStatus = nil
        audio = nil
        liveTranscript = ""
        isLiveTranscribing = false

        let recorder = environment.recorder
        let levels = await recorder.levelStream()
        let ticks = await recorder.elapsedTimeStream(interval: VoiceMeter.pollInterval)
        let events = await recorder.events()

        levelTask = Task { [weak self] in
            for await level in levels {
                self?.latestRMS = level
            }
        }

        tickTask = Task { [weak self] in
            for await elapsed in ticks {
                self?.tick(elapsed: elapsed)
            }
        }

        eventTask = Task { [weak self] in
            for await event in events {
                switch event {
                case .autoStopped(let artifact):
                    self?.handleAutoStop(artifact, hitDurationCap: true)
                case .interrupted(let artifact):
                    // A call or an alarm took the microphone. The audio up to
                    // that point is real, so it is processed rather than
                    // thrown away — the alternative is losing a note to a
                    // phone call the user did not answer.
                    self?.handleAutoStop(artifact, hitDurationCap: false)
                }
            }
        }

        // A previous attempt's live session and PCM handler (a retry after
        // `recorder.start` threw) must not survive into this capture —
        // especially one that resolves to batch below and would otherwise
        // never touch either again.
        let livePipeline = environment.pipeline as? any LiveTranscribingVoicePipeline
        await recorder.setPCMFrameHandler(nil)
        await livePipeline?.cancelLiveSession()

        // Realtime resolves to batch *before* recording when it is not
        // available — offline, or a pipeline that isn't live-capable at
        // all — never batch *because* a live session failed after the mic
        // was already running. Ports `useVoiceRecorder.ts`'s `begin()`:
        // realtime is tried first and batch is the silent fallback, not a
        // second attempt the user sees. Must run before `recorder.start`,
        // per `LiveTranscribingVoicePipeline.beginLiveSession`'s contract.
        if environment.isOnline(), let live = livePipeline {
            switch await live.beginLiveSession(recorder: recorder) {
            case .started(let liveEvents):
                isLiveTranscribing = true
                liveTranscriptTask = Task { [weak self] in
                    for await event in liveEvents {
                        self?.applyLiveTranscriptEvent(event)
                    }
                }
            case .unavailable(let error):
                // A 402 minting the session is the server saying the quota
                // is spent, checked against a ledger this client cannot
                // see. Batch would hit the same wall sixty seconds later,
                // after the user had recorded a note for nothing — the same
                // reasoning `failFromPipeline` applies mid-processing. Every
                // other mint failure stays silent: recording goes ahead and
                // `process()` falls back to batch.
                if let error, error.httpStatus == 402 {
                    // `stop()` first: this method already started the meter
                    // and event streams, and the microphone never opens
                    // now. The stage is left as the gate in `start()`
                    // leaves it — the composer hands its sheet slot to the
                    // paywall rather than showing anything else.
                    stop()
                    onPaywall(VoiceQuotaGate.paywallReason(forServerCode: error.code))
                    return
                }
            }
        }

        do {
            try await recorder.start(maxDuration: durationCap)
        } catch {
            fail(
                message: VoiceErrorCopy.startFailureMessage(error),
                code: VoiceErrorCopy.startFailureCode(error)
            )
        }
    }

    /// Folds one realtime event into `liveTranscript`. Only the two events
    /// that carry an updated `accumulatedTranscript` change anything —
    /// `.error` is left alone deliberately: the panel keeps showing the
    /// last good transcript rather than clearing itself the moment a
    /// socket drops, since `process()` may still recover a usable
    /// transcript from what accumulated before the drop.
    private func applyLiveTranscriptEvent(_ event: RealtimeTranscriber.RealtimeEvent) {
        switch event {
        case .transcriptDelta(_, _, let accumulatedTranscript), .itemCompleted(_, _, let accumulatedTranscript):
            liveTranscript = accumulatedTranscript
        case .connected, .speechStarted, .speechStopped, .closed, .error:
            break
        }
    }

    private func tick(elapsed: Duration) {
        guard stage == .recording, !isStopping else { return }
        self.elapsed = elapsed

        let sample = latestRMS
        latestRMS = nil

        // Ten seconds of quiet after the first two and a half ends the
        // recording on its own. Ported from `useVoiceRecorder.ts`: someone who
        // has stopped talking has finished, and making them reach for Stop is
        // a chore the app can spare them.
        if case .stopForSilence = meter.tick(rms: sample, elapsed: elapsed) {
            Task { await stopCapture() }
        }
    }

    /// The user tapped Stop.
    public func stopCapture() async {
        guard stage == .recording, !isStopping else { return }
        isStopping = true
        meter.finish()

        let artifact = await environment.recorder.stop()
        await process(artifact)
    }

    private func handleAutoStop(_ artifact: RecordingArtifact, hitDurationCap: Bool) {
        guard stage == .recording, !isStopping else { return }
        isStopping = true
        meter.finish()

        if hitDurationCap {
            // RN raises a two-button dialog here — the one place in this flow
            // that earns an alert rather than a toast, because "See plans" is
            // a decision and not a notification. Processing carries on behind
            // it either way; the recording is finished, not cancelled.
            isDurationLimitAlertPresented = true
        }

        Task { await process(artifact) }
    }

    // MARK: - Processing

    private func process(_ artifact: RecordingArtifact) async {
        audio = artifact
        stage = .processing
        processingStatus = nil

        let pipeline = environment.pipeline
        let recording = VoiceCaptureRecording(artifact: artifact)
        let allowFallback = allowsLocalGuestFallback

        processingTask = Task { [weak self] in
            // Captured once, weakly, and read from inside the `@Sendable`
            // progress callback — which the pipeline may call from any
            // context, so it hops back to the main actor before touching
            // anything.
            let report: @Sendable (VoiceProcessingProgress) -> Void = { progress in
                Task { @MainActor in self?.apply(progress) }
            }

            do {
                let outcome = try await pipeline.process(
                    recording: recording,
                    allowLocalGuestFallback: allowFallback,
                    onProgress: report
                )
                guard !Task.isCancelled else { return }
                self?.presentReview(outcome)
            } catch is CancellationError {
                // The sheet is closing. The audio file stays on disk — RN
                // keeps it too — so nothing here has to undo anything.
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.failFromPipeline(error)
            }
        }

        await processingTask?.value
    }

    private func apply(_ progress: VoiceProcessingProgress) {
        guard stage == .processing else { return }
        if case .slow(let seconds) = progress {
            processingStatus = VoiceCaptureCopy.processingStatus(slowMarkSeconds: seconds)
        }
    }

    private func failFromPipeline(_ error: Error) {
        guard let backend = error as? BackendError else {
            fail(message: VoiceErrorCopy.message(for: BackendError.transcribeFailed), code: nil)
            return
        }
        // A 402 is the server saying the quota is gone. That is final — it was
        // checked against the ledger this client cannot see — so it goes
        // straight to the paywall rather than offering a Retry that will fail
        // the same way. The body's code says which wall: `transcribe_audio`
        // sends PLUS_QUOTA_REACHED for a Plus subscriber's monthly quota and
        // FREE_LIMIT_REACHED for everyone else.
        if backend.httpStatus == 402 {
            onPaywall(VoiceQuotaGate.paywallReason(forServerCode: backend.code))
            return
        }
        fail(message: VoiceErrorCopy.message(for: backend.code), code: backend.code)
    }

    private func fail(message: String, code: String?) {
        stage = .error
        errorMessage = message
        errorCode = code
        processingStatus = nil
    }

    /// Retry re-sends the same audio. A fresh idempotency key is minted by the
    /// pipeline on each call, so this is a new request rather than one the
    /// server dedupes back to the failure.
    public func retry() async {
        guard let artifact = audio else {
            await beginCapture()
            return
        }
        await process(artifact)
    }

    public func signInFromError() {
        onSignIn()
    }

    /// "See plans" from the recording-limit alert. A different reason from the
    /// quota walls: nothing is used up, the recording was simply longer than
    /// this plan allows.
    public func showDurationPaywall() {
        onPaywall(.durationLimit)
    }

    // MARK: - Review

    private func presentReview(_ outcome: VoiceCaptureOutcome) {
        transcript = outcome.transcript
        usedLocalGuestFallback = outcome.usedLocalGuestFallback
        reviewItems = VoiceReview.buildItems(extraction: outcome.extraction, transcript: outcome.transcript)
        reminderSuggestion = outcome.extraction?.reminderSuggestion
        acceptReminder = VoiceReview.initialReminderSelection(reminderSuggestion)
        if let remindAt = reminderSuggestion?.remindAt, let date = ReloraTimestamp.parse(remindAt) {
            reminderDate = date
        }

        matchResult = ContactMatching.matchVoiceCaptureContacts(
            contacts: contacts,
            transcript: outcome.transcript,
            subjectNameGuess: outcome.extraction?.subjectNameGuess?.text,
            initialContactID: initialContactID
        )
        newContactName = VoiceContactResolution.initialNewContactName(
            subjectNameGuess: outcome.extraction?.subjectNameGuess?.text,
            initialContactName: initialContactID.flatMap { contactName(for: $0) }
        )
        selectedChip = VoiceContactResolution.initialSelection(
            result: matchResult,
            initialContactID: initialContactID
        )

        stage = .draft
        processingStatus = nil
        // Nothing was confidently matched, so the choice is asked for rather
        // than left as an empty field the Save button silently refuses.
        isPickerPresented = selectedChip == nil
    }

    public func setItemText(_ text: String, for itemID: String) {
        reviewItems = VoiceReview.settingText(reviewItems, id: itemID, text: text)
    }

    public func toggleKeep(_ itemID: String) {
        reviewItems = VoiceReview.togglingKeep(reviewItems, id: itemID)
    }

    public var sections: VoiceReviewSections {
        VoiceReview.sections(reviewItems)
    }

    public func contactName(for contactID: String) -> String? {
        contacts.first { $0.id == contactID }?.name
    }

    public var selection: VoiceContactSelection? {
        VoiceContactResolution.resolve(
            selection: selectedChip,
            newContactName: newContactName,
            nameForContactID: { self.contactName(for: $0) }
        )
    }

    public var activeContactName: String? {
        selection?.displayName
    }

    // MARK: Picker

    public var pickerOptions: [VoiceContactChip] {
        VoiceContactPickerList.options(
            candidates: matchResult.candidates,
            contacts: contacts,
            query: pickerQuery
        )
    }

    public var canConfirmPicker: Bool {
        VoiceContactResolution.canConfirm(selection: selectedChip, newContactName: newContactName)
    }

    public func confirmPicker() {
        guard canConfirmPicker else {
            toasts.showError(
                VoiceCaptureCopy.pickerIncompleteTitle,
                message: VoiceCaptureCopy.pickerIncompleteMessage
            )
            return
        }
        closePicker()
    }

    /// Closed without choosing. The selection is left exactly as it was —
    /// including unset, which keeps Save disabled and the review's prompt on
    /// screen. RN's `onDismiss` behaves the same way.
    public func dismissPicker() {
        closePicker()
    }

    private func closePicker() {
        isPickerPresented = false
        // Cleared on the way out so reopening starts on the full list rather
        // than a search someone typed a minute ago and has forgotten.
        pickerQuery = ""
    }

    // MARK: - Saving

    public var canSave: Bool {
        guard stage == .draft, !isSaving, selection != nil else { return false }
        let hasItems = !VoiceReview.acceptedItems(reviewItems).isEmpty
        return hasItems || (acceptReminder && reminderSuggestion != nil)
    }

    public func save() async {
        guard canSave, let selection else {
            toasts.showError(
                VoiceCaptureCopy.contactRequiredTitle,
                message: VoiceCaptureCopy.contactRequiredMessage
            )
            return
        }

        isSaving = true
        defer { isSaving = false }

        // The one moment a row needs an owner. A composer opened on a fresh
        // install has had no identity until now.
        //
        // Written long rather than with `??`: the fallback is an `async` call,
        // and `??` takes a plain autoclosure that cannot await.
        let userID: String
        if let saveUserID {
            userID = saveUserID
        } else {
            userID = await environment.identity.ensureLocalGuestSession()
            saveUserID = userID
        }

        let input = VoiceSaveInput(
            userID: userID,
            selection: selection,
            items: reviewItems,
            transcript: transcript,
            persistTranscript: await persistTranscript(),
            reminderSuggestion: reminderSuggestion,
            acceptReminder: acceptReminder,
            reminderRemindAt: acceptReminder ? ReloraTimestamp.from(reminderDate) : nil,
            audioLocalURI: await storedRecordingName(),
            // Only a capture the server never saw is charged locally. A
            // signed-in user's note was counted by `transcribe_audio` before
            // the transcript came back, and charging it again here would
            // spend one note twice.
            recordsUsageEvent: usedLocalGuestFallback
        )

        do {
            // Built here, written there: `ids` is main-actor state and cannot
            // be passed `inout` across a suspension. See
            // `VoiceSaveTransaction.execute`.
            let plan = try VoiceSaveTransaction.plan(input, ids: &ids)
            let result = try await VoiceSaveTransaction.execute(plan, database: environment.database)
            toasts.show(VoiceCaptureCopy.savedToast, variant: .success)
            // Completion-driven, not a timer. RN waited 850ms after the toast
            // before navigating, which was a guess at how long a write takes;
            // this runs when the write has actually landed.
            onSaved(result.contactID)
        } catch {
            toasts.showError("Could not save that note", message: saveFailureMessage(error))
        }
    }

    private func saveFailureMessage(_ error: Error) -> String {
        if case VoiceSaveError.noReviewItems = error {
            return "Keep at least one line, or the reminder, before saving."
        }
        return "Something went wrong writing it down. Try saving again."
    }

    private func persistTranscript() async -> Bool {
        // A guest's note has no server transcript to keep — there is only what
        // they typed — so the setting has nothing to act on. RN reaches the
        // same conclusion through `!usedLocalGuestFallback`.
        guard !usedLocalGuestFallback else { return false }
        let database = environment.database
        return await Task.detached(priority: .userInitiated) {
            (try? AppSettingsStore(database: database).saveVoiceTranscripts()) ?? true
        }.value
    }

    /// Moves the recording out of the temporary directory and returns the file
    /// name to store, or nil if there is no recording or the move failed.
    ///
    /// Done here rather than in `VoiceSaveTransaction.plan`, which is pure and
    /// synchronous by contract and must not touch the filesystem; off the main
    /// actor for the same reason `persistTranscript()` is.
    ///
    /// A failed move saves the note *without* audio. Failing the whole save
    /// would lose the words over a file, and storing the temporary path would
    /// store a reference that is already doomed. Saving again after a failure
    /// is safe: the store is idempotent on the same temporary file.
    private func storedRecordingName() async -> String? {
        guard let fileURL = audio?.fileURL else { return nil }
        let store = RecordingStore.shared
        return await Task.detached(priority: .userInitiated) {
            try? store.store(temporaryURL: fileURL)
        }.value
    }

    // MARK: - Leaving

    /// Whether closing should ask first. Ports `getHasCaptureData`: a capture
    /// with nothing in it closes silently, because a confirmation over an
    /// empty screen teaches people to dismiss confirmations.
    public var hasCaptureData: Bool {
        if stage == .recording && !isStopping { return true }
        if audio != nil { return true }
        if !transcript.trimmed.isEmpty { return true }
        if !reviewItems.isEmpty { return true }
        if reminderSuggestion != nil { return true }
        if errorMessage != nil { return true }
        return false
    }

    public func requestClose() {
        guard hasCaptureData else {
            close()
            return
        }
        isDiscardConfirmPresented = true
    }

    /// Discards the capture and closes. The audio file goes with it — this is
    /// the one exit that means "I do not want this recording".
    public func discard() {
        let recorder = environment.recorder
        let livePipeline = environment.pipeline as? any LiveTranscribingVoicePipeline
        stop()
        Task {
            await recorder.cancel()
            // RN's `cancel()` closes the realtime client alongside the
            // recorder (`voiceTranscriptionService.ts`); without this the
            // socket and the recorder's PCM tap outlive the capture.
            await recorder.setPCMFrameHandler(nil)
            await livePipeline?.cancelLiveSession()
        }
        close()
    }

    private func close() {
        stop()
        onClose()
    }
}
