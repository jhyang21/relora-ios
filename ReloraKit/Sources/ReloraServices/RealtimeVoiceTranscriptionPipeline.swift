import Foundation
import ReloraCore

/// The realtime pipeline: connect before recording, stream PCM as it is
/// captured, and turn whatever `RealtimeTranscriber` produced into a
/// `VoiceCaptureOutcome` once recording stops — falling back to a full
/// `batch.process()` re-run on the same file whenever the realtime leg
/// cannot be trusted.
///
/// Ports the realtime half of `useVoiceRecorder.ts`'s `begin()`/`stop()`
/// together with `VoiceCaptureComposerScreen.tsx`'s `processRealtimeCapture`
/// fallback funnel. `AppBootstrap` is the one line that switches the app
/// from M6's `BatchVoiceTranscriptionPipeline` to this — see
/// docs/milestone-notes.md, "M6 outcomes later milestones consume (M7...)".
///
/// ## The fallback matrix
///
/// `process()` falls back to a full re-run of `batch.process()` on the
/// original recording — the realtime transcript is discarded, not reused,
/// exactly as RN's fallback re-uploads the file rather than patching a
/// partial transcript — in three cases:
///
/// 1. `beginLiveSession` never connected (minting or the socket handshake
///    failed before recording started), or the socket dropped mid-capture
///    (an `.error` event arrived on the live stream);
/// 2. `RealtimeTranscriber.finish()` returned `nil` or an empty string —
///    the session connected but nothing usable came out of it;
/// 3. `extractFromTranscript` threw (any error except `CancellationError`,
///    which propagates so a user-cancelled capture does not silently start
///    a second network round trip).
///
/// ## `BackendError.realtimeTranscriptTimeout` is a label, not a timer
///
/// Ruled during M7 review, verified against RN: the only realtime timer
/// is `waitForLatestTranscript(timeoutMs = 4_000)` inside RN's stop path,
/// and `RealtimeTranscriber.finish()` already implements exactly that
/// bounded wait. RN uses this code string as the *reason label* it hands
/// `fallbackToBatch` when the wait produced nothing — analytics metadata,
/// not a thrown error — so nothing here throws it. The catalog constant
/// stays as a defensive entry (`VoiceErrorCopy` maps it).
///
/// ## Timeout semantics — deliberately not the batch shared clock
///
/// `BatchVoiceTranscriptionPipeline` races both stages against one shared
/// budget because RN's batch flow does. RN's realtime flow does not: the
/// transcript is already being built while recording happens, so all that
/// is left after `stop()` is `RealtimeTranscriber.finish()`'s own ~4-second
/// bound (already implemented there) and one `extractFromTranscript` call
/// under `EdgeFunctionsClient`'s own default per-call 60s budget — this
/// type adds no additional wrapping around either.
public final class RealtimeVoiceTranscriptionPipeline: LiveTranscribingVoicePipeline, @unchecked Sendable {
    public let mode: VoiceTranscriptionMode = .realtime

    private let client: EdgeFunctionsClient
    private let batch: any VoiceTranscriptionPipeline
    private let timeZoneIdentifier: @Sendable () -> String?
    private let state = LiveSessionState()

    /// - Parameters:
    ///   - batch: the fallback leg. `AppBootstrap` passes a
    ///     `BatchVoiceTranscriptionPipeline` sharing this pipeline's own
    ///     `client`; typed as the protocol so a test can substitute a
    ///     stub without a live `EdgeFunctionsClient`.
    ///   - timeZoneIdentifier: same contract as
    ///     `BatchVoiceTranscriptionPipeline`'s — injected so a test is not
    ///     at the mercy of the machine's zone.
    public init(
        client: EdgeFunctionsClient,
        batch: any VoiceTranscriptionPipeline,
        timeZoneIdentifier: @escaping @Sendable () -> String? = { TimeZone.current.identifier }
    ) {
        self.client = client
        self.batch = batch
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    // MARK: - Live session (pre-recording)

    public func beginLiveSession(recorder: RecordingController) async -> AsyncStream<RealtimeTranscriber.RealtimeEvent>? {
        // A leftover session from a capture that never reached `process()`
        // (a failed `recorder.start`, an abandoned attempt) must be closed,
        // not just dropped — dropping the reference leaks the socket and
        // its receive loop.
        await cancelLiveSession()

        let session: RealtimeSessionInfo
        do {
            session = try await client.createRealtimeTranscriptionSession()
        } catch {
            return nil
        }

        let transcriber = RealtimeTranscriber()
        // Must be requested before `connect()` — the transcriber starts
        // yielding `.connected` the moment the handshake completes, and a
        // stream requested after that would miss it.
        let sourceEvents = await transcriber.events()

        do {
            try await transcriber.connect(session: session)
        } catch {
            await transcriber.close()
            return nil
        }

        state.setTranscriber(transcriber)

        await recorder.setPCMFrameHandler { data in
            Task { try? await transcriber.append(pcm: data) }
        }

        // Relayed rather than handed back directly: this pipeline needs to
        // watch for a mid-capture `.error` event too (a dropped socket
        // after a clean connect), and `RealtimeTranscriber.events()` hands
        // out one continuation per call — calling it twice would steal the
        // stream out from under the composer, not add a second listener.
        let (relayed, continuation) = AsyncStream.makeStream(of: RealtimeTranscriber.RealtimeEvent.self)
        let state = self.state
        Task {
            for await event in sourceEvents {
                if case .error(let backendError) = event {
                    state.recordConnectFailure(backendError.code)
                }
                continuation.yield(event)
            }
            continuation.finish()
        }
        return relayed
    }

    public func cancelLiveSession() async {
        let (transcriber, _) = state.take()
        await transcriber?.close()
    }

    // MARK: - Outcome (post-recording)

    public func process(
        recording: VoiceCaptureRecording,
        allowLocalGuestFallback: Bool,
        onProgress: @escaping @Sendable (VoiceProcessingProgress) -> Void
    ) async throws -> VoiceCaptureOutcome {
        let (transcriber, connectFailureCode) = state.take()

        guard let transcriber, connectFailureCode == nil else {
            return try await runBatchFallback(recording, allowLocalGuestFallback, onProgress)
        }

        onProgress(.stage(.transcribe))
        guard let transcript = await transcriber.finish(), !transcript.isEmpty else {
            return try await runBatchFallback(recording, allowLocalGuestFallback, onProgress)
        }

        onProgress(.stage(.extract))
        do {
            let extraction = try await client.extractFromTranscript(
                transcript: transcript,
                timeZone: timeZoneIdentifier()
            )
            return VoiceCaptureOutcome(
                transcript: transcript,
                extraction: extraction,
                usedLocalGuestFallback: false
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try await runBatchFallback(recording, allowLocalGuestFallback, onProgress)
        }
    }

    /// Test-only seam: sets the post-`beginLiveSession` state directly, so
    /// `process()`'s fallback matrix is testable without a live WebSocket.
    /// `internal`, not `public` — reachable only via `@testable import`.
    func setLiveSessionStateForTesting(transcriber: RealtimeTranscriber?, connectFailureCode: String?) {
        state.reset()
        if let transcriber {
            state.setTranscriber(transcriber)
        }
        if let connectFailureCode {
            state.recordConnectFailure(connectFailureCode)
        }
    }

    private func runBatchFallback(
        _ recording: VoiceCaptureRecording,
        _ allowLocalGuestFallback: Bool,
        _ onProgress: @escaping @Sendable (VoiceProcessingProgress) -> Void
    ) async throws -> VoiceCaptureOutcome {
        try await batch.process(
            recording: recording,
            allowLocalGuestFallback: allowLocalGuestFallback,
            onProgress: onProgress
        )
    }
}

/// Bridges `beginLiveSession` (pre-recording) and `process()`
/// (post-recording) across the actor boundary, and across whatever thread
/// `RealtimeTranscriber`'s receive loop is relaying `.error` events from.
/// The same `@unchecked Sendable` + `NSLock` shape
/// `BatchVoiceTranscriptionPipeline`'s `VoiceProcessingStageBox` uses.
private final class LiveSessionState: @unchecked Sendable {
    private let lock = NSLock()
    private var transcriber: RealtimeTranscriber?
    private var connectFailureCode: String?

    /// Clears any state left over from a previous capture, so a retry
    /// after a discarded or fallback-completed session starts from a
    /// known-clean slate rather than replaying the last one's failure.
    func reset() {
        lock.withLock {
            transcriber = nil
            connectFailureCode = nil
        }
    }

    func setTranscriber(_ transcriber: RealtimeTranscriber) {
        lock.withLock { self.transcriber = transcriber }
    }

    func recordConnectFailure(_ code: String) {
        lock.withLock { connectFailureCode = code }
    }

    /// Consumes the session state — `process()` calls this once per
    /// capture, and a subsequent call (a Retry that starts a fresh
    /// recording) must not see this attempt's leftover transcriber.
    func take() -> (RealtimeTranscriber?, String?) {
        lock.withLock {
            let result = (transcriber, connectFailureCode)
            transcriber = nil
            connectFailureCode = nil
            return result
        }
    }
}
