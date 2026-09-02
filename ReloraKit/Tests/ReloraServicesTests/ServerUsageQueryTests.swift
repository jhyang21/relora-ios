import Foundation
import Testing
import ReloraCore
@testable import ReloraServices

/// Reuses `MockURLProtocol` from EdgeFunctionsTests.swift (same target,
/// internal — not `private` — so it is visible here without a duplicate
/// declaration). Its handler/capturedRequests/hangRequests statics are
/// process-wide, shared across every file in this target, so the tests
/// here and in EdgeFunctionsTests.swift all live under the serialized
/// `MockNetworkSerialTests` parent suite — the interleaving the M9
/// report flagged did happen on CI.

private struct StubTokenProvider: AccessTokenProvider {
    let token: String?
    func accessToken() async throws -> String? { token }
}

private let testConfig = BackendConfig(supabaseURL: URL(string: "https://example.supabase.co")!, anonKey: "test-anon-key")

private func makeQuery(token: String? = "test-access-token") -> PostgRESTUsageQuery {
    PostgRESTUsageQuery(
        config: testConfig,
        tokenProvider: StubTokenProvider(token: token),
        session: MockURLProtocol.makeSession()
    )
}

/// True for the month-bounded request (carries `processed_at` filters),
/// false for the lifetime-total request (`user_id` only).
private func isMonthRequest(_ request: URLRequest) -> Bool {
    guard let query = request.url?.query else { return false }
    return query.contains("processed_at")
}

private func contentRangeStub(statusCode: Int = 200, total: Int, headerValue: String? = nil) -> MockURLProtocol.Stub {
    MockURLProtocol.Stub(
        statusCode: statusCode,
        body: Data(),
        headers: ["Content-Range": headerValue ?? "*/\(total)"]
    )
}

// MARK: - Request shape

extension MockNetworkSerialTests { @Suite struct ServerUsageQuery {

@Test func usageSummaryIssuesHEADRequestsWithExactHeaders() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.handler = { request in
        contentRangeStub(total: isMonthRequest(request) ? 3 : 12)
    }

    let query = makeQuery(token: "the-access-token")
    _ = try await query.usageSummary(
        userID: "user-1",
        monthStart: Date(timeIntervalSince1970: 1_700_000_000),
        monthEnd: Date(timeIntervalSince1970: 1_702_000_000)
    )

    let requests = MockURLProtocol.capturedRequests.map(\.request)
    #expect(requests.count == 2)
    for request in requests {
        #expect(request.httpMethod == "HEAD")
        #expect(request.value(forHTTPHeaderField: "apikey") == "test-anon-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer the-access-token")
        #expect(request.value(forHTTPHeaderField: "Prefer") == "count=exact")
        #expect(request.url?.path == "/rest/v1/voice_note_usage_events")
        #expect(request.url?.query?.contains("select=*") == true)
        #expect(request.url?.query?.contains("user_id=eq.user-1") == true)
    }

    let monthRequest = requests.first { isMonthRequest($0) }
    #expect(monthRequest?.url?.query?.contains("processed_at=gte.") == true)
    #expect(monthRequest?.url?.query?.contains("processed_at=lt.") == true)
}

// MARK: - Content-Range parsing

@Test func usageSummaryReadsTotalAndMonthCountsFromContentRange() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.handler = { request in
        contentRangeStub(total: isMonthRequest(request) ? 3 : 12)
    }

    let query = makeQuery()
    let summary = try await query.usageSummary(
        userID: "user-1",
        monthStart: Date(timeIntervalSince1970: 1_700_000_000),
        monthEnd: Date(timeIntervalSince1970: 1_702_000_000)
    )

    #expect(summary.totalProcessedNotes == 12)
    #expect(summary.processedNotesThisMonth == 3)
}

@Test func usageSummaryParsesADashRangeContentRangeHeaderToo() async throws {
    MockURLProtocol.reset()
    MockURLProtocol.handler = { _ in contentRangeStub(total: 0, headerValue: "0-19/20") }

    let query = makeQuery()
    let summary = try await query.usageSummary(userID: "user-1", monthStart: Date(), monthEnd: Date())

    #expect(summary.totalProcessedNotes == 20)
    #expect(summary.processedNotesThisMonth == 20)
}

// MARK: - Failure paths

@Test func usageSummaryThrowsAuthRequiredAndMakesNoRequestWhenTokenIsMissing() async {
    MockURLProtocol.reset()
    MockURLProtocol.handler = { _ in contentRangeStub(total: 0) }

    let query = makeQuery(token: nil)

    await #expect(throws: BackendError.self) {
        _ = try await query.usageSummary(userID: "user-1", monthStart: Date(), monthEnd: Date())
    }
    #expect(MockURLProtocol.capturedRequests.isEmpty)
}

@Test func usageSummaryThrowsOnANon2xxResponse() async {
    MockURLProtocol.reset()
    MockURLProtocol.handler = { _ in MockURLProtocol.Stub(statusCode: 500, body: Data()) }

    let query = makeQuery()

    do {
        _ = try await query.usageSummary(userID: "user-1", monthStart: Date(), monthEnd: Date())
        Issue.record("Expected usageSummary to throw on a 500 response")
    } catch let error as BackendError {
        #expect(error.httpStatus == 500)
        #expect(error.code == "HTTP_500")
    } catch {
        Issue.record("Expected a BackendError, got \(error)")
    }
}

@Test func usageSummaryThrowsInvalidResponseWhenContentRangeIsMissing() async {
    MockURLProtocol.reset()
    MockURLProtocol.handler = { _ in MockURLProtocol.Stub(statusCode: 200, body: Data()) }

    let query = makeQuery()

    do {
        _ = try await query.usageSummary(userID: "user-1", monthStart: Date(), monthEnd: Date())
        Issue.record("Expected usageSummary to throw when Content-Range is absent")
    } catch let error as BackendError {
        #expect(error.code == BackendError.invalidResponse)
    } catch {
        Issue.record("Expected a BackendError, got \(error)")
    }
}

@Test func usageSummaryThrowsInvalidResponseWhenContentRangeIsUnparseable() async {
    MockURLProtocol.reset()
    MockURLProtocol.handler = { _ in
        MockURLProtocol.Stub(statusCode: 200, body: Data(), headers: ["Content-Range": "not-a-number"])
    }

    let query = makeQuery()

    do {
        _ = try await query.usageSummary(userID: "user-1", monthStart: Date(), monthEnd: Date())
        Issue.record("Expected usageSummary to throw when Content-Range does not end in a number")
    } catch let error as BackendError {
        #expect(error.code == BackendError.invalidResponse)
    } catch {
        Issue.record("Expected a BackendError, got \(error)")
    }
}

}}
