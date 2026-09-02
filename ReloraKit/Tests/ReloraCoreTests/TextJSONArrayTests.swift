import Testing
@testable import ReloraCore

@Suite("TextJSONArray")
struct TextJSONArrayTests {
    @Test("encode() produces compact JSON matching JSON.stringify shape")
    func encodeProducesCompactJSON() {
        #expect(TextJSONArray.encode([]) == "[]")
        #expect(TextJSONArray.encode(["a", "b"]) == "[\"a\",\"b\"]")
    }

    @Test("encode() leaves unicode characters unescaped, matching JSON.stringify")
    func encodePreservesUnicode() {
        #expect(TextJSONArray.encode(["café", "日本語"]) == "[\"café\",\"日本語\"]")
    }

    @Test("encode() escapes embedded quotes")
    func encodeEscapesQuotes() throws {
        let encoded = TextJSONArray.encode([#"she said "hi""#])
        let decoded = try TextJSONArray.decode(encoded)
        #expect(decoded == [#"she said "hi""#])
    }

    @Test("decode(nil) defaults to an empty array, matching JSON.parse(row.descriptors ?? '[]')")
    func decodeNilDefaultsToEmptyArray() throws {
        #expect(try TextJSONArray.decode(nil) == [])
    }

    @Test("decode(\"[]\") returns an empty array")
    func decodeEmptyArrayLiteral() throws {
        #expect(try TextJSONArray.decode("[]") == [])
    }

    @Test("decode round-trips values with unicode and embedded quotes")
    func decodeRoundTripsUnicodeAndQuotes() throws {
        let values = ["family", "José's café", "日本語のテスト", #"quote " inside"#]
        let encoded = TextJSONArray.encode(values)
        let decoded = try TextJSONArray.decode(encoded)
        #expect(decoded == values)
    }

    @Test("decode(\"\") throws, matching JSON.parse('') throwing")
    func decodeEmptyStringThrows() {
        #expect(throws: (any Error).self) {
            try TextJSONArray.decode("")
        }
    }

    @Test("decode throws on malformed JSON")
    func decodeMalformedJSONThrows() {
        #expect(throws: (any Error).self) {
            try TextJSONArray.decode("not json")
        }
        #expect(throws: (any Error).self) {
            try TextJSONArray.decode("[\"unterminated")
        }
    }

    @Test("decode throws when the JSON is valid but not a string array")
    func decodeNonArrayThrows() {
        #expect(throws: (any Error).self) {
            try TextJSONArray.decode("{\"a\":1}")
        }
        #expect(throws: (any Error).self) {
            try TextJSONArray.decode("[1,2,3]")
        }
    }
}
