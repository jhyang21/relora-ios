import Foundation
import RevenueCat
import StoreKit

/// Wraps RevenueCat's `Purchases` singleton to satisfy `PurchasesProviding`
/// for production use. Test code should conform a fake to
/// `PurchasesProviding` directly instead of using this type. Mirrors
/// `IdentitySupabaseBackend.swift`'s role for supabase-swift: this is
/// deliberately the only file in ReloraKit that imports `RevenueCat`.
///
/// ⚠️ UNVERIFIED — this package only builds on macOS, and this file was
/// written on Windows with no Swift toolchain to compile against. Every
/// `Purchases`/`CustomerInfo`/`EntitlementInfo`/`StoreProduct` member
/// referenced below is a best-effort name from documentation of the
/// purchases-ios 5.x API (`Package.swift` pins `from: "5.0.0"`), not
/// something this change has compiled or run. Treat this whole file as a
/// draft to correct against whatever version `Package.resolved` actually
/// pins on the first macOS build — most likely to have drifted, roughly
/// most to least likely:
///   - `Purchases.configure(withAPIKey:)`'s exact overload (this assumes
///     the simple form with no `appUserID:` — logIn happens separately,
///     matching RN's own configure-then-logIn split)
///   - `Purchases.shared.logIn(_:)` returning `(customerInfo: CustomerInfo,
///     created: Bool)` — assumed async throwing, tuple label `customerInfo`
///   - `Purchases.shared.logOut()` returning `CustomerInfo` (assumed async
///     throwing; discarded here since `PurchasesProviding.logOut()` has no
///     return value)
///   - `Purchases.shared.products(_:)` — assumed non-throwing async
///     returning `[StoreProduct]`
///   - `Purchases.shared.customerInfo()` — assumed async throwing
///   - `Purchases.shared.purchase(product:)` — assumed async throwing,
///     returning a result carrying `customerInfo` and `userCancelled`
///     (`PurchaseResultData`)
///   - `Purchases.shared.restorePurchases()` — assumed async throwing,
///     returning `CustomerInfo`
///   - `CustomerInfo.entitlements.active: [String: EntitlementInfo]` as the
///     already-active-only dictionary keyed by entitlement identifier
///   - `EntitlementInfo`'s exact member names: `.identifier`,
///     `.productIdentifier`, `.isActive`, `.willRenew`, `.periodType`,
///     `.expirationDate`, `.store`
///   - `PeriodType`'s case names (`.normal`, `.intro`, `.trial`,
///     `.prepaid`) and whether a fifth unknown case exists
///   - `Store`'s case names (assumed `.appStore`, `.macAppStore`,
///     `.playStore`, `.amazon`, plus others folded into `.other` below)
///   - `StoreProduct.productIdentifier` / `.localizedPriceString`
///
/// The 2.6.1 paywall work added a second unverified batch, same standing:
///   - `StoreProduct.subscriptionPeriod: SubscriptionPeriod?`, and that
///     type's `.value: Int` / `.unit: SubscriptionPeriod.Unit` with cases
///     `.day`, `.week`, `.month`, `.year`
///   - `StoreProduct.introductoryDiscount: StoreProductDiscount?`, and
///     that type's `.subscriptionPeriod`, `.localizedPriceString`, and
///     `.paymentMode: StoreProductDiscount.PaymentMode` with cases
///     `.payAsYouGo`, `.payUpFront`, `.freeTrial`
///   - `Purchases.shared.checkTrialOrIntroDiscountEligibility(
///     productIdentifiers:)` — assumed non-throwing async returning
///     `[String: IntroEligibility]`
///   - `IntroEligibility.status: IntroEligibilityStatus` with cases
///     `.unknown`, `.ineligible`, `.eligible`, `.noIntroOfferExists`
///
/// 2.6.3 (App Review 2.1(b)) moved the product lookup to StoreKit 2 so its
/// error survives, and added diagnostics. Unverified the same way:
///   - `StoreKit.Product.products(for:)` (async throws)
///   - `RevenueCat.StoreProduct(sk2Product:)`
///   - `Purchases.shared.attribution.setAttributes(_:)`
///   - `Purchases.shared.syncAttributesAndOfferingsIfNeeded()` (async throws)
///   - `RevenueCat.ErrorCode.purchaseCancelledError`, caught from a
///     thrown error by `as`
///
/// StoreKit and RevenueCat both declare product types, so RevenueCat's
/// types are qualified with their module below.
public final class RevenueCatPurchasesAdapter: PurchasesProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var isConfigured = false

    public init() {}

    /// Configures under the lock and marks it done only afterwards, so a
    /// second caller can never see `isConfigured` before
    /// `Purchases.shared` exists. The SDK call is synchronous; nothing is
    /// awaited while the lock is held.
    public func configure(apiKey: String) async {
        lock.withLock {
            guard !isConfigured else { return }
            Purchases.configure(withAPIKey: apiKey)
            isConfigured = true
        }
    }

    @discardableResult
    public func logIn(appUserID: String) async throws -> PurchasesCustomerInfo {
        do {
            let result = try await Purchases.shared.logIn(appUserID)
            return Self.map(result.customerInfo)
        } catch {
            throw PurchasesProviderError.underlying(Self.describe(error))
        }
    }

    public func logOut() async throws {
        do {
            _ = try await Purchases.shared.logOut()
        } catch {
            throw PurchasesProviderError.underlying(Self.describe(error))
        }
    }

    /// Asks StoreKit 2 directly rather than `Purchases.shared.products(_:)`,
    /// which swallows the lookup error and returns `[]`.
    public func products(identifiers: [String]) async throws -> [PurchasesProduct] {
        guard !identifiers.isEmpty else { return [] }
        return try await Self.storeProducts(identifiers).map { Self.map($0) }
    }

    public func introEligibility(productIDs: [String]) async -> [String: PurchasesIntroEligibility] {
        guard !productIDs.isEmpty else { return [:] }
        let results = await Purchases.shared.checkTrialOrIntroDiscountEligibility(productIdentifiers: productIDs)
        return results.mapValues { Self.map($0.status) }
    }

    public func customerInfo() async throws -> PurchasesCustomerInfo {
        do {
            return Self.map(try await Purchases.shared.customerInfo())
        } catch {
            throw PurchasesProviderError.underlying(Self.describe(error))
        }
    }

    public func purchase(productID: String) async throws -> PurchasesPurchaseResult {
        let products = try await Self.storeProducts([productID])
        guard let product = products.first(where: { $0.productIdentifier == productID }) else {
            throw PurchasesProviderError.productNotFound(productID)
        }
        do {
            let result = try await Purchases.shared.purchase(product: product)
            if result.userCancelled {
                return .userCancelled
            }
            return .success(Self.map(result.customerInfo))
        } catch let error as RevenueCat.ErrorCode where error == .purchaseCancelledError {
            // The async `purchase(product:)` can report a dismissed sheet
            // by throwing this code instead of setting `userCancelled`.
            // It is not a failure and must not show as one.
            return .userCancelled
        } catch {
            throw PurchasesProviderError.underlying(Self.describe(error))
        }
    }

    public func restorePurchases() async throws -> PurchasesCustomerInfo {
        do {
            return Self.map(try await Purchases.shared.restorePurchases())
        } catch {
            throw PurchasesProviderError.underlying(Self.describe(error))
        }
    }

    /// Attributes first, then a sync so they reach the dashboard now
    /// rather than on the next customer-info fetch. Both halves are
    /// best-effort. Skipped before `configure`, when `Purchases.shared`
    /// does not exist yet.
    public func recordDiagnostics(_ attributes: [String: String]) async {
        guard lock.withLock({ isConfigured }) else { return }
        Purchases.shared.attribution.setAttributes(attributes)
        _ = try? await Purchases.shared.syncAttributesAndOfferingsIfNeeded()
    }

    // MARK: - Product lookup

    /// Looks the ids up in StoreKit 2 and wraps each result for
    /// RevenueCat. Any StoreKit error becomes `.productLookupFailed` with
    /// its domain and code kept.
    private static func storeProducts(_ identifiers: [String]) async throws -> [RevenueCat.StoreProduct] {
        do {
            let products = try await StoreKit.Product.products(for: identifiers)
            return products.map { RevenueCat.StoreProduct(sk2Product: $0) }
        } catch {
            throw PurchasesProviderError.productLookupFailed(describe(error))
        }
    }

    /// `"<domain>#<code>: <description>"`, the form every wrapped error
    /// string takes (see `PurchasesProviderError`).
    private static func describe(_ error: any Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain)#\(nsError.code): \(nsError.localizedDescription)"
    }

    private static func map(_ product: RevenueCat.StoreProduct) -> PurchasesProduct {
        PurchasesProduct(
            identifier: product.productIdentifier,
            localizedPriceString: product.localizedPriceString,
            subscriptionPeriod: map(product.subscriptionPeriod),
            introductoryOffer: map(product.introductoryDiscount)
        )
    }

    private static func map(_ info: RevenueCat.CustomerInfo) -> PurchasesCustomerInfo {
        var active: [String: PurchasesEntitlementInfo] = [:]
        for (key, entitlement) in info.entitlements.active {
            active[key] = PurchasesEntitlementInfo(
                identifier: entitlement.identifier,
                productIdentifier: entitlement.productIdentifier,
                isActive: entitlement.isActive,
                willRenew: entitlement.willRenew,
                periodType: map(entitlement.periodType),
                expirationDate: entitlement.expirationDate,
                store: map(entitlement.store)
            )
        }
        return PurchasesCustomerInfo(activeEntitlements: active)
    }

    private static func map(_ periodType: RevenueCat.PeriodType) -> PurchasesPeriodType {
        switch periodType {
        case .normal: return .normal
        case .intro: return .intro
        case .trial: return .trial
        case .prepaid: return .prepaid
        @unknown default: return .unknown
        }
    }

    private static func map(_ period: RevenueCat.SubscriptionPeriod?) -> PurchasesSubscriptionPeriod? {
        guard let period else { return nil }
        let unit: PurchasesSubscriptionPeriod.Unit
        switch period.unit {
        case .day: unit = .day
        case .week: unit = .week
        case .month: unit = .month
        case .year: unit = .year
        @unknown default: return nil
        }
        return PurchasesSubscriptionPeriod(unit: unit, value: period.value)
    }

    /// An offer whose period this seam cannot name (a future unit) is
    /// dropped rather than guessed at: no offer at all makes the paywall
    /// quote the plain price, which is always safe to say.
    private static func map(_ discount: RevenueCat.StoreProductDiscount?) -> PurchasesIntroOffer? {
        guard let discount, let period = map(discount.subscriptionPeriod) else { return nil }
        let paymentMode: PurchasesIntroOffer.PaymentMode
        switch discount.paymentMode {
        case .freeTrial: paymentMode = .freeTrial
        case .payAsYouGo: paymentMode = .payAsYouGo
        case .payUpFront: paymentMode = .payUpFront
        @unknown default: return nil
        }
        return PurchasesIntroOffer(
            period: period,
            paymentMode: paymentMode,
            localizedPriceString: discount.localizedPriceString
        )
    }

    private static func map(_ status: RevenueCat.IntroEligibilityStatus) -> PurchasesIntroEligibility {
        switch status {
        case .eligible: return .eligible
        case .ineligible: return .ineligible
        case .noIntroOfferExists: return .noOffer
        case .unknown: return .unknown
        @unknown default: return .unknown
        }
    }

    private static func map(_ store: RevenueCat.Store) -> PurchasesStore {
        switch store {
        case .appStore, .macAppStore:
            return .apple
        case .playStore, .amazon:
            return .google
        default:
            return .other
        }
    }
}
