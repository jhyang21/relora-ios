import Testing
import Foundation
@testable import ReloraCore

@Suite("ReloraTimestamp")
struct TimestampTests {
    @Test("now() matches the wire format shape")
    func nowMatchesShape() {
        let value = ReloraTimestamp.now()
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#
        #expect(value.range(of: pattern, options: .regularExpression) != nil)
    }

    @Test("from(_:) always emits exactly three fractional digits and a literal Z")
    func fromMatchesShape() {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 31
        components.hour = 12
        components.minute = 34
        components.second = 56
        components.nanosecond = 789_000_000
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: components)!

        #expect(ReloraTimestamp.from(date) == "2026-08-31T12:34:56.789Z")
    }

    @Test("string order agrees with chronological order")
    func stringOrderAgreesWithChronologicalOrder() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let dates = (0..<20).map { offset in
            calendar.date(byAdding: .second, value: offset * 137, to: Date(timeIntervalSince1970: 1_700_000_000))!
        }
        let wireTimestamps = dates.map(ReloraTimestamp.from)

        let sortedByString = wireTimestamps.sorted()
        let sortedByDate = dates.sorted().map(ReloraTimestamp.from)

        #expect(sortedByString == sortedByDate)
    }

    @Test("parse round-trips a value produced by from(_:) to millisecond precision")
    func parseRoundTrips() {
        let original = Date(timeIntervalSince1970: 1_798_000_012.345)
        let wire = ReloraTimestamp.from(original)
        let parsed = ReloraTimestamp.parse(wire)

        #expect(parsed != nil)
        if let parsed {
            #expect(abs(parsed.timeIntervalSince1970 - original.timeIntervalSince1970) < 0.001)
        }
    }

    @Test("parse rejects malformed input")
    func parseRejectsMalformedInput() {
        #expect(ReloraTimestamp.parse("") == nil)
        #expect(ReloraTimestamp.parse("not-a-date") == nil)
        #expect(ReloraTimestamp.parse("2026-08-31T12:34:56Z") == nil) // missing fractional digits
        #expect(ReloraTimestamp.parse("2026-08-31T12:34:56.7Z") == nil) // wrong digit count
        #expect(ReloraTimestamp.parse("2026-08-31T12:34:56.789+00:00") == nil) // offset instead of Z
        #expect(ReloraTimestamp.parse("2026-08-31 12:34:56.789Z") == nil) // missing T separator
    }

    @Test("parse accepts a well-formed wire timestamp")
    func parseAcceptsWellFormed() {
        #expect(ReloraTimestamp.parse("2026-08-31T12:34:56.789Z") != nil)
    }
}
