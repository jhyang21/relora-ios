import Foundation
import ReloraCore
import ReloraServices

/// What the composer is allowed to do, decided before a single sample is
/// recorded.
///
/// Ports the `accessSnapshot` fields `VoiceCaptureComposerScreen.tsx` reads:
/// `canCreateVoiceNote`, `blockReason`, `noteDurationLimitMs`, `planId`.
/// `QuotaPolicy.Evaluation` already carries all four — this is the loading
/// of it, not a second copy.
public struct VoiceAccessSnapshot: Equatable, Sendable {
    public var evaluation: QuotaPolicy.Evaluation

    public var canRecord: Bool { evaluation.canCreateVoiceNote }
    public var blockReason: QuotaPolicy.BlockReason? { evaluation.blockReason }
    public var planID: QuotaPolicy.PlanID { evaluation.planID }
    public var durationCap: Duration { .milliseconds(evaluation.noteDurationLimitMs) }

    public init(evaluation: QuotaPolicy.Evaluation) {
        self.evaluation = evaluation
    }

    /// What a fresh install with nothing recorded gets: the free plan, all
    /// five notes left, a one-minute cap.
    public static let freeAndUnused = VoiceAccessSnapshot(
        evaluation: QuotaPolicy.evaluate(
            planID: .free,
            usage: QuotaPolicy.UsageSummary(totalProcessedNotes: 0, processedNotesThisMonth: 0)
        )
    )
}

/// Where the plan and the usage counts come from.
///
/// ## Why this is a protocol
///
/// The gate has to decide record-or-paywall without depending on the billing
/// stack, so it asks through this one-method seam and the composition root
/// supplies the conformer: `Billing/RevenueCatVoiceAccess.swift` — plan from
/// the RevenueCat entitlement snapshot, usage server-first with the local
/// ledger as fallback. (M6 shipped an interim conformer here with the plan
/// hardcoded to `.free`, recorded as a deviation in the M6 report; M9's
/// replacement made it dead code and the simplify pass removed it.)
public protocol VoiceAccessProviding: Sendable {
    func accessSnapshot(userID: String?) async -> VoiceAccessSnapshot
}

/// The decision the composer makes before recording, and the copy that goes
/// with a plan's duration cap.
public enum VoiceQuotaGate {
    /// What opening the composer should do.
    public enum Decision: Equatable, Sendable {
        case record(cap: Duration)
        /// Out of quota. Carries the reason the paywall opens on, so the
        /// blocked screen can say which limit was hit.
        case paywall(AppRouter.PaywallReason)
    }

    /// Ports the `useEffect` gate plus `getBlockedPaywallParams`: a composer
    /// that cannot record never records. RN replaces the route rather than
    /// pushing, so the user cannot swipe back into a screen that would
    /// immediately bounce them again; the sheet equivalent is that the
    /// composer hands its slot to the paywall instead of opening at all.
    public static func decide(_ snapshot: VoiceAccessSnapshot) -> Decision {
        guard snapshot.canRecord else {
            return .paywall(paywallReason(for: snapshot.blockReason))
        }
        return .record(cap: snapshot.durationCap)
    }

    /// `plus_quota_reached` is the only reason that is not the free limit —
    /// RN's `getBlockedPaywallParams` defaults everything else, including a
    /// missing reason, to the hard free limit.
    public static func paywallReason(for blockReason: QuotaPolicy.BlockReason?) -> AppRouter.PaywallReason {
        blockReason == .plusQuotaReached ? .plusQuotaReached : .freeLimitReached
    }

    /// The paywall a mid-processing 402 opens. The server's error body says
    /// which wall was hit — `transcribe_audio` sends `PLUS_QUOTA_REACHED` for
    /// a Plus subscriber's monthly quota and `FREE_LIMIT_REACHED` otherwise —
    /// and anything else 402-shaped defaults to the free limit, the same
    /// default `paywallReason(for:)` applies.
    public static func paywallReason(forServerCode code: String) -> AppRouter.PaywallReason {
        code == BackendError.plusQuotaReached ? .plusQuotaReached : .freeLimitReached
    }

    /// The alert body shown when a recording hits its cap. Ports
    /// `getDurationLimitMessage` (`features/billing/entitlements.ts`).
    public static func durationLimitMessage(for planID: QuotaPolicy.PlanID) -> String {
        planID == .pro
            ? "Pro supports voice notes up to 5 minutes."
            : "This plan supports voice notes up to 1 minute. Upgrade to Pro for up to 5 minutes."
    }

    /// Whether the cap alert offers a way to lift the cap. Pro is already at
    /// the longest cap there is, so it gets acknowledgement and nothing else.
    public static func offersUpgrade(for planID: QuotaPolicy.PlanID) -> Bool {
        planID != .pro
    }
}
