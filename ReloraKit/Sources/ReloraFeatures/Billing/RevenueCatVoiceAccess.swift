import Foundation
import ReloraCore
import ReloraData
import ReloraServices

/// The production `VoiceAccessProviding` conformer (M9): plan from
/// `BillingService`'s RevenueCat entitlement snapshot, usage from the
/// server ledger with a local fallback. Lives in `ReloraFeatures/Billing`
/// rather than `Voice/` — `Voice/VoiceQuotaGate.swift` is not this
/// milestone's to edit, and the protocol it declares is public precisely
/// so a conformer can live elsewhere.
///
/// There is no client usage-upload path here, by design — see
/// docs/milestone-notes.md, "Usage ledger — there is no client upload path
/// (M6, M9)". A signed-in user's usage events are written once, by the
/// server, inside `transcribe_audio`; this type only ever reads counts.
public struct RevenueCatVoiceAccess: VoiceAccessProviding {
    private let billing: BillingService
    private let usageQuery: any ServerUsageQuerying
    private let database: AppDatabase
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    public init(
        billing: BillingService,
        usageQuery: any ServerUsageQuerying,
        database: AppDatabase,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.billing = billing
        self.usageQuery = usageQuery
        self.database = database
        self.calendar = calendar
        self.now = now
    }

    public func accessSnapshot(userID: String?) async -> VoiceAccessSnapshot {
        guard let userID else {
            // No identity yet means nothing has been recorded under one.
            return .freeAndUnused
        }

        // `billing.subscriptionSnapshot` is already `.free` for anything
        // that is not `.account` — `BillingService.handleIdentityChange`
        // resets it for a local guest and a real anonymous session alike
        // (mirrors `refreshSubscriptionState`'s `identityKind !== 'account'`
        // guard) — so no separate guest check is needed here for the plan.
        let planID = await billing.subscriptionSnapshot.planID

        let window = QuotaPolicy.currentMonthWindow(now: now(), calendar: calendar)
        let usage = await usageSummary(userID: userID, window: window)

        return VoiceAccessSnapshot(evaluation: QuotaPolicy.evaluate(planID: planID, usage: usage))
    }

    /// Server-first for anyone who is *not* a local guest — this is the one
    /// place the local-guest check still matters: RN's
    /// `canUseServerUsageLedger` keys usage-ledger choice off the id prefix
    /// alone, not off plan or identity kind, so a real anonymous session
    /// (free plan, but a genuine `auth.users` row) still gets counted
    /// server-side. Falls back to the local ledger on any query failure,
    /// matching `getUsageSummary`'s try/catch.
    private func usageSummary(userID: String, window: (start: Date, end: Date)) async -> QuotaPolicy.UsageSummary {
        guard !LocalGuestID.isLocalGuestID(userID) else {
            return await localUsageSummary(userID: userID, window: window)
        }
        do {
            return try await usageQuery.usageSummary(userID: userID, monthStart: window.start, monthEnd: window.end)
        } catch {
            return await localUsageSummary(userID: userID, window: window)
        }
    }

    /// The local ledger, read the way `getLocalUsageSummary`
    /// (apps/mobile/src/features/billing/storage.ts) reads it: one unbounded
    /// count for the lifetime total, one bounded to the local calendar month.
    private func localUsageSummary(userID: String, window: (start: Date, end: Date)) async -> QuotaPolicy.UsageSummary {
        let database = self.database
        return await Task.detached(priority: .userInitiated) { () -> QuotaPolicy.UsageSummary in
            let ledger = UsageLedgerRepository(database: database)
            let total = (try? ledger.count(userID: userID)) ?? 0
            let month = (try? ledger.count(
                userID: userID,
                from: ReloraTimestamp.from(window.start),
                to: ReloraTimestamp.from(window.end)
            )) ?? 0
            return QuotaPolicy.UsageSummary(totalProcessedNotes: total, processedNotesThisMonth: month)
        }.value
    }
}
