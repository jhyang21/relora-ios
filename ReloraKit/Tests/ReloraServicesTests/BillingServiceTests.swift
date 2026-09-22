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
    private(set) var diagnosticsCalls: [[String: String]] = []

    private var logInResult: Result<PurchasesCustomerInfo, Error>
    private var customerInfoResult: Result<PurchasesCustomerInfo, Error>
    private var productsResult: [PurchasesProduct]
    /// Thrown by `products` in place of `productsResult` when set.
    private var productsError: Error?
    private var purchaseResult: Result<PurchasesPurchaseResult, Error>
    private var restoreResult: Result<PurchasesCustomerInfo, Error>
    /// Per-product answers for `introEligibility`; anything not listed is
    /// `.eligible`, which is the answer a fresh Apple ID gets.
    private var eligibilityResult: [String: PurchasesIntroEligibility]

    /// While true, `products` / `introEligibility` suspend until the test
    /// calls `releaseProducts()` / `releaseEligibility()` — a StoreKit call
    /// stuck on the network. Neither answers cancellation, which is the
    /// case a deadline exists for.
    private var holdsProducts: Bool
    private var holdsEligibility: Bool
    private var productsWaiters: [CheckedContinuation<Void, Never>] = []
    private var eligibilityWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        logInResult: Result<PurchasesCustomerInfo, Error> = .success(.empty),
        customerInfoResult: Result<PurchasesCustomerInfo, Error> = .success(.empty),
        productsResult: [PurchasesProduct] = [],
        purchaseResult: Result<PurchasesPurchaseResult, Error> = .success(.userCancelled),
        restoreResult: Result<PurchasesCustomerInfo, Error> = .success(.empty),
        eligibilityResult: [String: PurchasesIntroEligibility] = [:],
        productsError: Error? = nil,
        holdsProducts: Bool = false,
        holdsEligibility: Bool = false
    ) {
        self.logInResult = logInResult
        self.customerInfoResult = customerInfoResult
        self.eligibilityResult = eligibilityResult
        self.productsResult = productsResult
        self.productsError = productsError
        self.purchaseResult = purchaseResult
        self.restoreResult = restoreResult
        self.holdsProducts = holdsProducts
        self.holdsEligibility = holdsEligibility
    }

    func setCustomerInfoResult(_ result: Result<PurchasesCustomerInfo, Error>) { customerInfoResult = result }

    /// Replaces the catalog answer and clears any lookup error.
    func setProducts(_ products: [PurchasesProduct]) {
        productsResult = products
        productsError = nil
    }

    func releaseProducts() {
        holdsProducts = false
        productsWaiters.forEach { $0.resume() }
        productsWaiters.removeAll()
    }

    func releaseEligibility() {
        holdsEligibility = false
        eligibilityWaiters.forEach { $0.resume() }
        eligibilityWaiters.removeAll()
    }

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

    func products(identifiers: [String]) async throws -> [PurchasesProduct] {
        productsCalls.append(identifiers)
        if holdsProducts {
            await withCheckedContinuation { productsWaiters.append($0) }
        }
        if let productsError {
            throw productsError
        }
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

    func introEligibility(productIDs: [String]) async -> [String: PurchasesIntroEligibility] {
        if holdsEligibility {
            await withCheckedContinuation { eligibilityWaiters.append($0) }
        }
        return Dictionary(uniqueKeysWithValues: productIDs.map { ($0, eligibilityResult[$0] ?? .eligible) })
    }

    func recordDiagnostics(_ attributes: [String: String]) async {
        diagnosticsCalls.append(attributes)
    }
}

/// A `BillingService` whose diagnostics read a fixed storefront: the test
/// host has no App Store account to ask.
@MainActor
private func makeBilling(
    _ fake: FakePurchasesProviding,
    timeouts: BillingTimeouts = BillingTimeouts()
) -> BillingService {
    BillingService(purchases: fake, config: testConfig, timeouts: timeouts, storefrontCountry: { "USA" })
}

/// Spins until `condition` holds. Bounded, so a broken expectation fails
/// the test rather than hanging CI. Sleeps rather than only yielding: the
/// product lookup runs off the main actor.
@MainActor
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<2_000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
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

// MARK: - Trial eligibility

/// The Pro product in these three tests carries a real seven-day trial;
/// only the eligibility answer moves. That is the whole point of the
/// property: the offer is on the product either way, and what a given
/// Apple ID may take is a separate question the paywall must ask.
private let proTrialProduct = PurchasesProduct(
    identifier: testConfig.proProductID,
    localizedPriceString: "$19.99",
    subscriptionPeriod: PurchasesSubscriptionPeriod(unit: .month, value: 1),
    introductoryOffer: PurchasesIntroOffer(
        period: PurchasesSubscriptionPeriod(unit: .week, value: 1),
        paymentMode: .freeTrial,
        localizedPriceString: "$0.00"
    )
)

@MainActor
@Test func eligibleTrialIsCarriedThroughToTheSnapshot() async {
    let fake = FakePurchasesProviding(
        productsResult: [proTrialProduct],
        eligibilityResult: [testConfig.proProductID: .eligible]
    )
    let billing = BillingService(purchases: fake, config: testConfig)

    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))

    #expect(billing.trialEligibility[.pro] == .eligible)
}

@MainActor
@Test func anIneligibleAppleIDIsReportedAsIneligible() async {
    let fake = FakePurchasesProviding(
        productsResult: [proTrialProduct],
        eligibilityResult: [testConfig.proProductID: .ineligible]
    )
    let billing = BillingService(purchases: fake, config: testConfig)

    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))

    #expect(billing.trialEligibility[.pro] == .ineligible)
}

/// A product with no introductory offer answers `.noOffer` whatever
/// StoreKit says about it — the fake here would otherwise default to
/// `.eligible`, which would put trial copy on a plan that has no trial.
@MainActor
@Test func aProductWithoutAnOfferIsNoOfferRatherThanEligible() async {
    let plusWithoutOffer = PurchasesProduct(
        identifier: testConfig.plusProductID,
        localizedPriceString: "$4.99",
        subscriptionPeriod: PurchasesSubscriptionPeriod(unit: .month, value: 1)
    )
    let fake = FakePurchasesProviding(productsResult: [plusWithoutOffer])
    let billing = BillingService(purchases: fake, config: testConfig)

    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))

    #expect(billing.trialEligibility[.plus] == .noOffer)
}

/// Signing out clears the eligibility map with the catalog. A stale
/// "eligible" on the next guest's paywall would promise a trial against
/// somebody else's purchase history.
@MainActor
@Test func leavingAnAccountClearsTrialEligibility() async {
    let fake = FakePurchasesProviding(
        productsResult: [proTrialProduct],
        eligibilityResult: [testConfig.proProductID: .eligible]
    )
    let billing = BillingService(purchases: fake, config: testConfig)

    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))
    await billing.handleIdentityChange(.localGuest(userID: "local-guest-1"))

    #expect(billing.trialEligibility.isEmpty)
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

// MARK: - Catalog publishing, deadlines and retry

/// The paywall's prices must not wait on the trial check: that check is
/// the slowest of the three calls, and until the catalog lands every plan
/// button stays disabled.
@MainActor
@Test func theCatalogPublishesWhileEligibilityIsStillPending() async {
    let fake = FakePurchasesProviding(
        productsResult: [proTrialProduct],
        eligibilityResult: [testConfig.proProductID: .ineligible],
        holdsEligibility: true
    )
    let billing = makeBilling(fake)

    let change = Task { await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com")) }
    let loaded = await waitUntil { billing.catalogLoaded }

    #expect(loaded)
    #expect(billing.isCatalogAvailable)
    #expect(billing.purchaseCatalog[.pro] == proTrialProduct)
    #expect(billing.trialEligibility.isEmpty)

    await fake.releaseEligibility()
    await change.value

    #expect(billing.trialEligibility[.pro] == .ineligible)
}

/// An eligibility check past its deadline is no answer, which reads as
/// `.unknown` for a product that has an offer.
@MainActor
@Test func eligibilityPastItsDeadlineReadsAsUnknown() async {
    let fake = FakePurchasesProviding(productsResult: [proTrialProduct], holdsEligibility: true)
    let billing = makeBilling(fake, timeouts: BillingTimeouts(eligibility: .milliseconds(50)))

    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))

    #expect(billing.catalogLoaded)
    #expect(billing.trialEligibility[.pro] == .unknown)
    await fake.releaseEligibility()
}

@MainActor
@Test func aThrownLookupMarksTheCatalogUnavailableAndRecordsIt() async {
    let lookupError = PurchasesProviderError.productLookupFailed("StoreKit.StoreKitError#1: The network connection was lost.")
    let fake = FakePurchasesProviding(productsError: lookupError)
    let billing = makeBilling(fake)

    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))
    await billing.waitForDiagnostics()

    #expect(!billing.isCatalogAvailable)
    #expect(billing.catalogLoaded)
    #expect(billing.purchaseCatalog.isEmpty)
    let calls = await fake.diagnosticsCalls
    #expect(calls.count == 1)
    #expect(calls.first?["relora_billing_stage"] == "catalog")
    #expect(calls.first?["relora_billing_catalog"] == "StoreKit.StoreKitError#1: The network connection was lost.")
    #expect(calls.first?["relora_billing_error"] == "StoreKit.StoreKitError#1: The network connection was lost.")
    #expect(calls.first?["relora_storefront"] == "USA")
    #expect(calls.first?["relora_billing_at"] != nil)
    #expect(calls.first?["relora_build"] != nil)
}

/// A lookup that never answers is a failed lookup once its deadline
/// passes, not a paywall stuck on "Loading price…".
@MainActor
@Test func aLookupPastItsDeadlineCountsAsFailed() async {
    let fake = FakePurchasesProviding(productsResult: [proTrialProduct], holdsProducts: true)
    let billing = makeBilling(fake, timeouts: BillingTimeouts(products: .milliseconds(50)))

    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))
    await billing.waitForDiagnostics()

    #expect(billing.catalogLoaded)
    #expect(!billing.isCatalogAvailable)
    #expect(billing.purchaseCatalog.isEmpty)
    #expect(await fake.diagnosticsCalls.first?["relora_billing_catalog"] == "timeout")
    await fake.releaseProducts()
}

/// A good lookup is recorded too, as a count, and names no failure stage.
@MainActor
@Test func aSuccessfulLookupRecordsTheProductCount() async {
    let products = [
        PurchasesProduct(identifier: testConfig.plusProductID, localizedPriceString: "$4.99"),
        PurchasesProduct(identifier: testConfig.proProductID, localizedPriceString: "$19.99"),
    ]
    let fake = FakePurchasesProviding(productsResult: products)
    let billing = makeBilling(fake)

    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))
    await billing.waitForDiagnostics()

    let calls = await fake.diagnosticsCalls
    #expect(calls.count == 1)
    #expect(calls.first?["relora_billing_catalog"] == "2 products")
    #expect(calls.first?["relora_billing_stage"] == nil)
}

@MainActor
@Test func refreshCatalogRepopulatesAfterAFailure() async {
    let fake = FakePurchasesProviding(productsError: PurchasesProviderError.productLookupFailed("offline"))
    let billing = makeBilling(fake)
    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))
    #expect(!billing.isCatalogAvailable)

    await fake.setProducts([
        PurchasesProduct(identifier: testConfig.plusProductID, localizedPriceString: "$4.99"),
        proTrialProduct,
    ])
    await billing.refreshCatalog()

    #expect(billing.isCatalogAvailable)
    #expect(billing.catalogLoaded)
    #expect(billing.purchaseCatalog[.plus]?.localizedPriceString == "$4.99")
    #expect(billing.purchaseCatalog[.pro] == proTrialProduct)
    // Eligibility is asked again for the retried catalog.
    #expect(billing.trialEligibility[.pro] == .eligible)
}

@MainActor
@Test func refreshCatalogWithoutAnAccountDoesNothing() async {
    let fake = FakePurchasesProviding(productsResult: [proTrialProduct])
    let billing = makeBilling(fake)

    await billing.refreshCatalog()

    #expect(await fake.productsCalls.isEmpty)
    #expect(!billing.catalogLoaded)
}

@MainActor
@Test func leavingAnAccountResetsCatalogLoaded() async {
    let fake = FakePurchasesProviding(productsResult: [proTrialProduct])
    let billing = makeBilling(fake)

    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))
    #expect(billing.catalogLoaded)
    await billing.handleIdentityChange(.localGuest(userID: "local-guest-1"))

    #expect(!billing.catalogLoaded)
}

// MARK: - Failure diagnostics

@MainActor
@Test func aFailedPurchaseRecordsStagePurchase() async {
    let fake = FakePurchasesProviding(
        purchaseResult: .failure(PurchasesProviderError.underlying("RevenueCat.ErrorCode#2: There was a problem with the App Store."))
    )
    let billing = makeBilling(fake)
    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))

    let outcome = await billing.purchase(planID: .plus)
    await billing.waitForDiagnostics()

    #expect(outcome == .failed(BillingService.failureMessage(stage: "purchase")))
    let last = await fake.diagnosticsCalls.last
    #expect(last?["relora_billing_stage"] == "purchase")
    #expect(last?["relora_billing_product"] == testConfig.plusProductID)
    #expect(last?["relora_billing_error"] == "RevenueCat.ErrorCode#2: There was a problem with the App Store.")
}

/// A product StoreKit cannot find failed before any purchase began.
@MainActor
@Test func aProductNotFoundRecordsStageLookup() async {
    let fake = FakePurchasesProviding(
        purchaseResult: .failure(PurchasesProviderError.productNotFound(testConfig.proProductID))
    )
    let billing = makeBilling(fake)
    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))

    let outcome = await billing.purchase(planID: .pro)
    await billing.waitForDiagnostics()

    #expect(outcome == .failed(BillingService.failureMessage(stage: "lookup")))
    let last = await fake.diagnosticsCalls.last
    #expect(last?["relora_billing_stage"] == "lookup")
    #expect(last?["relora_billing_product"] == testConfig.proProductID)
    #expect(last?["relora_billing_error"] == "productNotFound: \(testConfig.proProductID)")
}

@MainActor
@Test func aFailedRestoreRecordsStageRestore() async {
    let fake = FakePurchasesProviding(restoreResult: .failure(PurchasesProviderError.underlying("RevenueCat.ErrorCode#10: Network error.")))
    let billing = makeBilling(fake)
    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))

    let outcome = await billing.restorePurchases()
    await billing.waitForDiagnostics()

    #expect(outcome == .failed(BillingService.failureMessage(stage: "restore")))
    let last = await fake.diagnosticsCalls.last
    #expect(last?["relora_billing_stage"] == "restore")
    #expect(last?["relora_billing_error"] == "RevenueCat.ErrorCode#10: Network error.")
}

/// A cancelled sheet is not a failure and leaves no record.
@MainActor
@Test func aCancelledPurchaseRecordsNothing() async {
    let fake = FakePurchasesProviding(purchaseResult: .success(.userCancelled))
    let billing = makeBilling(fake)
    await billing.handleIdentityChange(.account(userID: "acct-1", email: "a@example.com"))
    await billing.waitForDiagnostics()
    let before = await fake.diagnosticsCalls.count

    _ = await billing.purchase(planID: .plus)
    await billing.waitForDiagnostics()

    #expect(await fake.diagnosticsCalls.count == before)
}
