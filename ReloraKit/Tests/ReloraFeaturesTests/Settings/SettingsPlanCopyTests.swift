import Foundation
import Testing
import ReloraCore
import ReloraServices
@testable import ReloraFeatures

/// Pins `SettingsPlanCopy.planName` and `.usageFooter` — in particular the
/// Plus branch, which the M10 review rewrote to RN parity: a populated
/// `monthlyNotesRemaining` renders "N of 100 notes used this month"
/// (planPresentation.ts), and only the honest `nil` (the pre-`load()`
/// placeholder) falls back to generic copy instead of RN's `?? 0`
/// "100 of 100 used" flash.
struct SettingsPlanCopyTests {
    private func snapshot(_ planID: QuotaPolicy.PlanID) -> SubscriptionSnapshot {
        SubscriptionSnapshot(planID: planID, periodType: nil, store: nil, willRenew: false, expirationDate: nil)
    }

    private func trialSnapshot(willRenew: Bool, expirationDate: Date?) -> SubscriptionSnapshot {
        SubscriptionSnapshot(planID: .pro, periodType: .trial, store: nil, willRenew: willRenew, expirationDate: expirationDate)
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

    // MARK: - planName

    @Test func planNameFree() {
        #expect(SettingsPlanCopy.planName(snapshot(.free)) == "Free")
    }

    @Test func planNamePlus() {
        #expect(SettingsPlanCopy.planName(snapshot(.plus)) == "Plus")
    }

    @Test func planNamePro() {
        #expect(SettingsPlanCopy.planName(snapshot(.pro)) == "Pro")
    }

    @Test func planNameProTrial() {
        let subscription = trialSnapshot(willRenew: true, expirationDate: nil)
        #expect(SettingsPlanCopy.planName(subscription) == "Pro Trial")
    }

    // MARK: - usageFooter

    @Test func freeShowsUsedCount() {
        let footer = SettingsPlanCopy.usageFooter(
            subscription: snapshot(.free),
            evaluation: evaluation(planID: .free, freeNotesUsed: 3)
        )
        #expect(footer == "3 of 5 free notes used. Voice notes up to 1 minute.")
    }

    @Test func freeOverQuotaClamps() {
        let footer = SettingsPlanCopy.usageFooter(
            subscription: snapshot(.free),
            evaluation: evaluation(planID: .free, freeNotesUsed: 9)
        )
        #expect(footer == "5 of 5 free notes used. Voice notes up to 1 minute.")
    }

    @Test func plusWithUsageShowsMonthlyCount() {
        let footer = SettingsPlanCopy.usageFooter(
            subscription: snapshot(.plus),
            evaluation: evaluation(planID: .plus, monthlyNotesRemaining: 88)
        )
        #expect(footer == "12 of 100 notes used this month. Voice notes up to 1 minute.")
    }

    @Test func plusWithNilRemainingUsesGenericCopy() {
        let footer = SettingsPlanCopy.usageFooter(
            subscription: snapshot(.plus),
            evaluation: evaluation(planID: .plus, monthlyNotesRemaining: nil)
        )
        #expect(footer == "Up to 100 notes a month. Voice notes up to 1 minute.")
    }

    @Test func plusUsageLabelClampsBothEnds() {
        // Over-allowance remaining reads as zero used, not negative.
        #expect(SettingsPlanCopy.formatPlusMonthlyUsageLabel(150) == "0 of 100 notes used this month")
        // Negative remaining (over-quota ledger) reads as fully used.
        #expect(SettingsPlanCopy.formatPlusMonthlyUsageLabel(-3) == "100 of 100 notes used this month")
        #expect(SettingsPlanCopy.formatPlusMonthlyUsageLabel(0) == "100 of 100 notes used this month")
    }

    @Test func proShowsUnlimitedCopy() {
        let footer = SettingsPlanCopy.usageFooter(
            subscription: snapshot(.pro),
            evaluation: evaluation(planID: .pro)
        )
        #expect(footer == "Unlimited voice notes, up to 5 minutes each.")
    }

    @Test func proTrialWillRenewWithDate() {
        let subscription = trialSnapshot(willRenew: true, expirationDate: Date())
        let footer = SettingsPlanCopy.usageFooter(subscription: subscription, evaluation: evaluation(planID: .pro))
        #expect(footer.hasPrefix("Ends "))
        #expect(footer.hasSuffix("Becomes a paid Pro plan when the trial ends."))
    }

    @Test func proTrialNoRenewWithDate() {
        let subscription = trialSnapshot(willRenew: false, expirationDate: Date())
        let footer = SettingsPlanCopy.usageFooter(subscription: subscription, evaluation: evaluation(planID: .pro))
        #expect(footer.hasPrefix("Ends "))
        #expect(footer.hasSuffix("This trial will not renew."))
    }

    @Test func proTrialWithoutDateOmitsEndsSentence() {
        let subscription = trialSnapshot(willRenew: true, expirationDate: nil)
        let footer = SettingsPlanCopy.usageFooter(subscription: subscription, evaluation: evaluation(planID: .pro))
        #expect(footer == "Becomes a paid Pro plan when the trial ends.")
    }
}
