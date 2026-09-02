import Foundation
import ReloraCore

/// Actor wrapping one OpenAI Realtime transcription WebSocket connection.
/// Ports `RealtimeTranscriptionClient`
/// (apps/mobile/src/features/voice/realtime/realtimeTranscriptionClient.ts)
/// together with the stop semantics from `voiceTranscriptionService.ts`'s
/// `stop()` (commit → wait for the committed item to finalize, with a
/// bounded timeout) — that orchestration is inseparable from "what does
/// finishing a realtime session mean", so it lives here rather than in a
/// future caller. What does NOT live here: deciding what to do when the
/// transcript comes back empty or an `.error` event fires. That is the
/// batch-fallback decision the task brief reserves for the orchestrator
/// this type doesn't yet have — "keep this layer dumb about fallback".
public actor RealtimeTranscriber {
    public enum RealtimeEvent: Sendable {
        case connected
        case transcriptDelta(itemID: String, delta: String, accumulatedTranscript: String)
        case itemCompleted(itemID: String, transcript: String, accumulatedTranscript: String)
        case speechStarted
        case speechStopped
        case error(BackendError)
        case closed
    }

    public enum TranscriberError: Error, Sendable, Equatable {
        case alreadyConnected
        case notConnected
        case connectionFailed(String)
    }

    private let configuration: URLSessionConfiguration
    private var urlSession: URLSession?
    private var openSignal: OpenSignal?
    private var task: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?

    private var accumulator = RealtimeProtocol.TranscriptAccumulator()
    private var latestCommittedItemID: String?

    private var eventContinuation: AsyncStream<RealtimeEvent>.Continuation?
    private var pendingFinalTranscript: CheckedContinuation<String?, Never>?
    private var pendingFinalTranscriptTimeoutTask: Task<Void, Never>?

    public init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
    }

    public func events() -> AsyncStream<RealtimeEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: RealtimeEvent.self)
        eventContinuation = continuation
        return stream
    }

    /// Opens the socket at `wss://api.openai.com/v1/realtime` with
    /// subprotocols `["realtime", "openai-insecure-api-key.<secret>"]` —
    /// the exact URL and protocol list `RealtimeTranscriptionClient.connect`
    /// uses, no query string — and sends `session.update` once the
    /// handshake completes.
    ///
    /// Waiting for the handshake (rather than firing `session.update`
    /// right after `resume()`) mirrors RN's `open`/`error` event pair.
    /// `URLSessionWebSocketTask` has no async "did open" API of its own,
    /// so `OpenSignal` bridges `URLSessionWebSocketDelegate`'s
    /// `didOpenWithProtocol`/`didCompleteWithError` callbacks into this
    /// `throws`. That also means this connection needs its own
    /// `URLSession` (a delegate can only be attached at session
    /// construction) rather than the injected `.shared` a simpler client
    /// could reuse.
    public func connect(session: RealtimeSessionInfo) async throws {
        guard task == nil else { throw TranscriberError.alreadyConnected }

        let signal = OpenSignal()
        let scopedSession = URLSession(configuration: configuration, delegate: signal, delegateQueue: nil)
        let url = URL(string: "wss://api.openai.com/v1/realtime")!
        let socketTask = scopedSession.webSocketTask(
            with: url,
            protocols: ["realtime", "openai-insecure-api-key.\(session.clientSecretValue)"]
        )

        urlSession = scopedSession
        openSignal = signal
        task = socketTask

        socketTask.resume()

        do {
            try await signal.waitForOpen()
        } catch {
            task = nil
            urlSession = nil
            openSignal = nil
            throw TranscriberError.connectionFailed(String(describing: error))
        }

        startReceiveLoop(on: socketTask)
        eventContinuation?.yield(.connected)

        do {
            try await send(RealtimeProtocol.encodeSessionUpdate(), on: socketTask)
        } catch {
            throw TranscriberError.connectionFailed(String(describing: error))
        }
    }

    /// Mirrors `appendAudio`: base64-encodes `pcm` into
    /// `input_audio_buffer.append`. RN throws
    /// `REALTIME_CONNECTION_NOT_READY` when the socket isn't open yet;
    /// `.notConnected` is this type's equivalent.
    public func append(pcm: Data) async throws {
        guard let task else { throw TranscriberError.notConnected }
        try await send(RealtimeProtocol.encodeAppend(pcm: pcm), on: task)
    }

    /// Mirrors `voiceTranscriptionService.ts`'s `stop()` /
    /// `waitForLatestTranscript`. Commits the input buffer, then:
    ///
    /// 1. if the just-committed item already has a transcript (a
    ///    `.completed` event can race ahead of the commit's own round
    ///    trip), return it immediately;
    /// 2. else if nothing was ever explicitly committed but some
    ///    transcript text already accumulated (the server VAD
    ///    auto-committed and completed a turn on its own before this
    ///    call), return that;
    /// 3. else wait up to 4 seconds — RN's `waitForLatestTranscript`
    ///    default — for the matching `.completed` event, falling back to
    ///    whatever accumulated in the meantime.
    ///
    /// Never throws: RN's `stop()` always resolves to *some* transcript
    /// (or empty string) rather than failing the whole capture, even when
    /// the wait times out or the server sends an `error` event first —
    /// this returns `nil` in exactly those cases instead of RN's `""`,
    /// since `nil` reads better as "nothing usable came back" to a Swift
    /// caller. Always closes the socket before returning.
    public func finish() async -> String? {
        let result = await resolveFinalTranscript()
        // `defer` would only schedule a detached `Task` here, which would
        // NOT close before this method returns to its caller — an
        // explicit `await` after computing the result is what actually
        // delivers "always closes the socket before returning".
        await close()
        return result
    }

    private func resolveFinalTranscript() async -> String? {
        guard let task else {
            return nonEmpty(accumulator.composedTranscript())
        }

        try? await send(RealtimeProtocol.encodeCommit(), on: task)

        if let itemID = latestCommittedItemID, accumulator.isCompleted(itemID) {
            return nonEmpty(accumulator.composedTranscript())
        }
        if latestCommittedItemID == nil, let transcript = nonEmpty(accumulator.composedTranscript()) {
            return transcript
        }

        return await withCheckedContinuation { continuation in
            pendingFinalTranscript = continuation
            pendingFinalTranscriptTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(4_000))
                guard let self, !Task.isCancelled else { return }
                await self.resolvePendingFinalTranscript()
            }
        }
    }

    /// Closes the socket without waiting for a final transcript — for a
    /// caller abandoning the session outright (the realtime equivalent of
    /// RN's `cancel()` path in `voiceTranscriptionService.ts`, which
    /// tears the client down without calling `commitAudio`/
    /// `waitForLatestTranscript` at all). `finish()` also calls this once
    /// it has a result, so it is safe to call twice.
    public func close() async {
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        openSignal = nil
        resolvePendingFinalTranscript()
        eventContinuation?.yield(.closed)
        eventContinuation?.finish()
    }

    // MARK: - Receive loop

    private func startReceiveLoop(on task: URLSessionWebSocketTask) {
        receiveLoopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    await self.handle(message)
                } catch {
                    await self.handleReceiveFailure(error)
                    return
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .data(let value):
            data = value
        case .string(let value):
            data = Data(value.utf8)
        @unknown default:
            return
        }

        switch RealtimeProtocol.decodeServerEvent(data) {
        case .transcriptDelta(let itemID, let delta):
            let composed = accumulator.appendDelta(itemID: itemID, delta: delta)
            eventContinuation?.yield(.transcriptDelta(itemID: itemID, delta: delta, accumulatedTranscript: composed))

        case .itemCompleted(let itemID, let transcript):
            let composed = accumulator.completeTurn(itemID: itemID, transcript: transcript)
            eventContinuation?.yield(.itemCompleted(itemID: itemID, transcript: transcript, accumulatedTranscript: composed))
            if latestCommittedItemID == itemID {
                resolvePendingFinalTranscript()
            }

        case .bufferCommitted(let itemID, let previousItemID):
            latestCommittedItemID = itemID
            accumulator.registerCommittedTurn(itemID: itemID, previousItemID: previousItemID)

        case .speechStarted:
            eventContinuation?.yield(.speechStarted)

        case .speechStopped:
            eventContinuation?.yield(.speechStopped)

        case .serverError(let message):
            // RN's local error strings (e.g. resolveRealtimeServerErrorMessage's
            // fallback) have no counterpart in BackendError's catalog —
            // those are all server-defined codes from Backend.swift, which
            // is out of scope for this task — so the message doubles as
            // the code here, same as RN reusing it as `new Error(message)`.
            eventContinuation?.yield(.error(BackendError(code: message, message: message, httpStatus: 0)))
            resolvePendingFinalTranscript()

        case .unknown, .parseFailed:
            return
        }
    }

    private func handleReceiveFailure(_ error: Error) {
        eventContinuation?.yield(.error(BackendError(
            code: BackendError.realtimeConnectionFailed,
            message: String(describing: error),
            httpStatus: 0
        )))
        resolvePendingFinalTranscript()
    }

    // MARK: - Pending final-transcript continuation

    private func resolvePendingFinalTranscript() {
        guard let continuation = pendingFinalTranscript else { return }
        pendingFinalTranscript = nil
        pendingFinalTranscriptTimeoutTask?.cancel()
        pendingFinalTranscriptTimeoutTask = nil
        continuation.resume(returning: nonEmpty(accumulator.composedTranscript()))
    }

    private func nonEmpty(_ transcript: String) -> String? {
        transcript.isEmpty ? nil : transcript
    }

    // MARK: - Sending

    /// OpenAI's Realtime API speaks JSON text frames, matching what a JS
    /// `WebSocket.send(JSON.stringify(...))` call produces — `.string`,
    /// not `.data`, is the wire-accurate frame type here.
    private func send(_ data: Data, on task: URLSessionWebSocketTask) async throws {
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }
}

/// Bridges `URLSessionWebSocketDelegate`'s handshake callbacks into a
/// single `async throws` wait, since `URLSessionWebSocketTask` has no
/// async equivalent of JS `WebSocket`'s `open`/`error` events. Lives
/// outside the actor because delegate callbacks arrive on `URLSession`'s
/// own delegate queue, not on the actor's executor; `NSLock` (the same
/// pattern `MockURLProtocol` uses in ReloraServicesTests) keeps the
/// one-shot continuation handoff race-free between whichever callback
/// fires first and any late/duplicate call.
private final class OpenSignal: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    func waitForOpen() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        resume(with: .success(()))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        resume(with: .failure(error ?? URLError(.unknown)))
    }

    private func resume(with result: Result<Void, Error>) {
        lock.withLock {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }
}
