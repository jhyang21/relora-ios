import Foundation

/// Encodes and decodes `[String]` values as the compact JSON TEXT stored in
/// SQLite `TEXT NOT NULL DEFAULT '[]'` columns (`contacts.descriptors`,
/// `memories.labels`), matching the `asJson()` / `JSON.parse(...)` pair in
/// apps/mobile/src/db/repositories.ts.
public enum TextJSONArray {
    public enum DecodingFailure: Error, Equatable {
        case invalidEncoding
    }

    /// Encodes `values` as compact JSON text, e.g. `["a","b"]`, matching
    /// JavaScript's `JSON.stringify` output for a string array (no
    /// whitespace, unicode characters left unescaped). Every write site in
    /// the RN repository layer passes a real array — `partial.descriptors
    /// ?? []`, `asJson(memory.labels)` — never `null`, so this never needs
    /// to represent "no value": an empty list encodes as `"[]"`.
    public static func encode(_ values: [String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        guard let data = try? encoder.encode(values),
              let string = String(data: data, encoding: .utf8) else {
            // [String] is always encodable; this is unreachable in
            // practice and exists only so encode() can stay non-throwing.
            return "[]"
        }
        return string
    }

    /// Decodes JSON TEXT read back from a SQLite column into `[String]`.
    ///
    /// `text == nil` mirrors the repository layer's own fallback —
    /// `JSON.parse(row.descriptors ?? '[]')` — and decodes to `[]`. Any
    /// other value is parsed as JSON and must decode to a string array;
    /// malformed JSON throws, exactly as `JSON.parse` would throw on a
    /// non-null column holding something other than a JSON array. The
    /// `NOT NULL DEFAULT '[]'` schema constraint means a throw here signals
    /// real data corruption, not a value worth silently discarding.
    public static func decode(_ text: String?) throws -> [String] {
        let json = text ?? "[]"
        guard let data = json.data(using: .utf8) else {
            throw DecodingFailure.invalidEncoding
        }
        return try JSONDecoder().decode([String].self, from: data)
    }
}
