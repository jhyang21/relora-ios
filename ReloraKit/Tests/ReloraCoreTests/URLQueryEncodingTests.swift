import Testing
import Foundation
@testable import ReloraCore

@Suite("URLComponents strict query encoding")
struct URLQueryEncodingTests {
    @Test("escapes every reserved character Foundation would leave bare")
    func escapesReservedCharacters() {
        #expect(URLComponents.strictQueryEscape("+") == "%2B")
        #expect(URLComponents.strictQueryEscape(" ") == "%20")
        #expect(URLComponents.strictQueryEscape(":") == "%3A")
        #expect(URLComponents.strictQueryEscape(",") == "%2C")
    }

    @Test("leaves the RFC 3986 unreserved characters alone")
    func leavesUnreservedCharactersAlone() {
        let unreserved = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
        #expect(URLComponents.strictQueryEscape(unreserved) == unreserved)
    }

    @Test("a timestamptz cursor survives the round trip with no bare +")
    func timestampCursorRoundTrips() throws {
        var components = try #require(URLComponents(string: "https://example.supabase.co/rest/v1/contacts"))
        let cursor = "gt.2026-09-02T09:15:43.60222+00:00"
        components.setStrictlyEncodedQueryItems([
            URLQueryItem(name: "user_id", value: "eq.abc"),
            URLQueryItem(name: "updated_at", value: cursor),
            URLQueryItem(name: "name", value: "eq.Ada Lovelace")
        ])

        // A bare `+` is the whole bug: PostgREST reads it as a space.
        let encoded = try #require(components.percentEncodedQuery)
        #expect(!encoded.contains("+"))
        #expect(encoded.contains("%2B00%3A00"))
        #expect(encoded.contains("%20"))

        // Still a well-formed query — every value decodes back unchanged.
        let items = try #require(components.queryItems)
        #expect(items.contains(URLQueryItem(name: "user_id", value: "eq.abc")))
        #expect(items.contains(URLQueryItem(name: "updated_at", value: cursor)))
        #expect(items.contains(URLQueryItem(name: "name", value: "eq.Ada Lovelace")))
    }

    @Test("an empty item list clears the query")
    func emptyItemsClearTheQuery() throws {
        var components = try #require(URLComponents(string: "https://example.supabase.co/rest/v1/contacts?select=*"))
        components.setStrictlyEncodedQueryItems([])

        #expect(components.percentEncodedQuery == nil)
        #expect(components.queryItems == nil)
    }
}
