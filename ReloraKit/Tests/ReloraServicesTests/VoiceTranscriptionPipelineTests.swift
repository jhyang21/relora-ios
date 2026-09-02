import Foundation
import Testing
import ReloraCore
@testable import ReloraServices

// MARK: - Harness

/// A second `URLProtocol` stub, deliberately not `MockURLProtocol`.
///
/// Both hold their state in statics, and Swift Testing runs suites in
/// parallel, so sharing one class across two files would let an
/// `EdgeFunctionsTests` case reset a handler this suite is mid-request on.
/// Its own class plus a serialized suite is what keeps these deterministic.
///
/// The addition over `MockURLProtocol`: the handler decides *per request*
/// whether to answer or hang, which is the only way to time out the second
/// stage of a two-stage clock while the first one succeeds.
final class PipelineURLProtocol: URLProtocol, @unchecked Sendable {
    enum Outcome {
        case respond(status: Int, body: Data)
        /// Never calls back. The request stays pending until its task is
        /// cancelled, which is what the shared clock does when it fires.
        case hang
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: (@Sendable (URLRequest) -> Outcome)?
    nonisolated(unsafe) private static var _paths: [String] = []

    static var handler: (@Sendable (URLRequest) -> Outcome)? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    /// The function names requested, in order. `["transcribe_audio"]` alone
    /// proves extraction never ran.
    static var requestedPaths: [String] {
        lock.withLock { _paths }
    }

    static func reset() {
        lock.withLock {
            _handler = nil
            _paths = []
        }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PipelineURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let name = request.url?.lastPathComponent ?? ""
        Self.lock.withLock { Self._paths.append(name) }

        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        switch handler(request) {
        case .hang:
            return
        case .respond(let status, let body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: [:]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private struct StubTokenProvider: AccessTokenProvider {
    var token: String? = "test-access-token"
    func accessToken() async throws -> String? { token }
}

private let transcribeBody = Data(#"{"transcript":"Coffee with Ada.","request_id":"req-1","deduped":false}"#.utf8)
private let extractBody = Data(#"""
{"subject_name_guess":{"text":"Ada","confidence":0.9},"memory_draft":{"text":"Coffee with Ada.","confidence":0.8},"key_things":[],"reminder_suggestion":null}
"""#.utf8)
/// The flat `{ error, code }` envelope every edge function returns on
/// failure (`_shared/response.ts`), here the 401 `authenticateRequest`
/// raises when there is no usable session.
private let authRequiredBody = Data(#"{"error":"Sign in required","code":"AUTH_REQUIRED"}"#.utf8)

/// A real file on disk. `transcribeAudio` reads and size-checks the audio
/// before it builds a request, so a URL that points at nothing fails the
/// pre-flight and never reaches the clock under test.
private func makeAudioFile() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("relora-pipeline-\(UUID().uuidString).m4a")
    try Data(repeating: 0x41, count: 512).write(to: url)
    return url
}

private func makePipeline(
    budget: Duration,
    slowMarks: [Int] = [],
    token: String? = "test-access-token"
) -> BatchVoiceTranscriptionPipeline {
    BatchVoiceTranscriptionPipeline(
        client: EdgeFunctionsClient(
            config: BackendConfig(
                supabaseURL: URL(string: "https://example.supabase.co")!,
                anonKey: "test-anon-key"
            ),
            tokenProvider: StubTokenProvider(token: token),
            session: PipelineURLProtocol.makeSession(),
            // Well above the shared budget in every test below, so a failure
            // here is always the shared clock firing and never the per-call
            // backstop underneath it.
            timeoutBudget: .seconds(120),
            progressMarks: []
        ),
        budget: budget,
        slowMarks: slowMarks,
        timeZoneIdentifier: { "America/Los_Angeles" },
        idempotencyKey: { "key-1" }
    )
}

/// Collects `onProgress` callbacks, which arrive from whichever task fired
/// them.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [VoiceProcessingProgress] = []

    var all: [VoiceProcessingProgress] { lock.withLock { entries } }

    var report: @Sendable (VoiceProcessingProgress) -> Void {
        { [self] progress in lock.withLock { entries.append(progress) } }
    }
}

private func recording(_ url: URL) -> VoiceCaptureRecording {
    VoiceCaptureRecording(fileURL: url, mimeType: "audio/m4a", durationMS: 4_000)
}

// MARK: - Tests

@Suite(.serialized)
struct BatchVoiceTranscriptionPipelineTests {

    @Test func bothStagesRunUnderOneClockAndReportInOrder() async throws {
        PipelineURLProtocol.reset()
        PipelineURLProtocol.handler = { request in
            request.url?.lastPathComponent == "transcribe_audio"
                ? .respond(status: 200, body: transcribeBody)
                : .respond(status: 200, body: extractBody)
        }

        let audio = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let log = ProgressLog()
        let outcome = try await makePipeline(budget: .seconds(30)).process(
            recording: recording(audio),
            allowLocalGuestFallback: false,
            onProgress: log.report
        )

        #expect(outcome.transcript == "Coffee with Ada.")
        #expect(outcome.usedLocalGuestFallback == false)
        #expect(outcome.extraction?.memoryDraft?.text == "Coffee with Ada.")
        #expect(log.all == [.stage(.transcribe), .stage(.extract)])
        #expect(PipelineURLProtocol.requestedPaths == ["transcribe_audio", "extract_from_transcript"])
    }

    /// The budget is spent, not restarted per call: transcription that never
    /// answers ends the whole capture, and it does so with the code for the
    /// stage that was in flight.
    @Test func timeoutDuringTranscriptionReportsTranscribeTimeout() async throws {
        PipelineURLProtocol.reset()
        PipelineURLProtocol.handler = { _ in .hang }

        let audio = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        do {
            _ = try await makePipeline(budget: .milliseconds(250)).process(
                recording: recording(audio),
                allowLocalGuestFallback: false,
                onProgress: { _ in }
            )
            Issue.record("Expected the shared clock to fire")
        } catch let error as BackendError {
            #expect(error.code == BackendError.transcribeTimeout)
            #expect(error.httpStatus == 504)
        }
    }

    /// The half that proves the clock is shared rather than per-call:
    /// transcription succeeds, extraction hangs, and what is left of the
    /// budget — not a fresh one — runs out.
    @Test func timeoutDuringExtractionReportsExtractTimeout() async throws {
        PipelineURLProtocol.reset()
        PipelineURLProtocol.handler = { request in
            request.url?.lastPathComponent == "transcribe_audio"
                ? .respond(status: 200, body: transcribeBody)
                : .hang
        }

        let audio = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        do {
            _ = try await makePipeline(budget: .milliseconds(400)).process(
                recording: recording(audio),
                allowLocalGuestFallback: false,
                onProgress: { _ in }
            )
            Issue.record("Expected the shared clock to fire during extraction")
        } catch let error as BackendError {
            #expect(error.code == BackendError.extractTimeout)
            #expect(error.httpStatus == 504)
        }

        #expect(PipelineURLProtocol.requestedPaths == ["transcribe_audio", "extract_from_transcript"])
    }

    /// A mark fires once, carrying its own second count — that count is what
    /// the copy escalates on, and a mark that repeated would make the message
    /// flicker between the two lines.
    ///
    /// Zero seconds rather than the real fifteen: the mark is a `Task.sleep`
    /// off the same clock, and a test that proves it fires need not wait a
    /// quarter of a minute to do it.
    @Test func aSlowMarkFiresOnceCarryingItsSecondCount() async throws {
        PipelineURLProtocol.reset()
        PipelineURLProtocol.handler = { _ in .hang }

        let audio = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let log = ProgressLog()
        _ = try? await makePipeline(budget: .milliseconds(400), slowMarks: [0]).process(
            recording: recording(audio),
            allowLocalGuestFallback: false,
            onProgress: log.report
        )

        let slow = log.all.filter { if case .slow = $0 { return true } else { return false } }
        #expect(slow == [.slow(seconds: 0)])
    }

    /// A guest has no session, so transcription always refuses. That is not a
    /// failure — the review screen opens on an empty draft they write
    /// themselves — and nothing is invented to fill the transcript.
    @Test func guestFallbackReturnsAnEmptyTranscriptAndSkipsExtraction() async throws {
        PipelineURLProtocol.reset()
        PipelineURLProtocol.handler = { _ in .respond(status: 401, body: authRequiredBody) }

        let audio = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let outcome = try await makePipeline(budget: .seconds(30)).process(
            recording: recording(audio),
            allowLocalGuestFallback: true,
            onProgress: { _ in }
        )

        #expect(outcome.transcript.isEmpty)
        #expect(outcome.extraction == nil)
        #expect(outcome.usedLocalGuestFallback)
        #expect(PipelineURLProtocol.requestedPaths == ["transcribe_audio"])
    }

    /// The same 401 for someone with an account is a real failure: their
    /// session expired, and the error card offers a way back in rather than a
    /// blank note.
    @Test func signedInAuthFailureThrowsInsteadOfFallingBack() async throws {
        PipelineURLProtocol.reset()
        PipelineURLProtocol.handler = { _ in .respond(status: 401, body: authRequiredBody) }

        let audio = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        do {
            _ = try await makePipeline(budget: .seconds(30)).process(
                recording: recording(audio),
                allowLocalGuestFallback: false,
                onProgress: { _ in }
            )
            Issue.record("Expected AUTH_REQUIRED to reach the caller")
        } catch let error as BackendError {
            #expect(error.code == BackendError.authRequired)
        }
    }
}
