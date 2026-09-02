import Foundation

/// PostgREST-safe query encoding.
///
/// `URLComponents.queryItems` percent-encodes against
/// `CharacterSet.urlQueryAllowed`, which leaves every RFC 3986 sub-delimiter
/// bare — `+` included. PostgREST reads a bare `+` in a query value as a
/// space, so a `timestamptz` cursor sent as
/// `updated_at=gt.2026-09-02T09:15:43.60222+00:00` arrives at Postgres as
/// `… 00:00` and the whole request fails with `invalid input syntax for type
/// timestamp with time zone`. That is not a recoverable error: the cursor is
/// stored, so every later sync sends the same broken filter.
///
/// The fix is the one supabase-swift 2.55.1 applies in its own `escape()` —
/// subtract the reserved characters from the allowed set and hand the result
/// to `percentEncodedQueryItems`, which does no further encoding.
extension URLComponents {
    /// Replaces the query with `items`, percent-encoding each name and value
    /// strictly enough that PostgREST reads back exactly what was sent. An
    /// empty `items` clears the query, matching `queryItems = nil`.
    public mutating func setStrictlyEncodedQueryItems(_ items: [URLQueryItem]) {
        guard !items.isEmpty else {
            percentEncodedQueryItems = nil
            return
        }
        percentEncodedQueryItems = items.map { item in
            URLQueryItem(
                name: Self.strictQueryEscape(item.name),
                value: item.value.map(Self.strictQueryEscape)
            )
        }
    }

    /// `urlQueryAllowed` minus every RFC 3986 reserved character, so nothing
    /// a server might re-interpret survives unencoded.
    static let strictQueryAllowed: CharacterSet = CharacterSet.urlQueryAllowed
        .subtracting(CharacterSet(charactersIn: ":#[]@!$&'()*+,;="))

    /// Percent-encodes `string` for use as a query name or value.
    public static func strictQueryEscape(_ string: String) -> String {
        string.addingPercentEncoding(withAllowedCharacters: strictQueryAllowed) ?? string
    }
}
