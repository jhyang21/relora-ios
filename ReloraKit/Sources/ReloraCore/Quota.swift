import Foundation

/// Voice-note quota, duration limits, and usage-event source constants.
/// Ports packages/shared/src/billing/voiceAccess.ts,
/// apps/mobile/src/features/billing/entitlements.ts (`SOFT_UPSELL_THRESHOLD`
/// and `shouldShowSoftUpsell`), and the source-string constants written by
/// apps/mobile/src/features/billing/storage.ts and
/// apps/api/supabase/functions/transcribe_audio/index.ts.
public enum QuotaPolicy {
    /// Mirrors `VoicePlanId`.
    public enum PlanID: String, Equatable, Sendable {
        case free
        case plus
        case pro
    }

    /// Mirrors `VoiceQuotaBlockReason`. The RN `'none'` case is dropped in
    /// favor of `nil` — Swift already has Optional for "no reason".
    public enum BlockReason: String, Equatable, Sendable {
        case freeLimitReached = "free_limit_reached"
        case plusQuotaReached = "plus_quota_reached"
    }

    /// Mirrors `VoiceUsageSummary`.
    public struct UsageSummary: Equatable, Sendable {
        public var totalProcessedNotes: Int
        public var processedNotesThisMonth: Int

        public init(totalProcessedNotes: Int, processedNotesThisMonth: Int) {
            self.totalProcessedNotes = totalProcessedNotes
            self.processedNotesThisMonth = processedNotesThisMonth
        }
    }

    /// Mirrors `VoiceQuotaEvaluation`.
    public struct Evaluation: Equatable, Sendable {
        public var blockReason: BlockReason?
        public var canCreateVoiceNote: Bool
        public var freeNotesRemaining: Int
        public var freeNotesUsed: Int
        public var monthlyNotesRemaining: Int?
        public var noteDurationLimitMs: Int
        public var planID: PlanID

        public init(
            blockReason: BlockReason?,
            canCreateVoiceNote: Bool,
            freeNotesRemaining: Int,
            freeNotesUsed: Int,
            monthlyNotesRemaining: Int?,
            noteDurationLimitMs: Int,
            planID: PlanID
        ) {
            self.blockReason = blockReason
            self.canCreateVoiceNote = canCreateVoiceNote
            self.freeNotesRemaining = freeNotesRemaining
            self.freeNotesUsed = freeNotesUsed
            self.monthlyNotesRemaining = monthlyNotesRemaining
            self.noteDurationLimitMs = noteDurationLimitMs
            self.planID = planID
        }
    }

    // RN: FREE_NOTE_LIMIT
    public static let freeNoteLimit = 5
    // RN: PLUS_MONTHLY_NOTE_LIMIT
    public static let plusMonthlyNoteLimit = 100
    // RN: FREE_NOTE_DURATION_LIMIT_MS
    public static let freeNoteDurationLimitMs = 60_000
    // RN: PLUS_NOTE_DURATION_LIMIT_MS
    public static let plusNoteDurationLimitMs = 60_000
    // RN: PRO_NOTE_DURATION_LIMIT_MS
    public static let proNoteDurationLimitMs = 5 * 60_000
    // RN: SOFT_UPSELL_THRESHOLD (apps/mobile/src/features/billing/entitlements.ts)
    public static let softUpsellThreshold = 3

    /// Usage-event `source` written by the client review flow after a
    /// local (non-server-ledger) transcription. Preserve verbatim — mobile
    /// and API code compare/insert this as literal text, and the two sides
    /// intentionally use different strings for the same billing event.
    /// Mirrors `VOICE_NOTE_USAGE_SOURCE` in
    /// apps/mobile/src/features/billing/storage.ts.
    public static let clientUsageEventSource = "voice_capture_review"
    /// Usage-event `source` written by the server-side transcription
    /// function. Mirrors `VOICE_NOTE_USAGE_SOURCE` in
    /// apps/api/supabase/functions/transcribe_audio/index.ts.
    public static let serverUsageEventSource = "transcribe_audio"

    /// Mirrors `getNoteDurationLimitMs`.
    public static func noteDurationLimitMs(for planID: PlanID) -> Int {
        switch planID {
        case .pro: return proNoteDurationLimitMs
        case .plus: return plusNoteDurationLimitMs
        case .free: return freeNoteDurationLimitMs
        }
    }

    /// Mirrors `evaluateVoiceQuota`.
    public static func evaluate(planID: PlanID, usage: UsageSummary) -> Evaluation {
        switch planID {
        case .pro:
            return Evaluation(
                blockReason: nil,
                canCreateVoiceNote: true,
                freeNotesRemaining: max(0, freeNoteLimit - usage.totalProcessedNotes),
                freeNotesUsed: usage.totalProcessedNotes,
                monthlyNotesRemaining: nil,
                noteDurationLimitMs: proNoteDurationLimitMs,
                planID: .pro
            )

        case .plus:
            let monthlyNotesRemaining = max(0, plusMonthlyNoteLimit - usage.processedNotesThisMonth)
            return Evaluation(
                blockReason: monthlyNotesRemaining > 0 ? nil : .plusQuotaReached,
                canCreateVoiceNote: monthlyNotesRemaining > 0,
                freeNotesRemaining: max(0, freeNoteLimit - usage.totalProcessedNotes),
                freeNotesUsed: usage.totalProcessedNotes,
                monthlyNotesRemaining: monthlyNotesRemaining,
                noteDurationLimitMs: plusNoteDurationLimitMs,
                planID: .plus
            )

        case .free:
            let freeNotesRemaining = max(0, freeNoteLimit - usage.totalProcessedNotes)
            return Evaluation(
                blockReason: freeNotesRemaining > 0 ? nil : .freeLimitReached,
                canCreateVoiceNote: freeNotesRemaining > 0,
                freeNotesRemaining: freeNotesRemaining,
                freeNotesUsed: usage.totalProcessedNotes,
                monthlyNotesRemaining: nil,
                noteDurationLimitMs: freeNoteDurationLimitMs,
                planID: .free
            )
        }
    }

    /// Mirrors `shouldShowSoftUpsell` inside `buildAccessSnapshot`
    /// (apps/mobile/src/features/billing/entitlements.ts).
    public static func shouldShowSoftUpsell(
        evaluation: Evaluation,
        totalProcessedNotes: Int,
        softUpsellDismissed: Bool
    ) -> Bool {
        evaluation.planID == .free
            && totalProcessedNotes >= softUpsellThreshold
            && evaluation.freeNotesRemaining > 0
            && !softUpsellDismissed
    }

    /// The bounds `[start, end)` of the LOCAL calendar month containing
    /// `now`, computed in `calendar`'s time zone. Mirrors
    /// `getCurrentMonthWindow` in
    /// apps/mobile/src/features/billing/storage.ts, which builds the same
    /// bounds with the bare JS `Date` constructor — i.e. device-local wall
    /// time, not UTC. Pass a `calendar` carrying an explicit `TimeZone` for
    /// deterministic (testable, server-side) results; the default,
    /// `Calendar.current`, matches the RN behavior on-device.
    public static func currentMonthWindow(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        var components = calendar.dateComponents([.year, .month], from: now)
        components.day = 1
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.nanosecond = 0

        let start = calendar.date(from: components) ?? now
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return (start, end)
    }

    /// Whether wire timestamp `isoTimestamp` falls within the local
    /// calendar month containing `now`. Mirrors the
    /// `processed_at >= ? AND processed_at < ?` predicate the RN monthly
    /// usage query applies against `currentMonthWindow`'s bounds.
    public static func isWithinCurrentMonth(
        _ isoTimestamp: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard let date = ReloraTimestamp.parse(isoTimestamp) else {
            return false
        }
        let window = currentMonthWindow(now: now, calendar: calendar)
        return date >= window.start && date < window.end
    }
}
