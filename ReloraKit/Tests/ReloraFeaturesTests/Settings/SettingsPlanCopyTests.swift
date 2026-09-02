import Foundation
import Testing
import ReloraCore
import ReloraServices
@testable import ReloraFeatures

/// Pins `SettingsPlanCopy.build` — in particular the Plus branch, which the
/// M10 review rewrote to RN parity: a populated `monthlyNotesRemaining`
/// renders "N of 100 notes used this month" (planPresentation.ts), and only
/// the honest `nil` (the pre-`load()` placeholder) falls back to generic
/// copy instead of RN's `?? 0` "100 of 100 used" flash.
struct SettingsPlanCopyTests {
    private func snapshot(_ planID: QuotaPolicy.PlanID) -> SubscriptionSnapshot {
        SubscriptionSnapshot(planID: planID, periodType: nil, store: nil, willRenew: false, expirationDate: nil)
    }

    private func evaluation(planID: QuotaPolicy.PlanID, freeNotesUsed: Int = 0, monthlyNotesRemaining: Int? = nil) -> QuotaPolicy.Evaluation {
        QuotaPolicy.Evaluation(
            blockReason: nil,
            canCreateVoiceNote: true,
            freeNotesRemaining: max(0, QuotaPolicy.freeNoteLimit - freeNotesUsed),
            freeNotesUsed: freeNotesUsed,
            monthlyNotesRemaining: monthlyNotesRemaining,
            noteDurationLimitMs: QuotaPolicy.freeNoteDurationLimitMs,
            planID: planID
        )
    }

    @Test func plusWithUsageShowsMonthlyCount() {
        let summary = SettingsPlanCopy.build(
            subscription: snapshot(.plus),
            evaluation: evaluation(planID: .plus, monthlyNotesRemaining: 88)
        )
        #expect(summary.title == "Plus")
        #expect(summary.description == "12 of 100 notes used this month. Voice notes up to 1 minute.")
    }

    @Test func plusWithNilRemainingUsesGenericCopy() {
        let summary = SettingsPlanCopy.build(
            subscription: snapshot(.plus),
            evaluation: evaluation(planID: .plus, monthlyNotesRemaining: nil)
        )
        #expect(summary.title == "Plus")
        #expect(summary.description == "Voice notes up to 1 minute. Up to 100 notes a month.")
    }

    @Test func plusUsageLabelClampsBothEnds() {
        // Over-allowance remaining reads as zero used, not negative.
        #expect(SettingsPlanCopy.formatPlusMonthlyUsageLabel(150) == "0 of 100 notes used this month")
        // Negative remaining (over-quota ledger) reads as fully used.
        #expect(SettingsPlanCopy.formatPlusMonthlyUsageLabel(-3) == "100 of 100 notes used this month")
        #expect(SettingsPlanCopy.formatPlusMonthlyUsageLabel(0) == "100 of 100 notes used this month")
    }

    @Test func freeShowsUsedCount() {
        let summary = SettingsPlanCopy.build(
            subscription: snapshot(.free),
            evaluation: evaluation(planID: .free, freeNotesUsed: 2)
        )
        #expect(summary.title == "Free")
        #expect(summary.description == "2 of 5 free notes used. Voice notes up to 1 minute.")
    }

    @Test func proShowsUnlimitedCopy() {
        let summary = SettingsPlanCopy.build(
            subscription: snapshot(.pro),
            evaluation: evaluation(planID: .pro)
        )
        #expect(summary.title == "Pro")
        #expect(summary.description == "Unlimited voice notes, up to 5 minutes each.")
    }

    @Test func proTrialTitleCarriesEndDate() {
        var subscription = snapshot(.pro)
        subscription.periodType = .trial
        subscription.willRenew = true
        subscription.expirationDate = nil
        let summary = SettingsPlanCopy.build(subscription: subscription, evaluation: evaluation(planID: .pro))
        #expect(summary.title == "Pro trial")
        #expect(summary.description == "Unlimited voice notes up to 5 minutes. Becomes a paid Pro plan when the trial ends.")
    }
}
