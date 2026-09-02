import Foundation
import Testing
import ReloraCore
@testable import ReloraServices

/// A stub `VoiceTranscriptionPipeline` standing in for the batch fallback
/// leg, so these tests assert *that the fallback ran* without depending on
/// `BatchVoiceTranscriptionPipeline`'s own network stack.
private final class StubBatchPipeline: VoiceTranscriptionPipeline, @unchecked Sendable {
    let mode: VoiceTranscriptionMode = .batch
    private let lock = NSLock()
    private var _callCount = 0
    private let result: () throws -> VoiceCaptureOutcome

    var callCount: Int { lock.withLock { _callCount } }

    init(result: @escaping () throws -> VoiceCaptureOutcome) {
        self.result = result
    }

    func process(
        recording: VoiceCaptureRecording,
        allowLocalGuestFallback: Bool,
        onProgress: @escaping @Sendable (VoiceProcessingProgress) -> Void
    ) async throws -> VoiceCaptureOutcome {
        lock.withLock { _callCount += 1 }
        return try result()
    }
}

private struct StubTokenProvider: AccessTokenProvider {
    func accessToken() async throws -> String? { "test-token" }
}

/// A client whose HTTP calls always fail, standing in for a network
/// `EdgeFunctionsClient` without a live server — enough for the one HTTP
/// call `beginLiveSession` makes before any WebSocket is involved.
private func makeFailingClient() -> EdgeFunctionsClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FailingURLProtocol.self]
    return EdgeFunctionsClient(
        config: BackendConfig(supabaseURL: URL(string: "https://example.supabase.co")!, anonKey: "test-anon-key"),
        tokenProvider: StubTokenProvider(),
        session: URLSession(configuration: configuration),
        timeoutBudget: .seconds(5),
        progressMarks: []
    )
}

private final class FailingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func recording() -> VoiceCaptureRecording {
    VoiceCaptureRecording(fileURL: URL(fileURLWithPath: "/tmp/fake.m4a"), mimeType: "audio/m4a", durationMS: 1_000)
}

private func batchOutcome() -> VoiceCaptureOutcome {
    VoiceCaptureOutcome(transcript: "from batch", extraction: nil, usedLocalGuestFallback: false)
}

@Suite("RealtimeVoiceTranscriptionPipeline")
struct RealtimeVoiceTranscriptionPipelineTests {

    @Test("mode is realtime")
    func modeIsRealtime() {
        let pipeline = RealtimeVoiceTranscriptionPipeline(client: makeFailingClient(), batch: StubBatchPipeline { batchOutcome() })
        #expect(pipeline.mode == .realtime)
    }

    @Test("beginLiveSession returns nil when minting the session fails")
    func beginLiveSessionReturnsNilWhenMintFails() async {
        let pipeline = RealtimeVoiceTranscriptionPipeline(client: makeFailingClient(), batch: StubBatchPipeline { batchOutcome() })
        let recorder = RecordingController(sessionController: AudioSessionController())
        let events = await pipeline.beginLiveSession(recorder: recorder)
        #expect(events == nil)
    }

    @Test("process falls back to batch when no live session was ever established")
    func processFallsBackWhenNoTranscriber() async throws {
        let batch = StubBatchPipeline { batchOutcome() }
        let pipeline = RealtimeVoiceTranscriptionPipeline(client: makeFailingClient(), batch: batch)

        let outcome = try await pipeline.process(recording: recording(), allowLocalGuestFallback: false, onProgress: { _ in })

        #expect(outcome.transcript == "from batch")
        #expect(batch.callCount == 1)
    }

    @Test("process falls back to batch when a connect failure was recorded, even with a transcriber present")
    func processFallsBackOnRecordedConnectFailure() async throws {
        let batch = StubBatchPipeline { batchOutcome() }
        let pipeline = RealtimeVoiceTranscriptionPipeline(client: makeFailingClient(), batch: batch)
        pipeline.setLiveSessionStateForTesting(
            transcriber: RealtimeTranscriber(),
            connectFailureCode: BackendError.realtimeConnectionFailed
        )

        let outcome = try await pipeline.process(recording: recording(), allowLocalGuestFallback: false, onProgress: { _ in })

        #expect(outcome.transcript == "from batch")
        #expect(batch.callCount == 1)
    }

    /// A `RealtimeTranscriber` that was never `connect()`-ed always
    /// resolves `finish()` to `nil` (no task, empty accumulator) — enough
    /// to exercise the empty-transcript fallback without a live socket.
    ///
    /// That same limitation is why no sibling test covers the pipeline's
    /// extraction-throws branch: a transcript-bearing transcriber cannot
    /// be built without a live socket, so any test aimed at extraction
    /// lands on this empty-transcript branch instead. That branch is
    /// covered by code inspection, not by a unit test here.
    @Test("process falls back to batch when the realtime transcript comes back empty")
    func processFallsBackOnEmptyTranscript() async throws {
        let batch = StubBatchPipeline { batchOutcome() }
        let pipeline = RealtimeVoiceTranscriptionPipeline(client: makeFailingClient(), batch: batch)
        pipeline.setLiveSessionStateForTesting(transcriber: RealtimeTranscriber(), connectFailureCode: nil)

        let outcome = try await pipeline.process(recording: recording(), allowLocalGuestFallback: false, onProgress: { _ in })

        #expect(outcome.transcript == "from batch")
        #expect(batch.callCount == 1)
    }

    @Test("cancelLiveSession consumes the pending session, so a later process() cannot pick it up")
    func cancelLiveSessionConsumesState() async throws {
        let batch = StubBatchPipeline { batchOutcome() }
        let pipeline = RealtimeVoiceTranscriptionPipeline(client: makeFailingClient(), batch: batch)
        pipeline.setLiveSessionStateForTesting(transcriber: RealtimeTranscriber(), connectFailureCode: nil)

        // The discard path: the capture is abandoned, the session torn
        // down. Closing an unconnected transcriber is a no-op, which is
        // exactly the "safe to call when no session is open" contract.
        await pipeline.cancelLiveSession()

        let outcome = try await pipeline.process(recording: recording(), allowLocalGuestFallback: false, onProgress: { _ in })

        #expect(outcome.transcript == "from batch")
        #expect(batch.callCount == 1)
    }

    @Test("a second process() call after a fallback does not replay stale state")
    func stateIsConsumedAfterProcess() async throws {
        let batch = StubBatchPipeline { batchOutcome() }
        let pipeline = RealtimeVoiceTranscriptionPipeline(client: makeFailingClient(), batch: batch)
        pipeline.setLiveSessionStateForTesting(
            transcriber: RealtimeTranscriber(),
            connectFailureCode: BackendError.realtimeConnectionFailed
        )

        _ = try await pipeline.process(recording: recording(), allowLocalGuestFallback: false, onProgress: { _ in })
        _ = try await pipeline.process(recording: recording(), allowLocalGuestFallback: false, onProgress: { _ in })

        // Both calls fell back to batch — the second retry is a fresh
        // capture with no live session of its own, not a replay.
        #expect(batch.callCount == 2)
    }
}
