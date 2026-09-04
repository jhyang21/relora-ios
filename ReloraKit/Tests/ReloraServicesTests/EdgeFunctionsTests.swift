import Foundation
import Testing
import ReloraCore
@testable import ReloraServices

/// Intercepts every request made through a `URLSession` configured with
/// this protocol registered. Behaves like `MockURLProtocol` in
/// `ReloraSyncTests` (each test target needs its own copy — they're
/// separate modules) with one addition: `hangRequests`, which leaves a
/// request permanently unanswered so tests can exercise
/// `EdgeFunctionsClient`'s own timeout budget rather than a server
/// response.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        var statusCode: Int
        var body: Data
        var headers: [String: String] = [:]
    }

    struct CapturedRequest {
        var request: URLRequest
        var bodyData: Data?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _handler: (@Sendable (URLRequest) -> Stub)?
    nonisolated(unsafe) private static var _capturedRequests: [CapturedRequest] = []
    nonisolated(unsafe) private static var _hangRequests = false

    static var handler: (@Sendable (URLRequest) -> Stub)? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    static var hangRequests: Bool {
        get { lock.withLock { _hangRequests } }
        set { lock.withLock { _hangRequests = newValue } }
    }

    static var capturedRequests: [CapturedRequest] {
        lock.withLock { _capturedRequests }
    }

    static func reset() {
        lock.withLock {
            _handler = nil
            _capturedRequests = []
            _hangRequests = false
        }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let bodyData = Self.readBody(from: request)
        Self.lock.withLock {
            Self._capturedRequests.append(CapturedRequest(request: request, bodyData: bodyData))
        }

        if Self.hangRequests {
            // Deliberately never call back the client — the request stays
            // pending until the caller's Task is cancelled.
            return
        }

        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let stub = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data? {
        if let bodyData = request.httpBody {
            return bodyData
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private struct StubTokenProvider: AccessTokenProvider {
    let token: String?
    func accessToken() async throws -> String? { token }
}

private let testConfig = BackendConfig(supabaseURL: URL(string: "https://example.supabase.co")!, anonKey: "test-anon-key")

private func makeClient(
    token: String? = "test-access-token",
    timeoutBudget: Duration = .seconds(60),
    progressMarks: [EdgeFunctionsProgressMark] = [.fifteenSeconds, .thirtySeconds]
) -> EdgeFunctionsClient {
    EdgeFunctionsClient(
        config: testConfig,
        tokenProvider: StubTokenProvider(token: token),
        session: MockURLProtocol.makeSession(),
        timeoutBudget: timeoutBudget,
        progressMarks: progressMarks
    )
}

/// Extracts `name="..."` field values from a `multipart/form-data` body
/// for a given boundary, in appearance order (including duplicates, so a
/// field sent twice by mistake is visible rather than silently merged).
private func multipartFieldNames(body: Data, boundary: String) -> [String] {
    guard let text = String(data: body, encoding: .utf8) else { return [] }
    let parts = text.components(separatedBy: "--\(boundary)")
    var names: [String] = []
    for part in parts {
        guard let range = part.range(of: "name=\"") else { continue }
        let afterQuote = part[range.upperBound...]
        guard let endQuote = afterQuote.firstIndex(of: "\"") else { continue }
        names.append(String(afterQuote[afterQuote.startIndex..<endQuote]))
    }
    return names
}

// MARK: - Headers

extension MockNetworkSerialTests { @Suite struct EdgeFunctions {

@Test func transcribeAudioSendsExactHeadersAndURL() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.handler = { _ in
        .init(statusCode: 200, body: Data(#"{"transcript":"hi","request_id":"r1","deduped":false}"#.utf8))
    }

    let fileURL = try writeTempAudioFile()
    let client = makeClient()
    _ = try await client.transcribeAudio(fileURL: fileURL, mimeType: "audio/m4a", durationMS: 1000, idempotencyKey: "idem-1")

    let request = try #require(MockURLProtocol.capturedRequests.first?.request)
    #expect(request.url?.absoluteString == "https://example.supabase.co/functions/v1/transcribe_audio")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "apikey") == "test-anon-key")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-token")
    #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
}

@Test func extractFromTranscriptSendsJSONBodyWithTimeZone() async throws {
    MockURLProtocol.reset()
    let extractionBody = Data(#"{"subject_name_guess":null,"memory_draft":null,"key_things":[],"reminder_suggestion":null}"#.utf8)
    MockURLProtocol.handler = { _ in .init(statusCode: 200, body: extractionBody) }

    let client = makeClient()
    _ = try await client.extractFromTranscript(transcript: "Call Ben tomorrow.", timeZone: "America/Los_Angeles")

    let captured = try #require(MockURLProtocol.capturedRequests.first)
    #expect(captured.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(captured.request.url?.absoluteString == "https://example.supabase.co/functions/v1/extract_from_transcript")

    let decoded = try JSONDecoder().decode([String: String].self, from: try #require(captured.bodyData))
    #expect(decoded["transcript"] == "Call Ben tomorrow.")
    #expect(decoded["time_zone"] == "America/Los_Angeles")
}

@Test func extractFromTranscriptOmitsTimeZoneKeyWhenNil() async throws {
    MockURLProtocol.reset()
    let extractionBody = Data(#"{"subject_name_guess":null,"memory_draft":null,"key_things":[],"reminder_suggestion":null}"#.utf8)
    MockURLProtocol.handler = { _ in .init(statusCode: 200, body: extractionBody) }

    let client = makeClient()
    _ = try await client.extractFromTranscript(transcript: "Call Ben tomorrow.", timeZone: nil)

    let captured = try #require(MockURLProtocol.capturedRequests.first)
    let object = try JSONSerialization.jsonObject(with: try #require(captured.bodyData)) as? [String: Any]
    #expect(object?.keys.contains("time_zone") == false)
}

@Test func createRealtimeSessionSendsEmptyJSONBody() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.handler = { _ in
        .init(statusCode: 200, body: Data(#"{"client_secret":{"value":"secret","expires_at":1234567890},"mode":"realtime"}"#.utf8))
    }

    let client = makeClient()
    let info = try await client.createRealtimeTranscriptionSession()

    #expect(info.clientSecretValue == "secret")
    #expect(info.mode == "realtime")
    #expect(info.expiresAt == Date(timeIntervalSince1970: 1_234_567_890))

    let captured = try #require(MockURLProtocol.capturedRequests.first)
    #expect(captured.request.url?.absoluteString == "https://example.supabase.co/functions/v1/create_realtime_transcription_session")
    let object = try JSONSerialization.jsonObject(with: try #require(captured.bodyData)) as? [String: Any]
    #expect(object?.isEmpty == true)
}

@Test func deleteAccountDataPostsToExpectedURL() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.handler = { _ in .init(statusCode: 200, body: Data(#"{"ok":true}"#.utf8)) }

    let client = makeClient()
    try await client.deleteAccountData()

    let request = try #require(MockURLProtocol.capturedRequests.first?.request)
    #expect(request.url?.absoluteString == "https://example.supabase.co/functions/v1/delete_account_data")
    #expect(request.httpMethod == "POST")
}

@Test func missingAccessTokenThrowsAuthRequiredBeforeAnyRequest() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.handler = { _ in .init(statusCode: 200, body: Data()) }

    let client = makeClient(token: nil)
    do {
        try await client.deleteAccountData()
        Issue.record("Expected authRequired to throw")
    } catch let error as BackendError {
        #expect(error.code == BackendError.authRequired)
        #expect(error.httpStatus == 401)
    }
    #expect(MockURLProtocol.capturedRequests.isEmpty)
}

// MARK: - Multipart body

@Test func transcribeAudioMultipartBodyHasExpectedFieldsAndBoundary() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.handler = { _ in
        .init(statusCode: 200, body: Data(#"{"transcript":"hi","request_id":"r1","deduped":true}"#.utf8))
    }

    let fileURL = try writeTempAudioFile()
    let client = makeClient()
    let result = try await client.transcribeAudio(fileURL: fileURL, mimeType: "audio/m4a", durationMS: 4200, idempotencyKey: "idem-42")

    #expect(result.transcript == "hi")
    #expect(result.requestID == "r1")
    #expect(result.deduped == true)

    let captured = try #require(MockURLProtocol.capturedRequests.first)
    let contentType = try #require(captured.request.value(forHTTPHeaderField: "Content-Type"))
    let boundary = try #require(contentType.components(separatedBy: "boundary=").last)
    let body = try #require(captured.bodyData)

    let fieldNames = multipartFieldNames(body: body, boundary: boundary)
    #expect(fieldNames == ["audio_file", "idempotency_key", "mime_type", "duration_ms"])

    let bodyText = try #require(String(data: body, encoding: .utf8))
    #expect(bodyText.contains("idem-42"))
    #expect(bodyText.contains("4200"))
    #expect(bodyText.contains("audio/m4a"))
    #expect(bodyText.hasSuffix("--\(boundary)--\r\n"))
}

// MARK: - Error envelope decoding

@Test func transcribeAudioDecodesIdempotencyConflictOn409() async throws {
    MockURLProtocol.reset()
    let body = Data(#"{"error":"Idempotency key was already used with different audio payload","code":"IDEMPOTENCY_CONFLICT"}"#.utf8)
    MockURLProtocol.handler = { _ in .init(statusCode: 409, body: body) }

    let fileURL = try writeTempAudioFile()
    let client = makeClient()
    do {
        _ = try await client.transcribeAudio(fileURL: fileURL, mimeType: "audio/m4a", durationMS: 1000, idempotencyKey: "idem-1")
        Issue.record("Expected a thrown BackendError")
    } catch let error as BackendError {
        #expect(error.code == BackendError.idempotencyConflict)
        #expect(error.httpStatus == 409)
    }
}

@Test func transcribeAudioDecodesQuotaErrorOn402() async throws {
    MockURLProtocol.reset()
    let body = Data(#"{"error":"Transcription failed","code":"FREE_LIMIT_REACHED"}"#.utf8)
    MockURLProtocol.handler = { _ in .init(statusCode: 402, body: body) }

    let fileURL = try writeTempAudioFile()
    let client = makeClient()
    do {
        _ = try await client.transcribeAudio(fileURL: fileURL, mimeType: "audio/m4a", durationMS: 1000, idempotencyKey: "idem-1")
        Issue.record("Expected a thrown BackendError")
    } catch let error as BackendError {
        #expect(error.code == BackendError.freeLimitReached)
        #expect(error.httpStatus == 402)
    }
}

@Test func extractFromTranscriptDecodesAuthFailedOn401() async throws {
    MockURLProtocol.reset()
    let body = Data(#"{"error":"Unauthorized","code":"AUTH_FAILED"}"#.utf8)
    MockURLProtocol.handler = { _ in .init(statusCode: 401, body: body) }

    let client = makeClient()
    do {
        _ = try await client.extractFromTranscript(transcript: "hi", timeZone: nil)
        Issue.record("Expected a thrown BackendError")
    } catch let error as BackendError {
        #expect(error.code == BackendError.authFailed)
        #expect(error.httpStatus == 401)
    }
}

// MARK: - Timeout mapping

@Test func transcribeAudioTimesOutWithStageCodeWhenBudgetElapses() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.hangRequests = true

    let fileURL = try writeTempAudioFile()
    let client = makeClient(timeoutBudget: .milliseconds(50), progressMarks: [])
    do {
        _ = try await client.transcribeAudio(fileURL: fileURL, mimeType: "audio/m4a", durationMS: 1000, idempotencyKey: "idem-1")
        Issue.record("Expected a timeout to throw")
    } catch let error as BackendError {
        #expect(error.code == BackendError.transcribeTimeout)
        #expect(error.httpStatus == 504)
    }
}

@Test func extractFromTranscriptTimesOutWithStageCodeWhenBudgetElapses() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.hangRequests = true

    let client = makeClient(timeoutBudget: .milliseconds(50), progressMarks: [])
    do {
        _ = try await client.extractFromTranscript(transcript: "hi", timeZone: nil)
        Issue.record("Expected a timeout to throw")
    } catch let error as BackendError {
        #expect(error.code == BackendError.extractTimeout)
        #expect(error.httpStatus == 504)
    }
}

@Test func slowProgressFiresBeforeBudgetElapses() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.hangRequests = true

    let client = makeClient(
        timeoutBudget: .milliseconds(150),
        progressMarks: [EdgeFunctionsProgressMark(after: .milliseconds(20), seconds: 15)]
    )

    let progressSeconds = ProgressBox()
    do {
        _ = try await client.extractFromTranscript(transcript: "hi", timeZone: nil) { seconds in
            progressSeconds.record(seconds)
        }
        Issue.record("Expected a timeout to throw")
    } catch is BackendError {
        // expected
    }

    #expect(progressSeconds.values == [15])
}


// MARK: - Realtime session id

@Test func createRealtimeSessionDecodesTheSessionID() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.handler = { _ in
        .init(statusCode: 200, body: Data(#"{"client_secret":{"value":"secret","expires_at":1234567890},"mode":"realtime","session_id":"3f1b0c2e-0000-4000-8000-000000000001"}"#.utf8))
    }

    let info = try await makeClient().createRealtimeTranscriptionSession()

    #expect(info.sessionID == "3f1b0c2e-0000-4000-8000-000000000001")
}

/// An older server sends no id. That must still mint a usable session —
/// the caller falls back to the batch upload instead.
@Test func createRealtimeSessionDecodesAMissingSessionIDAsNil() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.handler = { _ in
        .init(statusCode: 200, body: Data(#"{"client_secret":{"value":"secret","expires_at":1234567890},"mode":"realtime"}"#.utf8))
    }

    let info = try await makeClient().createRealtimeTranscriptionSession()

    #expect(info.sessionID == nil)
    #expect(info.clientSecretValue == "secret")
}

/// The server has spelled `client_secret` both ways. Reading a bare
/// string is what keeps a client-server version skew from taking realtime
/// transcription out entirely.
@Test func createRealtimeSessionAcceptsAFlatClientSecret() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.handler = { _ in
        .init(statusCode: 200, body: Data(#"{"client_secret":"secret","mode":"realtime","session_id":"abc"}"#.utf8))
    }

    let info = try await makeClient().createRealtimeTranscriptionSession()

    #expect(info.clientSecretValue == "secret")
    #expect(info.expiresAt == nil)
    #expect(info.sessionID == "abc")
}

@Test func extractFromTranscriptSendsTheRealtimeSessionIDWhenGiven() async throws {
    MockURLProtocol.reset()
    let extractionBody = Data(#"{"subject_name_guess":null,"memory_draft":null,"key_things":[],"reminder_suggestion":null}"#.utf8)
    MockURLProtocol.handler = { _ in .init(statusCode: 200, body: extractionBody) }

    _ = try await makeClient().extractFromTranscript(
        transcript: "Call Ben tomorrow.",
        timeZone: nil,
        realtimeSessionID: "session-1"
    )

    let captured = try #require(MockURLProtocol.capturedRequests.first)
    let decoded = try JSONDecoder().decode([String: String].self, from: try #require(captured.bodyData))
    #expect(decoded["realtime_session_id"] == "session-1")
}

@Test func extractFromTranscriptOmitsTheRealtimeSessionIDKeyWhenNil() async throws {
    MockURLProtocol.reset()
    let extractionBody = Data(#"{"subject_name_guess":null,"memory_draft":null,"key_things":[],"reminder_suggestion":null}"#.utf8)
    MockURLProtocol.handler = { _ in .init(statusCode: 200, body: extractionBody) }

    _ = try await makeClient().extractFromTranscript(transcript: "Call Ben tomorrow.", timeZone: nil)

    let captured = try #require(MockURLProtocol.capturedRequests.first)
    let object = try JSONSerialization.jsonObject(with: try #require(captured.bodyData)) as? [String: Any]
    #expect(object?.keys.contains("realtime_session_id") == false)
}

@Test func createRealtimeSessionDecodesTheRateLimitCode() async throws {
    MockURLProtocol.reset()
    let body = Data(#"{"error":"Too many realtime sessions","code":"REALTIME_RATE_LIMITED"}"#.utf8)
    MockURLProtocol.handler = { _ in .init(statusCode: 429, body: body) }

    do {
        _ = try await makeClient().createRealtimeTranscriptionSession()
        Issue.record("Expected the rate-limit error to throw")
    } catch let error as BackendError {
        #expect(error.code == BackendError.realtimeRateLimited)
        #expect(error.httpStatus == 429)
    }
}

}}

/// A synchronous, thread-safe collector for `onSlowProgress` callbacks.
/// `EdgeFunctionsClient` calls `onSlowProgress` directly (not as an async
/// function) from inside its internal timeout race, so this cannot be an
/// actor — actor method calls require `await`, which a plain `(Int) ->
/// Void` closure body cannot perform.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int] = []

    var values: [Int] { lock.withLock { _values } }

    func record(_ value: Int) {
        lock.withLock { _values.append(value) }
    }
}

private func writeTempAudioFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("edge-functions-test-\(UUID().uuidString).m4a")
    try Data("fake-audio-bytes".utf8).write(to: url)
    return url
}
