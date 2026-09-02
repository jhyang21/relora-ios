import Foundation
import Testing
@testable import ReloraFeatures

@Suite("TutorialSeed.reminderDate")
struct TutorialSeedTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test("Lands at 9:00am the day after `now`, in the given calendar's local time")
    func landsAtNineAMTomorrow() {
        let calendar = utc
        let now = calendar.date(from: DateComponents(year: 2026, month: 8, day: 31, hour: 14, minute: 30))!

        let result = TutorialSeed.reminderDate(from: now, calendar: calendar)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: result)

        #expect(components.year == 2026)
        #expect(components.month == 9)
        #expect(components.day == 1)
        #expect(components.hour == 9)
        #expect(components.minute == 0)
        #expect(components.second == 0)
    }

    @Test("Rolls across a month boundary correctly")
    func rollsAcrossMonthBoundary() {
        let calendar = utc
        let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 8, minute: 0))!

        let result = TutorialSeed.reminderDate(from: now, calendar: calendar)
        let components = calendar.dateComponents([.year, .month, .day], from: result)

        #expect(components.year == 2026)
        #expect(components.month == 2)
        #expect(components.day == 1)
    }

    @Test("Ignores the time-of-day `now` carries — always 9:00am tomorrow, whether now is early or late")
    func ignoresTimeOfDayInNow() {
        let calendar = utc
        let earlyNow = calendar.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 0, minute: 5))!
        let lateNow = calendar.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 23, minute: 55))!

        let earlyResult = calendar.dateComponents([.day, .hour, .minute], from: TutorialSeed.reminderDate(from: earlyNow, calendar: calendar))
        let lateResult = calendar.dateComponents([.day, .hour, .minute], from: TutorialSeed.reminderDate(from: lateNow, calendar: calendar))

        #expect(earlyResult.day == 11)
        #expect(lateResult.day == 11)
        #expect(earlyResult.hour == 9 && earlyResult.minute == 0)
        #expect(lateResult.hour == 9 && lateResult.minute == 0)
    }
}
