import Testing
import Foundation
@testable import ReloraCore

@Suite("QuotaPolicy")
struct QuotaTests {
    @Test("blocks free users after five processed notes")
    func blocksFreeUsersAfterFiveNotes() {
        let evaluation = QuotaPolicy.evaluate(
            planID: .free,
            usage: .init(totalProcessedNotes: 5, processedNotesThisMonth: 5)
        )

        #expect(evaluation.blockReason == .freeLimitReached)
        #expect(evaluation.canCreateVoiceNote == false)
        #expect(evaluation.freeNotesRemaining == 0)
        #expect(evaluation.noteDurationLimitMs == QuotaPolicy.freeNoteDurationLimitMs)
        #expect(evaluation.planID == .free)
    }

    @Test("blocks plus users after the monthly quota is exhausted")
    func blocksPlusUsersAfterMonthlyQuotaExhausted() {
        let evaluation = QuotaPolicy.evaluate(
            planID: .plus,
            usage: .init(totalProcessedNotes: 101, processedNotesThisMonth: QuotaPolicy.plusMonthlyNoteLimit)
        )

        #expect(evaluation.blockReason == .plusQuotaReached)
        #expect(evaluation.canCreateVoiceNote == false)
        #expect(evaluation.monthlyNotesRemaining == 0)
        #expect(evaluation.noteDurationLimitMs == QuotaPolicy.freeNoteDurationLimitMs) // == plusNoteDurationLimitMs, both 60_000
        #expect(evaluation.planID == .plus)
    }

    @Test("allows pro users with the longer duration limit")
    func allowsProUsersWithLongerDurationLimit() {
        let evaluation = QuotaPolicy.evaluate(
            planID: .pro,
            usage: .init(totalProcessedNotes: 250, processedNotesThisMonth: 250)
        )

        #expect(evaluation.blockReason == nil)
        #expect(evaluation.canCreateVoiceNote == true)
        #expect(evaluation.monthlyNotesRemaining == nil)
        #expect(evaluation.noteDurationLimitMs == QuotaPolicy.proNoteDurationLimitMs)
        #expect(evaluation.planID == .pro)
    }

    @Test("shows the soft upsell only for free users past the threshold, with quota left, not dismissed")
    func softUpsellConditions() {
        let underThreshold = QuotaPolicy.evaluate(
            planID: .free,
            usage: .init(totalProcessedNotes: 2, processedNotesThisMonth: 2)
        )
        #expect(!QuotaPolicy.shouldShowSoftUpsell(evaluation: underThreshold, totalProcessedNotes: 2, softUpsellDismissed: false))

        let atThreshold = QuotaPolicy.evaluate(
            planID: .free,
            usage: .init(totalProcessedNotes: 3, processedNotesThisMonth: 3)
        )
        #expect(QuotaPolicy.shouldShowSoftUpsell(evaluation: atThreshold, totalProcessedNotes: 3, softUpsellDismissed: false))
        #expect(!QuotaPolicy.shouldShowSoftUpsell(evaluation: atThreshold, totalProcessedNotes: 3, softUpsellDismissed: true))

        let exhausted = QuotaPolicy.evaluate(
            planID: .free,
            usage: .init(totalProcessedNotes: 5, processedNotesThisMonth: 5)
        )
        #expect(!QuotaPolicy.shouldShowSoftUpsell(evaluation: exhausted, totalProcessedNotes: 5, softUpsellDismissed: false))

        let plusEvaluation = QuotaPolicy.evaluate(
            planID: .plus,
            usage: .init(totalProcessedNotes: 10, processedNotesThisMonth: 10)
        )
        #expect(!QuotaPolicy.shouldShowSoftUpsell(evaluation: plusEvaluation, totalProcessedNotes: 10, softUpsellDismissed: false))
    }

    @Test("isWithinCurrentMonth uses the LOCAL calendar month, not UTC, across a month boundary")
    func isWithinCurrentMonthUsesLocalCalendarMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!

        // "Now" is Jan 31, 11 PM Eastern -- still January locally, even
        // though it is already Feb 1 in UTC.
        var nowComponents = DateComponents()
        nowComponents.year = 2026
        nowComponents.month = 1
        nowComponents.day = 31
        nowComponents.hour = 23
        let now = calendar.date(from: nowComponents)!

        var withinMonthComponents = DateComponents()
        withinMonthComponents.year = 2026
        withinMonthComponents.month = 1
        withinMonthComponents.day = 15
        withinMonthComponents.hour = 12
        let withinMonth = calendar.date(from: withinMonthComponents)!

        var justAfterBoundaryComponents = DateComponents()
        justAfterBoundaryComponents.year = 2026
        justAfterBoundaryComponents.month = 2
        justAfterBoundaryComponents.day = 1
        justAfterBoundaryComponents.hour = 0
        justAfterBoundaryComponents.minute = 1
        let justAfterBoundary = calendar.date(from: justAfterBoundaryComponents)!

        var justBeforeBoundaryComponents = DateComponents()
        justBeforeBoundaryComponents.year = 2026
        justBeforeBoundaryComponents.month = 1
        justBeforeBoundaryComponents.day = 31
        justBeforeBoundaryComponents.hour = 23
        justBeforeBoundaryComponents.minute = 59
        justBeforeBoundaryComponents.second = 59
        let justBeforeBoundary = calendar.date(from: justBeforeBoundaryComponents)!

        #expect(QuotaPolicy.isWithinCurrentMonth(ReloraTimestamp.from(withinMonth), now: now, calendar: calendar))
        #expect(QuotaPolicy.isWithinCurrentMonth(ReloraTimestamp.from(justBeforeBoundary), now: now, calendar: calendar))
        #expect(!QuotaPolicy.isWithinCurrentMonth(ReloraTimestamp.from(justAfterBoundary), now: now, calendar: calendar))
    }

    @Test("currentMonthWindow spans a full calendar month across a DST transition")
    func currentMonthWindowSpansDSTTransition() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!

        // America/New_York springs forward on March 8, 2026 -- a 23-hour
        // day in the middle of the month.
        var nowComponents = DateComponents()
        nowComponents.year = 2026
        nowComponents.month = 3
        nowComponents.day = 20
        nowComponents.hour = 12
        let now = calendar.date(from: nowComponents)!

        var beforeDSTComponents = DateComponents()
        beforeDSTComponents.year = 2026
        beforeDSTComponents.month = 3
        beforeDSTComponents.day = 5
        beforeDSTComponents.hour = 12
        let beforeDST = calendar.date(from: beforeDSTComponents)!

        var nextMonthComponents = DateComponents()
        nextMonthComponents.year = 2026
        nextMonthComponents.month = 4
        nextMonthComponents.day = 1
        nextMonthComponents.hour = 1
        let nextMonth = calendar.date(from: nextMonthComponents)!

        #expect(QuotaPolicy.isWithinCurrentMonth(ReloraTimestamp.from(beforeDST), now: now, calendar: calendar))
        #expect(!QuotaPolicy.isWithinCurrentMonth(ReloraTimestamp.from(nextMonth), now: now, calendar: calendar))

        let window = QuotaPolicy.currentMonthWindow(now: now, calendar: calendar)
        let daysInWindow = calendar.dateComponents([.day], from: window.start, to: window.end).day
        #expect(daysInWindow == 31) // March has 31 calendar days, DST notwithstanding.
    }

    @Test("usage source strings are preserved verbatim for client vs server billing events")
    func usageSourceStringsPreserved() {
        #expect(QuotaPolicy.clientUsageEventSource == "voice_capture_review")
        #expect(QuotaPolicy.serverUsageEventSource == "transcribe_audio")
    }
}
