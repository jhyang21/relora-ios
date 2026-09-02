import Foundation
import Testing
@testable import ReloraServices

private struct FakePurchasesError: Error, Sendable, Equatable {}

private let testConfig = BillingConfig(
    appleAPIKey: "test-api-key",
    plusProductID: "com.immform.relora.plus.monthly",
    proProductID: "com.immform.relora.pro.monthly",
    plusEntitlementID: "Relora Plus",
    proEntitlementID: "Relora Pro"
)

private func entitlement(
    id: String,
    productID: String,
    willRenew: Bool = true,
    periodType: PurchasesPeriodType = .normal,
    expirationDate: Date? = nil,
    store: PurchasesStore = .apple
) -> PurchasesEntitlementInfo {
    PurchasesEntitlementInfo(
        identifier: id,
        productIdentifier: productID,
        isActive: true,
        willRenew: willRenew,
        periodType: periodType,
        expirationDate: expirationDate,
        store: store
    )
}

// MARK: - FakePurchasesProviding

/// An actor, like `FakeAuthBackend` in IdentityControllerTests.swift — every
/// `PurchasesProviding` requirement is already `async`, so there is no
/// synchronous surface forcing a lock-guarded class instead.
private actor FakePurchasesProviding: PurchasesProviding {
    private(set) var configureCalls: [String] = []
    private(set) var logInCalls: [String] = []
    private(set) var logOutCallCount = 0
    private(set) var productsCalls: [[String]] = []
    private(set) var purchaseCalls: [String] = []

    private var logInResult: Result<PurchasesCustomerInfo, Error>
    private var customerInfoResult: Result<PurchasesCustomerInfo, Error>
    private var productsResult: [PurchasesProduct]
    private var purchaseResult: Result<PurchasesPurchaseResult, Error>
    private var restoreResult: Result<PurchasesCustomerInfo, Error>

    init(
        logInResult: Result<PurchasesCustomerInfo, Error> = .success(.empty),
        customerInfoResult: Result<PurchasesCustomerInfo, Error> = .success(.empty),
        productsResult: [PurchasesProduct] = [],
        purchaseResult: Result<PurchasesPurchaseResult, Error> = .success(.userCancelled),
        restoreResult: Result<PurchasesCustomerInfo, Error> = .success(.empty)
    ) {
        self.logInResult = logInResult
        self.customerInfoResult = customerInfoResult
        self.productsResult = productsResult
        self.purchaseResult = purchaseResult
        self.restoreResult = restoreResult
    }

    func setCustomerInfoResult(_ result: Result<PurchasesCustomerInfo, Error>) { customerInfoResult = result }

    func configure(apiKey: String) async {
        configureCalls.append(apiKey)
    }

    func logIn(appUserID: String) async throws -> PurchasesCustomerInfo {
        logInCalls.append(appUserID)
        return try logInResult.get()
    }

    func logOut() async throws {
        logOutCallCount += 1
    }

    func products(identifiers: [String]) async -> [PurchasesProduct] {
        productsCalls.append(identifiers)
        return productsResult
    }

    func customerInfo() async throws -> PurchasesCustomerInfo {
        try customerInfoResult.get()
    }

    func purchase(productID: String) async throws -> PurchasesPurchaseResult {
        purchaseCalls.append(productID)
        return try purchaseResult.get()
    }

    func restorePurchases() async throws -> PurchasesCustomerInfo {
        try restoreResult.get()
    }
}

// MARK: - Entitlement precedence and plan mapping

@MainActor
@Test func proEntitlementWinsOverPlusWhenBothActive() async {
    let info = PurchasesCustomerInfo(activeEntitlements: [
        "Relora Plus": entitlement(id: "Relora Plus", productID: testConfig.plusProductID),
        "Relora Pro": entitlement(id: "Relora Pro", productID: testConfig.proProductID),
    ])
    let fake = FakePurchasesProviding(customerInfoResult: .success(info))
    let billing = BillingService(purchases: fake, config: testConfig)

    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))

    #expect(billing.subscriptionSnapshot.planID == .pro)
}

@MainActor
@Test func plusEntitlementMapsToPlusPlanWhenProIsAbsent() async {
    let info = PurchasesCustomerInfo(activeEntitlements: [
        "Relora Plus": entitlement(id: "Relora Plus", productID: testConfig.plusProductID),
    ])
    let fake = FakePurchasesProviding(customerInfoResult: .success(info))
    let billing = BillingService(purchases: fake, config: testConfig)

    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))

    #expect(billing.subscriptionSnapshot.planID == .plus)
}

@MainActor
@Test func noActiveEntitlementsMapsToFreePlan() async {
    let fake = FakePurchasesProviding(customerInfoResult: .success(.empty))
    let billing = BillingService(purchases: fake, config: testConfig)

    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))

    #expect(billing.subscriptionSnapshot == .free)
}

@MainActor
@Test func customerInfoFailureFallsBackToFreeRatherThanThrowing() async {
    let fake = FakePurchasesProviding(customerInfoResult: .failure(FakePurchasesError()))
    let billing = BillingService(purchases: fake, config: testConfig)

    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))

    #expect(billing.subscriptionSnapshot == .free)
}

@MainActor
@Test func trialIsActiveOnlyForATrialingProEntitlement() async {
    let trialing = PurchasesCustomerInfo(activeEntitlements: [
        "Relora Pro": entitlement(id: "Relora Pro", productID: testConfig.proProductID, periodType: .trial),
    ])
    let fake = FakePurchasesProviding(customerInfoResult: .success(trialing))
    let billing = BillingService(purchases: fake, config: testConfig)

    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))

    #expect(billing.subscriptionSnapshot.trialIsActive)

    let normalPro = PurchasesCustomerInfo(activeEntitlements: [
        "Relora Pro": entitlement(id: "Relora Pro", productID: testConfig.proProductID, periodType: .normal),
    ])
    await fake.setCustomerInfoResult(.success(normalPro))
    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))

    #expect(!billing.subscriptionSnapshot.trialIsActive)
}

// MARK: - handleIdentityChange: logIn / logOut on identity transitions

@MainActor
@Test func accountIdentityConfiguresAndLogsInWithLowercasedUserID() async {
    let fake = FakePurchasesProviding()
    let billing = BillingService(purchases: fake, config: testConfig)

    // `Identity.account` already carries whatever casing upstream produced;
    // `BillingService` logs in with exactly the id it is handed — the
    // lowercasing contract lives at the call site that builds the
    // `Identity` in the first place (Supabase user ids), not here.
    await billing.handleIdentityChange(.account(userID: "acct-lower", email: "a@example.com"))

    #expect(await fake.configureCalls == ["test-api-key"])
    #expect(await fake.logInCalls == ["acct-lower"])
    #expect(await fake.productsCalls == [[testConfig.plusProductID, testConfig.proProductID]])
}

@MainActor
@Test func accountIdentityPopulatesCatalogKeyedByPlan() async {
    let products = [
        PurchasesProduct(identifier: testConfig.plusProductID, localizedPriceString: "$4.99"),
        PurchasesProduct(identifier: testConfig.proProductID, localizedPriceString: "$19.99"),
    ]
    let fake = FakePurchasesProviding(productsResult: products)
    let billing = BillingService(purchases: fake, config: testConfig)

    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))

    #expect(billing.purchaseCatalog[.plus]?.localizedPriceString == "$4.99")
    #expect(billing.purchaseCatalog[.pro]?.localizedPriceString == "$19.99")
    #expect(billing.isCatalogAvailable)
}

@MainActor
@Test func emptyCatalogResponseMarksCatalogUnavailable() async {
    let fake = FakePurchasesProviding(productsResult: [])
    let billing = BillingService(purchases: fake, config: testConfig)

    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))

    #expect(!billing.isCatalogAvailable)
}

@MainActor
@Test func switchingFromAccountToLocalGuestLogsOutAndResets() async {
    let fake = FakePurchasesProviding()
    let billing = BillingService(purchases: fake, config: testConfig)

    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))
    await billing.handleIdentityChange(.localGuest(userID: "local-guest-1"))

    #expect(await fake.logOutCallCount == 1)
    #expect(billing.subscriptionSnapshot == .free)
    #expect(billing.purchaseCatalog.isEmpty)
    #expect(billing.isCatalogAvailable)
}

@MainActor
@Test func switchingFromAccountToAnonymousAlsoLogsOutAndResets() async {
    // Mirrors `refreshSubscriptionState`'s `identityKind !== 'account'`
    // guard: a real anonymous session gets no billing session either,
    // exactly like a local guest.
    let fake = FakePurchasesProviding()
    let billing = BillingService(purchases: fake, config: testConfig)

    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))
    await billing.handleIdentityChange(.anonymous(userID: "anon-1"))

    #expect(await fake.logOutCallCount == 1)
    #expect(billing.subscriptionSnapshot == .free)
}

@MainActor
@Test func guestToGuestTransitionNeverCallsLogOut() async {
    // No prior account session was ever logged in, so there is nothing to
    // log out of — `resetAndLogOut`'s `if loggedInUserID != nil` guard.
    let fake = FakePurchasesProviding()
    let billing = BillingService(purchases: fake, config: testConfig)

    await billing.handleIdentityChange(.localGuest(userID: "local-guest-1"))

    #expect(await fake.logOutCallCount == 0)
    #expect(billing.subscriptionSnapshot == .free)
}

@MainActor
@Test func unresolvedIdentityResetsWithoutLoggingIn() async {
    let fake = FakePurchasesProviding()
    let billing = BillingService(purchases: fake, config: testConfig)

    await billing.handleIdentityChange(.unresolved)

    #expect(await fake.logInCalls.isEmpty)
    #expect(await fake.configureCalls.isEmpty)
    #expect(billing.subscriptionSnapshot == .free)
}

@MainActor
@Test func missingConfigResetsAndNeverTouchesPurchases() async {
    let fake = FakePurchasesProviding()
    let billing = BillingService(purchases: fake, config: nil)

    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))

    #expect(await fake.configureCalls.isEmpty)
    #expect(await fake.logInCalls.isEmpty)
    #expect(billing.subscriptionSnapshot == .free)
}

// MARK: - purchase(planID:)

@MainActor
@Test func purchaseRequiresAccountWhenNoIdentityHasEverLoggedIn() async {
    let fake = FakePurchasesProviding()
    let billing = BillingService(purchases: fake, config: testConfig)

    let outcome = await billing.purchase(planID: .plus)

    #expect(outcome == .requiresAccount)
    #expect(await fake.purchaseCalls.isEmpty)
}

@MainActor
@Test func purchaseWithNoConfigFailsRatherThanCrashing() async {
    let fake = FakePurchasesProviding()
    let billing = BillingService(purchases: fake, config: nil)

    let outcome = await billing.purchase(planID: .plus)

    guard case .failed = outcome else {
        Issue.record("Expected .failed, got \(outcome)")
        return
    }
}

@MainActor
@Test func purchaseReturnsCancelledWithoutUpdatingSnapshot() async {
    let fake = FakePurchasesProviding(purchaseResult: .success(.userCancelled))
    let billing = BillingService(purchases: fake, config: testConfig)
    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))

    let outcome = await billing.purchase(planID: .plus)

    #expect(outcome == .cancelled)
    #expect(billing.subscriptionSnapshot == .free)
}

@MainActor
@Test func purchaseSuccessUpdatesSnapshotAndUsesTheProProductIDForPro() async {
    let info = PurchasesCustomerInfo(activeEntitlements: [
        "Relora Pro": entitlement(id: "Relora Pro", productID: testConfig.proProductID),
    ])
    let fake = FakePurchasesProviding(purchaseResult: .success(.success(info)))
    let billing = BillingService(purchases: fake, config: testConfig)
    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))

    let outcome = await billing.purchase(planID: .pro)

    #expect(outcome == .success(billing.subscriptionSnapshot))
    #expect(billing.subscriptionSnapshot.planID == .pro)
    #expect(await fake.purchaseCalls == [testConfig.proProductID])
}

@MainActor
@Test func purchaseFailureIsReportedAsFailed() async {
    let fake = FakePurchasesProviding(purchaseResult: .failure(FakePurchasesError()))
    let billing = BillingService(purchases: fake, config: testConfig)
    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))

    let outcome = await billing.purchase(planID: .plus)

    guard case .failed = outcome else {
        Issue.record("Expected .failed, got \(outcome)")
        return
    }
}

// MARK: - restorePurchases()

@MainActor
@Test func restoreRequiresAccountWhenNoIdentityHasEverLoggedIn() async {
    let fake = FakePurchasesProviding()
    let billing = BillingService(purchases: fake, config: testConfig)

    let outcome = await billing.restorePurchases()

    #expect(outcome == .requiresAccount)
}

@MainActor
@Test func restoreLandingOnFreeReportsNoPurchasesFound() async {
    let fake = FakePurchasesProviding(restoreResult: .success(.empty))
    let billing = BillingService(purchases: fake, config: testConfig)
    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))

    let outcome = await billing.restorePurchases()

    #expect(outcome == .noPurchasesFound)
}

@MainActor
@Test func restoreLandingOnAPaidPlanReportsRestored() async {
    let info = PurchasesCustomerInfo(activeEntitlements: [
        "Relora Plus": entitlement(id: "Relora Plus", productID: testConfig.plusProductID),
    ])
    let fake = FakePurchasesProviding(restoreResult: .success(info))
    let billing = BillingService(purchases: fake, config: testConfig)
    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))

    let outcome = await billing.restorePurchases()

    #expect(outcome == .restored(billing.subscriptionSnapshot))
    #expect(billing.subscriptionSnapshot.planID == .plus)
}

@MainActor
@Test func restoreFailureIsReportedAsFailed() async {
    let fake = FakePurchasesProviding(restoreResult: .failure(FakePurchasesError()))
    let billing = BillingService(purchases: fake, config: testConfig)
    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))

    let outcome = await billing.restorePurchases()

    guard case .failed = outcome else {
        Issue.record("Expected .failed, got \(outcome)")
        return
    }
}
