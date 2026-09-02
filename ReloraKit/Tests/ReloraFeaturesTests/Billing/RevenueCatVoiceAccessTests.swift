import Foundation
import Testing
import ReloraCore
import ReloraData
@testable import ReloraServices
@testable import ReloraFeatures

private struct FakeUsageQueryError: Error, Sendable {}

private let testConfig = BillingConfig(
    appleAPIKey: "test-api-key",
    plusProductID: "com.immform.relora.plus.monthly",
    proProductID: "com.immform.relora.pro.monthly",
    plusEntitlementID: "Relora Plus",
    proEntitlementID: "Relora Pro"
)

// MARK: - Fakes

/// A minimal `PurchasesProviding` fake — only what `BillingService.handleIdentityChange`
/// needs to land on a given plan. Distinct from BillingServiceTests.swift's
/// own fake of the same name: different target (ReloraFeaturesTests vs
/// ReloraServicesTests), so no redeclaration conflict.
private actor FakePurchasesProviding: PurchasesProviding {
    private let customerInfoResult: Result<PurchasesCustomerInfo, Error>

    init(customerInfoResult: Result<PurchasesCustomerInfo, Error>) {
        self.customerInfoResult = customerInfoResult
    }

    func configure(apiKey: String) async {}
    func logIn(appUserID: String) async throws -> PurchasesCustomerInfo { try customerInfoResult.get() }
    func logOut() async throws {}
    func products(identifiers: [String]) async -> [PurchasesProduct] { [] }
    func customerInfo() async throws -> PurchasesCustomerInfo { try customerInfoResult.get() }
    func purchase(productID: String) async throws -> PurchasesPurchaseResult { .userCancelled }
    func restorePurchases() async throws -> PurchasesCustomerInfo { try customerInfoResult.get() }
}

private final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(userID: String, monthStart: Date, monthEnd: Date)] = []
    var calls: [(userID: String, monthStart: Date, monthEnd: Date)] { lock.withLock { _calls } }
    func record(_ call: (userID: String, monthStart: Date, monthEnd: Date)) { lock.withLock { _calls.append(call) } }
}

private struct FakeServerUsageQuery: ServerUsageQuerying {
    enum Behavior {
        case succeed(QuotaPolicy.UsageSummary)
        case fail
    }

    let behavior: Behavior
    let recorder: CallRecorder

    func usageSummary(userID: String, monthStart: Date, monthEnd: Date) async throws -> QuotaPolicy.UsageSummary {
        recorder.record((userID, monthStart, monthEnd))
        switch behavior {
        case .succeed(let summary): return summary
        case .fail: throw FakeUsageQueryError()
        }
    }
}

// MARK: - Fixtures

/// Billing with no configured RevenueCat session at all — models a local
/// guest or a fresh install, where `subscriptionSnapshot` stays `.free`.
@MainActor
private func freeBillingService() -> BillingService {
    BillingService(purchases: FakePurchasesProviding(customerInfoResult: .success(.empty)), config: nil)
}

/// Billing logged in to `.account(userID:)` and landed on `planID` via a
/// stubbed RevenueCat entitlement.
@MainActor
private func accountBillingService(planID: QuotaPolicy.PlanID, userID: String = "acct-1") async -> BillingService {
    var active: [String: PurchasesEntitlementInfo] = [:]
    switch planID {
    case .pro:
        active["Relora Pro"] = PurchasesEntitlementInfo(
            identifier: "Relora Pro", productIdentifier: testConfig.proProductID,
            isActive: true, willRenew: true, periodType: .normal, expirationDate: nil, store: .apple
        )
    case .plus:
        active["Relora Plus"] = PurchasesEntitlementInfo(
            identifier: "Relora Plus", productIdentifier: testConfig.plusProductID,
            isActive: true, willRenew: true, periodType: .normal, expirationDate: nil, store: .apple
        )
    case .free:
        break
    }
    let fake = FakePurchasesProviding(customerInfoResult: .success(PurchasesCustomerInfo(activeEntitlements: active)))
    let billing = BillingService(purchases: fake, config: testConfig)
    await billing.handleIdentityChange(.account(userID: userID, email: "a@example.com"))
    return billing
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return utcCalendar().date(from: components)!
}

// MARK: - No identity

@MainActor
@Test func nilUserIDReturnsFreeAndUnusedWithoutQueryingAnything() async {
    let recorder = CallRecorder()
    let voiceAccess = RevenueCatVoiceAccess(
        billing: freeBillingService(),
        usageQuery: FakeServerUsageQuery(behavior: .succeed(QuotaPolicy.UsageSummary(totalProcessedNotes: 99, processedNotesThisMonth: 99)), recorder: recorder),
        database: try! AppDatabase.inMemory()
    )

    let snapshot = await voiceAccess.accessSnapshot(userID: nil)

    #expect(snapshot == .freeAndUnused)
    #expect(recorder.calls.isEmpty)
}

// MARK: - Local guest short-circuit

@MainActor
@Test func localGuestNeverQueriesTheServerAndUsesTheLocalLedger() async throws {
    let database = try AppDatabase.inMemory()
    let ledger = UsageLedgerRepository(database: database)
    let guestID = LocalGuestID.generate()
    try ledger.append(userID: guestID, processedAt: ReloraTimestamp.from(date(2026, 8, 10)), source: QuotaPolicy.clientUsageEventSource)
    try ledger.append(userID: guestID, processedAt: ReloraTimestamp.from(date(2026, 8, 12)), source: QuotaPolicy.clientUsageEventSource)

    let recorder = CallRecorder()
    let voiceAccess = RevenueCatVoiceAccess(
        billing: freeBillingService(),
        usageQuery: FakeServerUsageQuery(behavior: .succeed(QuotaPolicy.UsageSummary(totalProcessedNotes: 999, processedNotesThisMonth: 999)), recorder: recorder),
        database: database,
        calendar: utcCalendar(),
        now: { date(2026, 8, 15) }
    )

    let snapshot = await voiceAccess.accessSnapshot(userID: guestID)

    #expect(recorder.calls.isEmpty)
    #expect(snapshot.evaluation.freeNotesUsed == 2)
    #expect(snapshot.planID == .free)
}

// MARK: - Real (non-guest) identity: server-first, local fallback

@MainActor
@Test func realAccountUsesServerCountsWhenTheQuerySucceeds() async {
    let recorder = CallRecorder()
    let voiceAccess = RevenueCatVoiceAccess(
        billing: await accountBillingService(planID: .plus, userID: "acct-42"),
        usageQuery: FakeServerUsageQuery(behavior: .succeed(QuotaPolicy.UsageSummary(totalProcessedNotes: 40, processedNotesThisMonth: 10)), recorder: recorder),
        database: try! AppDatabase.inMemory(),
        calendar: utcCalendar(),
        now: { date(2026, 8, 15) }
    )

    let snapshot = await voiceAccess.accessSnapshot(userID: "acct-42")

    #expect(recorder.calls.count == 1)
    #expect(recorder.calls.first?.userID == "acct-42")
    #expect(recorder.calls.first?.monthStart == date(2026, 8, 1))
    #expect(recorder.calls.first?.monthEnd == date(2026, 9, 1))
    #expect(snapshot.planID == .plus)
    #expect(snapshot.evaluation.monthlyNotesRemaining == 90)
}

@MainActor
@Test func realAccountFallsBackToTheLocalLedgerWhenTheServerQueryFails() async throws {
    let database = try AppDatabase.inMemory()
    let ledger = UsageLedgerRepository(database: database)
    try ledger.append(userID: "acct-7", processedAt: ReloraTimestamp.from(date(2026, 8, 10)), source: QuotaPolicy.serverUsageEventSource)

    let recorder = CallRecorder()
    let voiceAccess = RevenueCatVoiceAccess(
        billing: await accountBillingService(planID: .free, userID: "acct-7"),
        usageQuery: FakeServerUsageQuery(behavior: .fail, recorder: recorder),
        database: database,
        calendar: utcCalendar(),
        now: { date(2026, 8, 15) }
    )

    let snapshot = await voiceAccess.accessSnapshot(userID: "acct-7")

    #expect(recorder.calls.count == 1)
    #expect(snapshot.evaluation.freeNotesUsed == 1)
}

// MARK: - Month-boundary math

@MainActor
@Test func localFallbackCountsRespectTheHalfOpenCurrentMonthWindow() async throws {
    let database = try AppDatabase.inMemory()
    let ledger = UsageLedgerRepository(database: database)
    let userID = "acct-boundary"
    // One row just before the window, two inside it (one exactly on the
    // start boundary), one exactly on the end boundary (excluded — the
    // window is `[start, end)`).
    try ledger.append(userID: userID, processedAt: ReloraTimestamp.from(date(2026, 7, 31, 23, 59)), source: "s")
    try ledger.append(userID: userID, processedAt: ReloraTimestamp.from(date(2026, 8, 1, 0, 0)), source: "s")
    try ledger.append(userID: userID, processedAt: ReloraTimestamp.from(date(2026, 8, 31, 23, 59)), source: "s")
    try ledger.append(userID: userID, processedAt: ReloraTimestamp.from(date(2026, 9, 1, 0, 0)), source: "s")

    let recorder = CallRecorder()
    // Plus rather than free: `Evaluation.monthlyNotesRemaining` is only
    // populated for a monthly-capped plan, and is the one field that
    // reflects the month-scoped count directly — free's `freeNotesUsed`
    // is the unbounded lifetime count either way.
    let voiceAccess = RevenueCatVoiceAccess(
        billing: await accountBillingService(planID: .plus, userID: userID),
        usageQuery: FakeServerUsageQuery(behavior: .fail, recorder: recorder),
        database: database,
        calendar: utcCalendar(),
        now: { date(2026, 8, 15) }
    )

    let snapshot = await voiceAccess.accessSnapshot(userID: userID)

    // Lifetime total counts all four rows; the month count only the two
    // that fall in `[Aug 1 00:00, Sep 1 00:00)`.
    #expect(snapshot.evaluation.freeNotesUsed == 4)
    #expect(snapshot.evaluation.monthlyNotesRemaining == QuotaPolicy.plusMonthlyNoteLimit - 2)
}
