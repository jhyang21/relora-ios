import Foundation
import ReloraCore

// MARK: - The seam

/// Which transport produced (or will produce) a transcript.
///
/// The composer reads this to decide whether a live transcript panel has
/// anything to show. Ports `VoiceTranscriptionMode` in
/// apps/mobile/src/features/voice/voiceTranscriptionService.ts.
public enum VoiceTranscriptionMode: String, Sendable, Equatable {
    case batch
    case realtime
}

/// Which half of the shared clock is running. The distinction is not
/// cosmetic: it decides which timeout code a caller sees, exactly as
/// `timedOutStage` does in `voiceCaptureFlow.ts`.
public enum VoiceProcessingStage: String, Sendable, Equatable {
    case transcribe
    case extract
}

/// Progress reported while `process` runs.
///
/// `.slow` carries RN's `'15s'` / `'30s'` marks as plain seconds, so the
/// copy that escalates lives with the copy rather than in the transport.
public enum VoiceProcessingProgress: Sendable, Equatable {
    case stage(VoiceProcessingStage)
    case slow(seconds: Int)
}

/// A finished recording, ready to be turned into a transcript.
///
/// A struct of its own rather than `RecordingArtifact` so the pipeline is
/// not tied to the recorder that produced the file — M7's realtime path
/// hands over the same three fields alongside a transcript it already has.
public struct VoiceCaptureRecording: Sendable, Equatable {
    public var fileURL: URL
    public var mimeType: String
    public var durationMS: Int

    public init(fileURL: URL, mimeType: String, durationMS: Int) {
        self.fileURL = fileURL
        self.mimeType = mimeType
        self.durationMS = durationMS
    }

    public init(artifact: RecordingArtifact) {
        self.init(
            fileURL: artifact.fileURL,
            mimeType: artifact.mimeType,
            durationMS: artifact.durationMS
        )
    }
}

/// What the review screen needs from the pipeline, and nothing more.
///
/// `usedLocalGuestFallback` marks the one path that produces no transcript
/// at all: a guest whose transcription call came back `AUTH_REQUIRED`. The
/// review screen still opens — the user can write the memory themselves —
/// but nothing may be invented to fill the gap. `voiceCaptureFlow.ts` is
/// explicit about why: "filler describing the app's own state would land
/// there as a memory of the person."
public struct VoiceCaptureOutcome: Sendable, Equatable {
    public var transcript: String
    public var extraction: ExtractionPayload?
    public var usedLocalGuestFallback: Bool

    public init(transcript: String, extraction: ExtractionPayload?, usedLocalGuestFallback: Bool) {
        self.transcript = transcript
        self.extraction = extraction
        self.usedLocalGuestFallback = usedLocalGuestFallback
    }
}

/// Audio in, transcript and extraction out.
///
/// ## Why this exists as a protocol with one conformer
///
/// M6 ships batch only. M7 adds a realtime transcriber that produces the
/// transcript *during* recording and falls back to batch when the socket
/// fails, the transcript comes back empty, or extraction throws (the
/// fallback matrix in `VoiceCaptureComposerScreen.tsx`'s
/// `processRealtimeCapture`). Every one of those decisions is about how a
/// transcript is obtained — none of them changes what the review screen
/// shows or what the save transaction writes.
///
/// So the seam is drawn here: the composer awaits one `process` call and
/// receives one `VoiceCaptureOutcome`. `RealtimeVoiceTranscriptionPipeline`
/// (M7) conforms with the fallback matrix inside it, wrapping the batch
/// conformer for the fallback leg, and the review and save layers do not
/// change. `RealtimeTranscriber` already leaves exactly this hole — its doc
/// comment reserves "what to do when the transcript comes back empty or an
/// `.error` event fires" for "the orchestrator this type doesn't yet have".
///
/// The live-transcript half of realtime is deliberately *not* modelled
/// here. It arrives while recording, not while processing, and it reaches
/// the composer through `RecordingController.setPCMFrameHandler` and
/// `RealtimeTranscriber.events()` — two APIs that already exist. Folding a
/// second lifecycle into this protocol now would be guessing at M7's shape
/// rather than leaving room for it.
public protocol VoiceTranscriptionPipeline: Sendable {
    var mode: VoiceTranscriptionMode { get }

    /// - Parameters:
    ///   - recording: the finished audio file.
    ///   - allowLocalGuestFallback: true for an identity RN calls
    ///     `'anonymous'` (this port's `.localGuest` **and** `.anonymous`).
    ///     Only such an identity may end on an empty-transcript outcome
    ///     instead of an `AUTH_REQUIRED` error.
    ///   - onProgress: stage changes and slow marks. Called from whatever
    ///     context the work runs on, never guaranteed to be the main actor.
    func process(
        recording: VoiceCaptureRecording,
        allowLocalGuestFallback: Bool,
        onProgress: @escaping @Sendable (VoiceProcessingProgress) -> Void
    ) async throws -> VoiceCaptureOutcome
}

// MARK: - Live transcription (M7)

/// What `beginLiveSession` came back with.
///
/// The failure case carries an error rather than being a bare `nil`
/// because one mint failure is not like the others: a 402 is the server
/// saying the quota is spent, which batch cannot recover from either, so
/// recording on and finding out sixty seconds later is worse than saying
/// so now. Everything else stays silent and lets batch have its turn.
public enum LiveSessionStart: Sendable {
    case started(AsyncStream<RealtimeTranscriber.RealtimeEvent>)
    case unavailable(BackendError?)
}

/// The seam `VoiceTranscriptionPipeline`'s doc comment reserved: a pipeline
/// that can also stream a transcript *while recording is still happening*.
///
/// Deliberately a second, smaller protocol rather than folding this into
/// `VoiceTranscriptionPipeline` itself — `BatchVoiceTranscriptionPipeline`
/// has nothing to offer here, and a method every conformer must implement
/// (most of them with `nil`) is worse than a capability the composer checks
/// for. The composer discovers it with
/// `environment.pipeline as? any LiveTranscribingVoicePipeline`.
public protocol LiveTranscribingVoicePipeline: VoiceTranscriptionPipeline {
    /// Mints a realtime session and connects before recording starts,
    /// wiring the recorder's PCM tap straight into the socket. Returns
    /// `.unavailable` when minting or connecting fails — the caller then
    /// records normally and this pipeline's own `process()` falls back to
    /// batch once the recording finishes, so a doomed connection never
    /// blocks the recording itself. Ports `useVoiceRecorder.ts`'s
    /// `begin()`: realtime is tried first and batch is the silent
    /// fallback, not a second attempt the user sees.
    ///
    /// Call at most once per capture, before `recorder.start()`.
    func beginLiveSession(recorder: RecordingController) async -> LiveSessionStart

    /// Tears down a live session that `process()` will never consume — a
    /// discarded capture, or a retry starting over. Closes the socket
    /// without waiting for a transcript. Ports RN's `cancel()` in
    /// `voiceTranscriptionService.ts`, whose `Promise.allSettled` closes
    /// the realtime client whenever a capture is abandoned; without it the
    /// socket, its receive loop, and the recorder's PCM tap all outlive
    /// the capture they belonged to. Safe to call when no session is open.
    func cancelLiveSession() async
}

// MARK: - Batch

/// The batch pipeline: upload, transcribe, extract — under one clock.
///
/// ## The shared clock
///
/// `EdgeFunctionsClient` gives every call its own 60-second budget with
/// 15s/30s progress marks. Calling it twice would give a capture up to 120
/// seconds, and would announce "still polishing" twice. RN spends one
/// 60-second budget across both stages — extraction gets whatever
/// transcription left — and marks 15s and 30s once each, measured from the
/// start of the capture. That difference is the whole reason this type
/// exists rather than the composer calling the client directly; see
/// docs/milestone-notes.md, "Voice capture timeout".
///
/// Ports `processVoiceCapture` in
/// apps/mobile/src/features/voice/voiceCaptureFlow.ts. The structure is the
/// same one `EdgeFunctionsClient.withTimeout` uses — a task group racing
/// the work against a sleeping timeout task — hoisted up one level so the
/// budget spans both calls. The inner per-call budgets stay at their
/// default and act as a backstop that can only fire at or after the outer
/// one; the inner progress marks are left unsubscribed so the shared clock
/// is the only thing reporting.
public final class BatchVoiceTranscriptionPipeline: VoiceTranscriptionPipeline {
    /// 60 seconds, `CLIENT_TIMEOUT_MS` in voiceCaptureFlow.ts.
    public static let sharedBudget = Duration.seconds(60)
    /// 15s and 30s, the two `setTimeout(... onProgress)` marks in the same file.
    public static let slowMarks: [Int] = [15, 30]

    public let mode: VoiceTranscriptionMode = .batch

    private let client: EdgeFunctionsClient
    private let budget: Duration
    private let slowMarks: [Int]
    private let timeZoneIdentifier: @Sendable () -> String?
    private let idempotencyKey: @Sendable () -> String

    /// - Parameters:
    ///   - timeZoneIdentifier: the IANA zone `extract_from_transcript` uses
    ///     to resolve "next Tuesday" into an instant. Injected rather than
    ///     read inline so a test is not at the mercy of the machine's zone.
    ///   - idempotencyKey: a **fresh** key per attempt. RN calls
    ///     `generateId()` at each `processVoiceCapture` call site, so a
    ///     retry after a failure is a new request rather than one the
    ///     server dedupes back to the failure.
    public init(
        client: EdgeFunctionsClient,
        budget: Duration = BatchVoiceTranscriptionPipeline.sharedBudget,
        slowMarks: [Int] = BatchVoiceTranscriptionPipeline.slowMarks,
        timeZoneIdentifier: @escaping @Sendable () -> String? = { TimeZone.current.identifier },
        idempotencyKey: @escaping @Sendable () -> String = { ReloraID.new() }
    ) {
        self.client = client
        self.budget = budget
        self.slowMarks = slowMarks
        self.timeZoneIdentifier = timeZoneIdentifier
        self.idempotencyKey = idempotencyKey
    }

    public func process(
        recording: VoiceCaptureRecording,
        allowLocalGuestFallback: Bool,
        onProgress: @escaping @Sendable (VoiceProcessingProgress) -> Void
    ) async throws -> VoiceCaptureOutcome {
        let stage = VoiceProcessingStageBox()
        let client = self.client
        let timeZone = timeZoneIdentifier()
        let key = idempotencyKey()

        return try await withThrowingTaskGroup(of: VoiceCaptureOutcome?.self) { group in
            group.addTask {
                onProgress(.stage(.transcribe))

                let transcript: String
                do {
                    transcript = try await client.transcribeAudio(
                        fileURL: recording.fileURL,
                        mimeType: recording.mimeType,
                        durationMS: recording.durationMS,
                        idempotencyKey: key
                    ).transcript
                } catch let error as BackendError where
                    allowLocalGuestFallback && error.code == BackendError.authRequired {
                    // A guest with no usable session. The capture is not a
                    // failure — the review screen opens on an empty draft
                    // the user can fill in themselves.
                    return VoiceCaptureOutcome(
                        transcript: "",
                        extraction: nil,
                        usedLocalGuestFallback: true
                    )
                }

                stage.advanceToExtract()
                onProgress(.stage(.extract))

                let extraction = try await client.extractFromTranscript(
                    transcript: transcript,
                    timeZone: timeZone
                )

                return VoiceCaptureOutcome(
                    transcript: transcript,
                    extraction: extraction,
                    usedLocalGuestFallback: false
                )
            }

            group.addTask { [budget] in
                try await Task.sleep(for: budget)
                throw stage.timeoutError()
            }

            for seconds in slowMarks {
                group.addTask {
                    try await Task.sleep(for: .seconds(seconds))
                    onProgress(.slow(seconds: seconds))
                    return nil
                }
            }

            // Cancels the timeout and any unfired marks the moment the work
            // lands — and, on the timeout path, cancels the in-flight
            // request so the URLSession task stops rather than finishing
            // into nothing.
            defer { group.cancelAll() }

            while let result = try await group.next() {
                if let result { return result }
            }

            throw BackendError(
                code: BackendError.transcribeFailed,
                message: "Voice processing ended without a result.",
                httpStatus: 500
            )
        }
    }
}

/// Which stage the shared clock is in, readable from the timeout task.
///
/// `voiceCaptureFlow.ts` keeps this in a plain `let timedOutStage` that its
/// closures close over. Swift 6 will not let two concurrent tasks share a
/// `var`, so it becomes a lock-guarded box — the same `@unchecked Sendable`
/// + `NSLock` shape `RecordingTapSink` uses for the same reason.
private final class VoiceProcessingStageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stage: VoiceProcessingStage = .transcribe

    func advanceToExtract() {
        lock.withLock { stage = .extract }
    }

    /// 504, matching the semantic status mapping the edge functions use for
    /// their own timeouts (`.claude/rules/engineering-conventions.md`).
    func timeoutError() -> BackendError {
        let current = lock.withLock { stage }
        switch current {
        case .transcribe:
            return BackendError(
                code: BackendError.transcribeTimeout,
                message: "Transcription timed out.",
                httpStatus: 504
            )
        case .extract:
            return BackendError(
                code: BackendError.extractTimeout,
                message: "Extraction timed out.",
                httpStatus: 504
            )
        }
    }
}
