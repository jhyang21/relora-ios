import Foundation
import Observation
import ReloraCore

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
    /// `AuthGateView` before this is retried.
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
    /// False when the last `getProducts` call for an account identity came
    /// back empty — mirrors `loadPurchaseCatalog`'s "unavailable catalog"
    /// state, which `PaywallScreen` shows as a notice instead of prices.
    /// Starts `true` so a screen rendered before the first refresh doesn't
    /// show that notice prematurely.
    public private(set) var isCatalogAvailable: Bool = true

    private let purchases: any PurchasesProviding
    private let config: BillingConfig?
    /// The account id currently logged in to RevenueCat, if any. Distinct
    /// from `IdentityController.identity` — this class deliberately does
    /// not hold a reference to that controller, only to the `Identity`
    /// values `handleIdentityChange` is handed.
    private var loggedInUserID: String?

    public init(purchases: any PurchasesProviding, config: BillingConfig?) {
        self.purchases = purchases
        self.config = config
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

        async let infoResult: PurchasesCustomerInfo? = try? purchases.customerInfo()
        async let products = purchases.products(identifiers: [config.plusProductID, config.proProductID])

        let info = await infoResult
        let fetchedProducts = await products

        subscriptionSnapshot = info.map { Self.mapSnapshot($0, config: config) } ?? .free
        purchaseCatalog = Self.buildCatalog(fetchedProducts, config: config)
        isCatalogAvailable = !fetchedProducts.isEmpty
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
            return .failed(String(describing: error))
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
            return .failed(String(describing: error))
        }
    }

    private func reset() {
        subscriptionSnapshot = .free
        purchaseCatalog = [:]
        isCatalogAvailable = true
        loggedInUserID = nil
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
