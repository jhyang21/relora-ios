import Foundation
import Observation
import ReloraCore
import StoreKit

// MARK: - Configuration

/// RevenueCat product and entitlement identifiers, read from the bundle.
/// Mirrors `BackendConfigLoader`'s role for Supabase credentials — the
/// values arrive through `Config/Secrets.xcconfig` → `Info.plist`, so they
/// are build settings rather than anything checked in.
public struct BillingConfig: Sendable, Equatable {
    public var appleAPIKey: String
    public var plusProductID: String
    public var proProductID: String
    /// The RevenueCat *lookup key* for the Plus entitlement — carries
    /// spaces and capitals ("Relora Plus"), not a slug. See
    /// `PurchasesCustomerInfo.activeEntitlements`'s doc comment.
    public var plusEntitlementID: String
    public var proEntitlementID: String

    public init(
        appleAPIKey: String,
        plusProductID: String,
        proProductID: String,
        plusEntitlementID: String,
        proEntitlementID: String
    ) {
        self.appleAPIKey = appleAPIKey
        self.plusProductID = plusProductID
        self.proProductID = proProductID
        self.plusEntitlementID = plusEntitlementID
        self.proEntitlementID = proEntitlementID
    }
}

/// Reads `BillingConfig` from the bundle. A build with a placeholder API
/// key (the "replace-me" `Secrets.example.xcconfig` default) is a valid
/// build: `BillingService` runs with billing disabled, the same stance
/// `BackendConfigLoader` takes for a build with no Supabase credentials.
public enum BillingConfigLoader {
    public static func fromBundle() -> BillingConfig? {
        guard
            let apiKey = string(for: "RevenueCatAppleApiKey"),
            let plusProductID = string(for: "RevenueCatPlusProductId"),
            let proProductID = string(for: "RevenueCatProProductId"),
            let plusEntitlementID = string(for: "RevenueCatPlusEntitlementId"),
            let proEntitlementID = string(for: "RevenueCatProEntitlementId")
        else {
            return nil
        }
        return BillingConfig(
            appleAPIKey: apiKey,
            plusProductID: plusProductID,
            proProductID: proProductID,
            plusEntitlementID: plusEntitlementID,
            proEntitlementID: proEntitlementID
        )
    }

    /// Treats an unfilled placeholder as absent, matching
    /// `BackendConfigLoader.string(for:)`.
    private static func string(for key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "replace-me" else { return nil }
        return trimmed
    }
}

/// How long `BillingService` waits on the App Store before it gives up on
/// a call. Only the two fetches that fill the paywall have a deadline:
/// a purchase or restore never does, because a timer must never report a
/// purchase as failed while StoreKit may still complete it.
public struct BillingTimeouts: Sendable, Equatable {
    /// The product lookup. Passing it counts as a failed lookup.
    public var products: Duration
    /// The trial eligibility check. Passing it means "no answer" (`[:]`).
    public var eligibility: Duration
    /// The storefront country read for diagnostics. Passing it records
    /// "unknown".
    public var storefront: Duration

    public init(
        products: Duration = .seconds(15),
        eligibility: Duration = .seconds(8),
        storefront: Duration = .seconds(2)
    ) {
        self.products = products
        self.eligibility = eligibility
        self.storefront = storefront
    }
}

// MARK: - Snapshot / outcome types

/// The plan and renewal state this identity currently holds. Mirrors
/// `SubscriptionSnapshot` (apps/mobile/src/features/billing/types.ts) minus
/// the fields RN carries only for analytics.
public struct SubscriptionSnapshot: Sendable, Equatable {
    public var planID: QuotaPolicy.PlanID
    public var periodType: PurchasesPeriodType?
    public var store: PurchasesStore?
    public var willRenew: Bool
    public var expirationDate: Date?

    public init(
        planID: QuotaPolicy.PlanID,
        periodType: PurchasesPeriodType?,
        store: PurchasesStore?,
        willRenew: Bool,
        expirationDate: Date?
    ) {
        self.planID = planID
        self.periodType = periodType
        self.store = store
        self.willRenew = willRenew
        self.expirationDate = expirationDate
    }

    /// Mirrors `buildDefaultSubscriptionSnapshot`: `planId: 'free'`, every
    /// other field null/false.
    public static let free = SubscriptionSnapshot(planID: .free, periodType: nil, store: nil, willRenew: false, expirationDate: nil)

    /// Mirrors `buildAccessSnapshot`'s `trialIsActive`: a Pro entitlement
    /// whose latest transaction is still in its trial period.
    public var trialIsActive: Bool {
        planID == .pro && periodType == .trial
    }
}

/// The outcome of `BillingService.purchase(planID:)`. Mirrors the branches
/// `purchaseSelectedPlan` (billingState.ts) and `PaywallScreen`'s purchase
/// handler distinguish.
public enum PurchaseOutcome: Sendable, Equatable {
    case success(SubscriptionSnapshot)
    /// The StoreKit sheet was dismissed without buying. Mirrors RN's
    /// `userCancelled` branch — silent, no error toast.
    case cancelled
    /// Mirrors `purchaseSelectedPlan`'s early-return message: "Create your
    /// account to link your subscription first." A guest must go through
    /// the auth sheet before this is retried.
    case requiresAccount
    case failed(String)
}

/// The outcome of `BillingService.restorePurchases()`. Mirrors
/// `restorePurchases` (billingState.ts) and `PaywallScreen`'s restore
/// handler.
public enum RestoreOutcome: Sendable, Equatable {
    case restored(SubscriptionSnapshot)
    /// Mirrors `PaywallScreen`'s "No purchases found" info toast: restore
    /// succeeded but landed back on the free plan.
    case noPurchasesFound
    /// Mirrors `restorePurchases`'s early-return message: "Sign in to
    /// restore purchases for your account."
    case requiresAccount
    case failed(String)
}

// MARK: - BillingService

/// Owns RevenueCat session state, the current entitlement snapshot, and the
/// Plus/Pro product catalog. Ports the RevenueCat half of
/// apps/mobile/src/state/billingState.ts
/// (`refreshSubscriptionState`/`purchaseSelectedPlan`/`restorePurchases`) —
/// the usage-ledger half (`getUsageSummary`) is `RevenueCatVoiceAccess`
/// (ReloraFeatures/Billing), which reads `subscriptionSnapshot` from here.
///
/// `@MainActor @Observable`, matching `IdentityController`: screens read
/// `subscriptionSnapshot`/`purchaseCatalog` directly, and the class needs to
/// be `Sendable` to satisfy call sites that hand it into
/// `IdentityController.onIdentityApplied`, which is `@Sendable`.
@MainActor
@Observable
public final class BillingService: Sendable {
    public private(set) var subscriptionSnapshot: SubscriptionSnapshot = .free
    /// Plus/Pro storefront metadata, keyed by plan. Empty when billing is
    /// unconfigured, the identity is not an account, or the last catalog
    /// fetch came back with nothing — see `isCatalogAvailable`.
    public private(set) var purchaseCatalog: [QuotaPolicy.PlanID: PurchasesProduct] = [:]
    /// Whether this Apple ID may still take each plan's introductory
    /// offer, fetched alongside the catalog. Read by `PaywallView` so a
    /// buyer who has already spent the free trial is never promised it
    /// again — App Review 3.1.2. Empty in every state
    /// `purchaseCatalog` is empty in.
    public private(set) var trialEligibility: [QuotaPolicy.PlanID: PurchasesIntroEligibility] = [:]
    /// False when the last `getProducts` call for an account identity came
    /// back empty or failed — mirrors `loadPurchaseCatalog`'s "unavailable
    /// catalog" state, which `PaywallScreen` shows as a notice instead of
    /// prices. Starts `true` so a screen rendered before the first refresh
    /// doesn't show that notice prematurely.
    public private(set) var isCatalogAvailable: Bool = true
    /// True once the first product lookup for the current account has
    /// answered, with products or with a failure. Until then the paywall
    /// says "Loading price…" rather than "Price unavailable". False again
    /// after every reset.
    public private(set) var catalogLoaded: Bool = false

    private let purchases: any PurchasesProviding
    private let config: BillingConfig?
    private let timeouts: BillingTimeouts
    private let storefrontCountry: @Sendable () async -> String?
    /// The account id currently logged in to RevenueCat, if any. Distinct
    /// from `IdentityController.identity` — this class deliberately does
    /// not hold a reference to that controller, only to the `Identity`
    /// values `handleIdentityChange` is handed.
    private var loggedInUserID: String?
    /// The last diagnostics write still in flight. Each new write waits for
    /// this one, so writes land in order; tests await it through
    /// `waitForDiagnostics()`.
    private var diagnosticsTask: Task<Void, Never>?

    /// - Parameters:
    ///   - timeouts: deadlines for the product and eligibility fetches.
    ///     Tests pass short ones.
    ///   - storefrontCountry: the App Store country code for diagnostics.
    ///     Tests pass a constant; StoreKit has no storefront there.
    public init(
        purchases: any PurchasesProviding,
        config: BillingConfig?,
        timeouts: BillingTimeouts = BillingTimeouts(),
        storefrontCountry: @escaping @Sendable () async -> String? = { await StoreKit.Storefront.current?.countryCode }
    ) {
        self.purchases = purchases
        self.config = config
        self.timeouts = timeouts
        self.storefrontCountry = storefrontCountry
    }

    /// Call from `IdentityController.onIdentityApplied`. Mirrors
    /// `refreshSubscriptionState(userId, identityKind)`: only `.account`
    /// gets a RevenueCat session and a live snapshot; every other identity
    /// (including a real anonymous session) resets to free and logs the
    /// SDK out, matching `!userId || identityKind !== 'account'` in RN.
    public func handleIdentityChange(_ identity: Identity) async {
        guard let config else {
            reset()
            return
        }
        guard case .account(let userID, _) = identity else {
            await resetAndLogOut()
            return
        }

        await purchases.configure(apiKey: config.appleAPIKey)
        // Best-effort, like `preparePurchasesSession`: a failed logIn still
        // lets the rest of the app run — the snapshot below falls back to
        // free on its own failure path below.
        try? await purchases.logIn(appUserID: userID)
        loggedInUserID = userID

        // All three start together, but each is published as it lands:
        // prices first, so a slow eligibility check (or a slow customer
        // record) never holds the paywall on "Loading price…".
        let productIDs = [config.plusProductID, config.proProductID]
        async let productsResult = Self.fetchProducts(purchases, productIDs: productIDs, timeout: timeouts.products)
        async let infoResult: PurchasesCustomerInfo? = try? purchases.customerInfo()
        async let eligibility = Self.fetchEligibility(purchases, productIDs: productIDs, timeout: timeouts.eligibility)

        publishCatalog(await productsResult, config: config)

        let info = await infoResult
        subscriptionSnapshot = info.map { Self.mapSnapshot($0, config: config) } ?? .free

        trialEligibility = Self.buildEligibility(await eligibility, catalog: purchaseCatalog)
    }

    /// Runs the product lookup again, for the paywall's "Try again". Then
    /// asks eligibility again for whatever came back, so a retried Pro card
    /// does not promise a trial this Apple ID has already used. No-op
    /// without an account session.
    public func refreshCatalog() async {
        guard let config, loggedInUserID != nil else { return }
        let productIDs = [config.plusProductID, config.proProductID]
        publishCatalog(
            await Self.fetchProducts(purchases, productIDs: productIDs, timeout: timeouts.products),
            config: config
        )
        guard !purchaseCatalog.isEmpty else { return }
        let eligibility = await Self.fetchEligibility(purchases, productIDs: productIDs, timeout: timeouts.eligibility)
        trialEligibility = Self.buildEligibility(eligibility, catalog: purchaseCatalog)
    }

    /// Mirrors `purchaseSelectedPlan`.
    public func purchase(planID: QuotaPolicy.PlanID) async -> PurchaseOutcome {
        guard let config else { return .failed("Billing is not configured.") }
        guard loggedInUserID != nil else { return .requiresAccount }
        let productID = productID(for: planID, config: config)
        do {
            switch try await purchases.purchase(productID: productID) {
            case .userCancelled:
                return .cancelled
            case .success(let info):
                let snapshot = Self.mapSnapshot(info, config: config)
                subscriptionSnapshot = snapshot
                return .success(snapshot)
            }
        } catch {
            let stage = Self.purchaseStage(for: error)
            recordDiagnostics([
                DiagnosticsKey.stage: stage,
                DiagnosticsKey.error: Self.describe(error),
                DiagnosticsKey.product: productID,
            ])
            return .failed(Self.failureMessage(stage: stage))
        }
    }

    /// Mirrors `restorePurchases` (billingState.ts).
    public func restorePurchases() async -> RestoreOutcome {
        guard let config else { return .failed("Billing is not configured.") }
        guard loggedInUserID != nil else { return .requiresAccount }
        do {
            let info = try await purchases.restorePurchases()
            let snapshot = Self.mapSnapshot(info, config: config)
            subscriptionSnapshot = snapshot
            return snapshot.planID == .free ? .noPurchasesFound : .restored(snapshot)
        } catch {
            recordDiagnostics([
                DiagnosticsKey.stage: DiagnosticsStage.restore,
                DiagnosticsKey.error: Self.describe(error),
            ])
            return .failed(Self.failureMessage(stage: DiagnosticsStage.restore))
        }
    }

    private func reset() {
        subscriptionSnapshot = .free
        purchaseCatalog = [:]
        trialEligibility = [:]
        isCatalogAvailable = true
        catalogLoaded = false
        loggedInUserID = nil
    }

    // MARK: - Catalog

    /// Publishes one product lookup's answer. A thrown lookup (or one
    /// past its deadline) empties the catalog like an empty answer does,
    /// and both are recorded.
    private func publishCatalog(_ result: Result<[PurchasesProduct], any Error>, config: BillingConfig) {
        switch result {
        case .success(let products):
            purchaseCatalog = Self.buildCatalog(products, config: config)
            isCatalogAvailable = !products.isEmpty
            recordDiagnostics([
                DiagnosticsKey.catalog: "\(products.count) products",
            ])
        case .failure(let error):
            purchaseCatalog = [:]
            trialEligibility = [:]
            isCatalogAvailable = false
            let description = Self.describe(error)
            recordDiagnostics([
                DiagnosticsKey.stage: DiagnosticsStage.catalog,
                DiagnosticsKey.error: description,
                DiagnosticsKey.catalog: description,
            ])
        }
        catalogLoaded = true
    }

    /// The product lookup as a `Result`, so a failure can be published
    /// next to the other two fetches instead of aborting them.
    private nonisolated static func fetchProducts(
        _ purchases: any PurchasesProviding,
        productIDs: [String],
        timeout: Duration
    ) async -> Result<[PurchasesProduct], any Error> {
        do {
            let products = try await withTimeout(timeout) {
                try await purchases.products(identifiers: productIDs)
            }
            return .success(products)
        } catch {
            return .failure(error)
        }
    }

    /// Eligibility, or no answer at all (`[:]`) once `timeout` passes.
    /// No answer reads as `.unknown` per product; see `buildEligibility`.
    private nonisolated static func fetchEligibility(
        _ purchases: any PurchasesProviding,
        productIDs: [String],
        timeout: Duration
    ) async -> [String: PurchasesIntroEligibility] {
        let answer = try? await withTimeout(timeout) {
            await purchases.introEligibility(productIDs: productIDs)
        }
        return answer ?? [:]
    }

    // MARK: - Diagnostics

    /// RevenueCat customer attribute keys. Values are plain strings: never
    /// receipts, tokens or anything personal.
    enum DiagnosticsKey {
        static let stage = "relora_billing_stage"
        static let error = "relora_billing_error"
        static let product = "relora_billing_product"
        static let catalog = "relora_billing_catalog"
        static let at = "relora_billing_at"
        static let build = "relora_build"
        static let storefront = "relora_storefront"
    }

    /// Where a billing call failed. Also the short reference the paywall
    /// shows, so a screenshot from a user or a reviewer names the stage.
    enum DiagnosticsStage {
        static let catalog = "catalog"
        static let lookup = "lookup"
        static let purchase = "purchase"
        static let restore = "restore"
    }

    /// Stamps `attributes` with the time, build and storefront and hands
    /// them to RevenueCat in a task of its own: the caller never waits,
    /// so recording can neither delay nor fail the purchase it describes.
    private func recordDiagnostics(_ attributes: [String: String]) {
        let purchases = self.purchases
        let storefrontCountry = self.storefrontCountry
        let storefrontTimeout = timeouts.storefront
        let at = ISO8601DateFormatter().string(from: Date())
        let previous = diagnosticsTask
        diagnosticsTask = Task {
            await previous?.value
            let storefront = try? await withTimeout(storefrontTimeout) { await storefrontCountry() }
            var stamped = attributes
            stamped[DiagnosticsKey.at] = at
            stamped[DiagnosticsKey.build] = Self.buildDescription
            stamped[DiagnosticsKey.storefront] = storefront ?? "unknown"
            await purchases.recordDiagnostics(stamped)
        }
    }

    /// Waits until every diagnostics write started so far has been handed
    /// to `PurchasesProviding`. For tests.
    func waitForDiagnostics() async {
        await diagnosticsTask?.value
    }

    /// `"<version> (<build>)"` from the app bundle, e.g. `"2.6.3 (17)"`.
    private nonisolated static var buildDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    /// A product that could not be found or looked up failed before
    /// StoreKit was ever asked to sell it; anything else failed in the
    /// purchase itself.
    private static func purchaseStage(for error: any Error) -> String {
        guard let providerError = error as? PurchasesProviderError else {
            return DiagnosticsStage.purchase
        }
        switch providerError {
        case .productNotFound, .productLookupFailed:
            return DiagnosticsStage.lookup
        case .underlying:
            return DiagnosticsStage.purchase
        }
    }

    /// The string recorded as `relora_billing_error`. The adapter's own
    /// errors already carry `"<domain>#<code>: <description>"`.
    private static func describe(_ error: any Error) -> String {
        if let providerError = error as? PurchasesProviderError {
            switch providerError {
            case .productNotFound(let productID):
                return "productNotFound: \(productID)"
            case .productLookupFailed(let description), .underlying(let description):
                return description
            }
        }
        if error is AsyncTimeoutError {
            return "timeout"
        }
        let nsError = error as NSError
        return "\(nsError.domain)#\(nsError.code): \(nsError.localizedDescription)"
    }

    /// What a failed purchase or restore tells the person: plain words,
    /// plus the stage as a reference. The raw error goes to diagnostics,
    /// not to the screen.
    static func failureMessage(stage: String) -> String {
        "We couldn't complete this with the App Store. Try again. (ref: \(stage))"
    }

    /// Mirrors `resetBillingState` plus `clearPurchasesAccount`'s
    /// best-effort logOut — only actually calls the SDK if a session was
    /// logged in, so a guest-to-guest transition never touches RevenueCat.
    private func resetAndLogOut() async {
        if loggedInUserID != nil {
            try? await purchases.logOut()
        }
        reset()
    }

    private func productID(for planID: QuotaPolicy.PlanID, config: BillingConfig) -> String {
        planID == .pro ? config.proProductID : config.plusProductID
    }

    /// Mirrors `mapCustomerInfoToSubscriptionSnapshot`: Pro wins over Plus
    /// when (in principle) both are somehow active at once.
    private static func mapSnapshot(_ info: PurchasesCustomerInfo, config: BillingConfig) -> SubscriptionSnapshot {
        if let pro = info.activeEntitlements[config.proEntitlementID] {
            return SubscriptionSnapshot(planID: .pro, periodType: pro.periodType, store: pro.store, willRenew: pro.willRenew, expirationDate: pro.expirationDate)
        }
        if let plus = info.activeEntitlements[config.plusEntitlementID] {
            return SubscriptionSnapshot(planID: .plus, periodType: plus.periodType, store: plus.store, willRenew: plus.willRenew, expirationDate: plus.expirationDate)
        }
        return .free
    }

    /// Re-keys the eligibility answers by plan, and answers `.noOffer` for
    /// a plan whose product carries no introductory offer at all —
    /// StoreKit is not asked to distinguish "you already used it" from
    /// "there is nothing to use", and the paywall needs that difference.
    /// A plan absent from the catalog is left out entirely.
    private static func buildEligibility(
        _ eligibility: [String: PurchasesIntroEligibility],
        catalog: [QuotaPolicy.PlanID: PurchasesProduct]
    ) -> [QuotaPolicy.PlanID: PurchasesIntroEligibility] {
        var result: [QuotaPolicy.PlanID: PurchasesIntroEligibility] = [:]
        for (planID, product) in catalog {
            guard product.introductoryOffer != nil else {
                result[planID] = .noOffer
                continue
            }
            result[planID] = eligibility[product.identifier] ?? .unknown
        }
        return result
    }

    private static func buildCatalog(_ products: [PurchasesProduct], config: BillingConfig) -> [QuotaPolicy.PlanID: PurchasesProduct] {
        var catalog: [QuotaPolicy.PlanID: PurchasesProduct] = [:]
        for product in products {
            if product.identifier == config.plusProductID {
                catalog[.plus] = product
            } else if product.identifier == config.proProductID {
                catalog[.pro] = product
            }
        }
        return catalog
    }
}
