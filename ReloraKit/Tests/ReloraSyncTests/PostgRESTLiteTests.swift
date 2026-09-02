import Foundation
import Testing
import ReloraCore
@testable import ReloraSync

/// Intercepts every request made through a `URLSession` configured with
/// this protocol registered, so tests never touch the network. Captures
/// each request (with its body, read from either `httpBody` or
/// `httpBodyStream` — `URLSession` may hand the loading system either)
/// for assertion, and replies with whatever `MockURLProtocol.handler`
/// returns.
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

    static var handler: (@Sendable (URLRequest) -> Stub)? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    static var capturedRequests: [CapturedRequest] {
        lock.withLock { _capturedRequests }
    }

    static func reset() {
        lock.withLock {
            _handler = nil
            _capturedRequests = []
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

private func makeClient(token: String? = "test-access-token") -> PostgRESTLite {
    PostgRESTLite(config: testConfig, tokenProvider: StubTokenProvider(token: token), session: MockURLProtocol.makeSession())
}

// MARK: - Headers

/// Serialized: every test here shares `MockURLProtocol`'s statics, and
/// Swift Testing otherwise interleaves them.
@Suite(.serialized) struct PostgRESTLiteSerialTests {

@Test func upsertSendsExactHeaders() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.handler = { _ in .init(statusCode: 200, body: Data()) }

    let client = makeClient()
    try await client.upsert(table: "contacts", rows: [["id": .string("c1")]], onConflict: "id")

    let request = try #require(MockURLProtocol.capturedRequests.first?.request)
    #expect(request.value(forHTTPHeaderField: "apikey") == "test-anon-key")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-token")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.value(forHTTPHeaderField: "Prefer") == "resolution=merge-duplicates")
}

@Test func selectSendsExactHeadersAndOmitsContentType() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.handler = { _ in .init(statusCode: 200, body: Data("[]".utf8)) }

    let client = makeClient()
    _ = try await client.select(table: "contacts", filters: [], order: "", range: (0, 9))

    let request = try #require(MockURLProtocol.capturedRequests.first?.request)
    #expect(request.value(forHTTPHeaderField: "apikey") == "test-anon-key")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-token")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
    #expect(request.httpMethod == "GET")
}

@Test func missingAccessTokenThrowsAuthRequiredBeforeAnyRequest() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.handler = { _ in .init(statusCode: 200, body: Data()) }

    let client = makeClient(token: nil)
    do {
        _ = try await client.select(table: "contacts", filters: [], order: "", range: (0, 9))
        Issue.record("Expected authRequired to throw")
    } catch let error as BackendError {
        #expect(error.code == BackendError.authRequired)
        #expect(error.httpStatus == 401)
    }
    #expect(MockURLProtocol.capturedRequests.isEmpty)
}

// MARK: - Upsert body / query construction

@Test func upsertSendsOnConflictAndColumnsParams() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.handler = { _ in .init(statusCode: 200, body: Data()) }

    let client = makeClient()
    try await client.upsert(
        table: "memories",
        rows: [["id": .string("m1"), "labels": .array([.string("a")])], ["id": .string("m2"), "text": .string("hi")]],
        onConflict: "id"
    )

    let request = try #require(MockURLProtocol.capturedRequests.first?.request)
    let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
    #expect(request.url?.path == "/rest/v1/memories")
    #expect(components.queryItems?.first(where: { $0.name == "on_conflict" })?.value == "id")
    let columnsValue = components.queryItems?.first(where: { $0.name == "columns" })?.value
    #expect(columnsValue == "\"id\",\"labels\",\"text\"")
    #expect(request.httpMethod == "POST")

    let bodyData = try #require(MockURLProtocol.capturedRequests.first?.bodyData)
    let decodedRows = try JSONDecoder().decode([JSONObject].self, from: bodyData)
    #expect(decodedRows.count == 2)
}

@Test func upsertWithEmptyRowsSendsNoRequest() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.handler = { _ in .init(statusCode: 500, body: Data()) }

    let client = makeClient()
    try await client.upsert(table: "contacts", rows: [], onConflict: "id")

    #expect(MockURLProtocol.capturedRequests.isEmpty)
}

// MARK: - Select filter / order / range construction

@Test func selectBuildsFiltersOrderAndOffsetLimitFromRange() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.handler = { _ in .init(statusCode: 200, body: Data("[]".utf8)) }

    let client = makeClient()
    _ = try await client.select(
        table: "reminders",
        filters: [
            URLQueryItem(name: "user_id", value: "eq.user-1"),
            URLQueryItem(name: "updated_at", value: "gt.2026-01-01T00:00:00.000Z"),
        ],
        order: "updated_at.asc,id.asc",
        range: (from: 500, to: 999)
    )

    let request = try #require(MockURLProtocol.capturedRequests.first?.request)
    let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
    let items = try #require(components.queryItems)

    #expect(items.contains(URLQueryItem(name: "select", value: "*")))
    #expect(items.contains(URLQueryItem(name: "user_id", value: "eq.user-1")))
    #expect(items.contains(URLQueryItem(name: "updated_at", value: "gt.2026-01-01T00:00:00.000Z")))
    #expect(items.contains(URLQueryItem(name: "order", value: "updated_at.asc,id.asc")))
    // range(500, 999) -> offset=500, limit=500 (inclusive range, matching
    // postgrest-js's `limit = to - from + 1`).
    #expect(items.contains(URLQueryItem(name: "offset", value: "500")))
    #expect(items.contains(URLQueryItem(name: "limit", value: "500")))
    // No Range header: this postgrest-js version uses offset/limit params,
    // not the older Range-header pagination convention.
    #expect(request.value(forHTTPHeaderField: "Range") == nil)
}

@Test func selectDecodesReturnedRows() async throws {
    MockURLProtocol.reset()
    let body = Data(#"[{"id":"c1","name":"Ada"}]"#.utf8)
    MockURLProtocol.handler = { _ in .init(statusCode: 200, body: body) }

    let client = makeClient()
    let rows = try await client.select(table: "contacts", filters: [], order: "", range: (0, 499))

    #expect(rows.count == 1)
    #expect(rows[0]["id"] == .string("c1"))
    #expect(rows[0]["name"] == .string("Ada"))
}

// MARK: - Allowlist rejection

@Test func disallowedTableThrowsBeforeAnyRequest() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.handler = { _ in .init(statusCode: 200, body: Data()) }

    let client = makeClient()
    do {
        _ = try await client.select(table: "tidynote_notes", filters: [], order: "", range: (0, 9))
        Issue.record("Expected disallowedTable to throw")
    } catch let error as BackendError {
        #expect(error.code == BackendError.disallowedTable)
    }
    #expect(MockURLProtocol.capturedRequests.isEmpty)

    do {
        try await client.upsert(table: "subscription_states", rows: [["id": .string("x")]], onConflict: "id")
        Issue.record("Expected disallowedTable to throw")
    } catch let error as BackendError {
        #expect(error.code == BackendError.disallowedTable)
    }
    #expect(MockURLProtocol.capturedRequests.isEmpty)
}

@Test func selectPercentEncodesEveryReservedCharacterInFilterValues() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.handler = { _ in .init(statusCode: 200, body: Data("[]".utf8)) }

    let cursor = "gt.2026-09-02T09:15:43.60222+00:00"
    let client = makeClient()
    _ = try await client.select(
        table: "contacts",
        filters: [
            URLQueryItem(name: "user_id", value: "eq.abc"),
            URLQueryItem(name: "updated_at", value: cursor),
            URLQueryItem(name: "name", value: "eq.Ada Lovelace"),
        ],
        order: "updated_at.asc,id.asc",
        range: (from: 0, to: 499)
    )

    let request = try #require(MockURLProtocol.capturedRequests.first?.request)
    let query = try #require(request.url?.query)
    // A bare `+` is the bug: PostgREST decodes it as a space, so the offset
    // reaches Postgres as `... 00:00` and the timestamptz filter is rejected.
    #expect(!query.contains("+"))
    #expect(query.contains("%2B00%3A00"))
    #expect(query.contains("%20"))

    // Still a well-formed query — the cursor decodes back byte for byte.
    let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
    let items = try #require(components?.queryItems)
    #expect(items.contains(URLQueryItem(name: "updated_at", value: cursor)))
    #expect(items.contains(URLQueryItem(name: "name", value: "eq.Ada Lovelace")))
}

// MARK: - Error envelope decoding

@Test func decodesPostgRESTErrorShapeOn409() async throws {
    MockURLProtocol.reset()
    let body = Data(#"{"message":"duplicate key value violates unique constraint","code":"23505","details":"Key (id)=(c1) already exists.","hint":null}"#.utf8)
    MockURLProtocol.handler = { _ in .init(statusCode: 409, body: body) }

    let client = makeClient()
    do {
        try await client.upsert(table: "contacts", rows: [["id": .string("c1")]], onConflict: nil)
        Issue.record("Expected a thrown BackendError")
    } catch let error as BackendError {
        #expect(error.code == "23505")
        #expect(error.httpStatus == 409)
        #expect(error.message.contains("duplicate key"))
    }
}

@Test func decodesEdgeFunctionErrorShapeOn401() async throws {
    MockURLProtocol.reset()
    let body = Data(#"{"error":"Missing Authorization header","code":"AUTH_REQUIRED"}"#.utf8)
    MockURLProtocol.handler = { _ in .init(statusCode: 401, body: body) }

    let client = makeClient()
    do {
        _ = try await client.select(table: "contacts", filters: [], order: "", range: (0, 9))
        Issue.record("Expected a thrown BackendError")
    } catch let error as BackendError {
        #expect(error.code == BackendError.authRequired)
        #expect(error.httpStatus == 401)
    }
}

@Test func fallsBackToStatusOnlyWhenBodyIsUndecodable() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.handler = { _ in .init(statusCode: 402, body: Data("not json".utf8)) }

    let client = makeClient()
    do {
        _ = try await client.select(table: "contacts", filters: [], order: "", range: (0, 9))
        Issue.record("Expected a thrown BackendError")
    } catch let error as BackendError {
        #expect(error.code == "HTTP_402")
        #expect(error.httpStatus == 402)
    }
}

}
