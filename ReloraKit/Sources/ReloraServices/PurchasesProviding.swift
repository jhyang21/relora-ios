import Foundation

/// The RevenueCat surface `BillingService` needs, behind a protocol so its
/// tests use a fake instead of the real SDK. This file and
/// `RevenueCatPurchasesAdapter` below are deliberately the only place in
/// ReloraKit that name the `RevenueCat` module — the same boundary
/// `NotificationCenterProviding.swift` draws around `UserNotifications`.
///
/// No RevenueCat type (`CustomerInfo`, `EntitlementInfo`, `StoreProduct`, …)
/// crosses this seam; everything is remapped to a plain value type below so
/// `BillingService` and its tests never import RevenueCat either.
public protocol PurchasesProviding: Sendable {
    /// Configures the SDK with the App Store API key. Safe to call more
    /// than once — the adapter configures the underlying singleton only on
    /// the first call and no-ops after, mirroring `preparePurchasesSession`
    /// (apps/mobile/src/features/billing/purchases.ts)'s "configure once"
    /// half. Unlike RN, this native build never sees the API key change at
    /// runtime — it is compiled in via `Secrets.xcconfig` → `Info.plist` —
    /// so the "configure with a different key" error RN guards against has
    /// no reachable equivalent here; see the deviation note in the M9
    /// report.
    func configure(apiKey: String) async

    /// Logs in the SDK's current user, aliasing local purchase history to
    /// `appUserID`. Mirrors `Purchases.shared.logIn(appUserID)` — the
    /// `logIn` half of `preparePurchasesSession`.
    @discardableResult
    func logIn(appUserID: String) async throws -> PurchasesCustomerInfo

    /// Reverts the SDK to an anonymous app-user id. Mirrors
    /// `clearPurchasesAccount`'s best-effort `Purchases.shared.logOut()`.
    func logOut() async throws

    /// Fetches product metadata for exactly these ids — never an Offering.
    /// Mirrors `loadPurchaseCatalog`'s direct `getProducts([...])` call.
    /// RevenueCat's own `products(_:)` does not throw on a lookup failure;
    /// an id that doesn't resolve to a StoreKit product is simply absent
    /// from the result, which is why this returns a plain array rather
    /// than throwing.
    func products(identifiers: [String]) async -> [PurchasesProduct]

    /// The current customer's entitlement state. Mirrors
    /// `Purchases.shared.getCustomerInfo()`, called by
    /// `refreshSubscriptionSnapshot`.
    func customerInfo() async throws -> PurchasesCustomerInfo

    /// Buys one product by id. The adapter resolves `productID` to a
    /// StoreKit product internally (mirroring `purchasePlan`'s own
    /// `getProducts([productId])` lookup before purchasing) so no
    /// RevenueCat product type ever needs to leave this file.
    func purchase(productID: String) async throws -> PurchasesPurchaseResult

    /// Mirrors `Purchases.shared.restorePurchases()`, called by
    /// `restorePurchaseSnapshot`.
    func restorePurchases() async throws -> PurchasesCustomerInfo
}

// MARK: - Value types

/// One product's storefront metadata, remapped from RevenueCat's
/// `StoreProduct`. Mirrors the fields `PaywallScreen.tsx` reads off a
/// `PurchaseCatalog` entry (`priceString`, used verbatim; `paywallContent.ts`
/// supplies the marketing title/bullets separately, so no title beyond the
/// storefront's own is carried here).
public struct PurchasesProduct: Sendable, Equatable {
    public var identifier: String
    public var localizedPriceString: String

    public init(identifier: String, localizedPriceString: String) {
        self.identifier = identifier
        self.localizedPriceString = localizedPriceString
    }
}

/// Mirrors RevenueCat's `PeriodType`, minus `PurchasesCustomerInfo`'s own
/// import: which billing period the entitlement's *latest* transaction
/// belongs to. `mapCustomerInfoToSubscriptionSnapshot` reads this to decide
/// `periodType` on the snapshot (`NORMAL`/`INTRO`/`TRIAL`/`PREPAID`, else
/// `nil`).
public enum PurchasesPeriodType: Sendable, Equatable {
    case normal
    case intro
    case trial
    case prepaid
    case unknown
}

/// Mirrors RevenueCat's `Store` enum, collapsed to the three buckets
/// `mapCustomerInfoToSubscriptionSnapshot` cares about (`apple` for any
/// App Store family member, `google` for Play/Amazon, `other` for
/// everything else — RC billing, Stripe, promotional, web).
public enum PurchasesStore: Sendable, Equatable {
    case apple
    case google
    case other
}

/// One entitlement's state, remapped from RevenueCat's `EntitlementInfo`.
/// Only active entitlements are meaningful to `BillingService` — see
/// `PurchasesCustomerInfo.activeEntitlements` below — but `isActive` is
/// still carried so a caller can assert on it directly.
public struct PurchasesEntitlementInfo: Sendable, Equatable {
    public var identifier: String
    public var productIdentifier: String
    public var isActive: Bool
    public var willRenew: Bool
    public var periodType: PurchasesPeriodType
    public var expirationDate: Date?
    public var store: PurchasesStore

    public init(
        identifier: String,
        productIdentifier: String,
        isActive: Bool,
        willRenew: Bool,
        periodType: PurchasesPeriodType,
        expirationDate: Date?,
        store: PurchasesStore
    ) {
        self.identifier = identifier
        self.productIdentifier = productIdentifier
        self.isActive = isActive
        self.willRenew = willRenew
        self.periodType = periodType
        self.expirationDate = expirationDate
        self.store = store
    }
}

/// A customer's full entitlement state, remapped from RevenueCat's
/// `CustomerInfo`. Mirrors the fields `mapCustomerInfoToSubscriptionSnapshot`
/// reads off `customerInfo.entitlements.active`.
public struct PurchasesCustomerInfo: Sendable, Equatable {
    /// Keyed by entitlement identifier ("Relora Plus" / "Relora Pro" — the
    /// RevenueCat *lookup key*, which carries spaces and capitals; see
    /// `REVENUECAT_PLUS_ENTITLEMENT_ID` / `REVENUECAT_PRO_ENTITLEMENT_ID`
    /// in `Secrets.example.xcconfig`). Mirrors
    /// `customerInfo.entitlements.active` — RevenueCat's own dictionary
    /// already excludes anything not currently active, so this adapter
    /// does not filter again.
    public var activeEntitlements: [String: PurchasesEntitlementInfo]

    public init(activeEntitlements: [String: PurchasesEntitlementInfo]) {
        self.activeEntitlements = activeEntitlements
    }

    public static let empty = PurchasesCustomerInfo(activeEntitlements: [:])
}

/// Mirrors the two outcomes `purchasePlan` distinguishes: a completed
/// purchase, or the user dismissing the StoreKit sheet
/// (RevenueCat's `userCancelled` result flag) — everything else surfaces as
/// a thrown error instead.
public enum PurchasesPurchaseResult: Sendable, Equatable {
    case success(PurchasesCustomerInfo)
    case userCancelled
}

/// Errors this seam raises itself, distinct from whatever the SDK throws
/// (which the adapter wraps as `.underlying`).
public enum PurchasesProviderError: Error, Sendable, Equatable {
    /// `purchase(productID:)` could not resolve `productID` to a StoreKit
    /// product — mirrors `loadPurchaseCatalog`'s "unavailable catalog"
    /// branch when `getProducts` comes back empty.
    case productNotFound(String)
    case underlying(String)
}
