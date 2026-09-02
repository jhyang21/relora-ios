import Foundation
import RevenueCat

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
public final class RevenueCatPurchasesAdapter: PurchasesProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var isConfigured = false

    public init() {}

    public func configure(apiKey: String) async {
        let alreadyConfigured: Bool = lock.withLock {
            defer { isConfigured = true }
            return isConfigured
        }
        guard !alreadyConfigured else { return }
        Purchases.configure(withAPIKey: apiKey)
    }

    @discardableResult
    public func logIn(appUserID: String) async throws -> PurchasesCustomerInfo {
        do {
            let result = try await Purchases.shared.logIn(appUserID)
            return Self.map(result.customerInfo)
        } catch {
            throw PurchasesProviderError.underlying(String(describing: error))
        }
    }

    public func logOut() async throws {
        do {
            _ = try await Purchases.shared.logOut()
        } catch {
            throw PurchasesProviderError.underlying(String(describing: error))
        }
    }

    public func products(identifiers: [String]) async -> [PurchasesProduct] {
        guard !identifiers.isEmpty else { return [] }
        let products = await Purchases.shared.products(identifiers)
        return products.map {
            PurchasesProduct(identifier: $0.productIdentifier, localizedPriceString: $0.localizedPriceString)
        }
    }

    public func customerInfo() async throws -> PurchasesCustomerInfo {
        do {
            return Self.map(try await Purchases.shared.customerInfo())
        } catch {
            throw PurchasesProviderError.underlying(String(describing: error))
        }
    }

    public func purchase(productID: String) async throws -> PurchasesPurchaseResult {
        let products = await Purchases.shared.products([productID])
        guard let product = products.first(where: { $0.productIdentifier == productID }) else {
            throw PurchasesProviderError.productNotFound(productID)
        }
        do {
            let result = try await Purchases.shared.purchase(product: product)
            if result.userCancelled {
                return .userCancelled
            }
            return .success(Self.map(result.customerInfo))
        } catch {
            throw PurchasesProviderError.underlying(String(describing: error))
        }
    }

    public func restorePurchases() async throws -> PurchasesCustomerInfo {
        do {
            return Self.map(try await Purchases.shared.restorePurchases())
        } catch {
            throw PurchasesProviderError.underlying(String(describing: error))
        }
    }

    private static func map(_ info: CustomerInfo) -> PurchasesCustomerInfo {
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

    private static func map(_ periodType: PeriodType) -> PurchasesPeriodType {
        switch periodType {
        case .normal: return .normal
        case .intro: return .intro
        case .trial: return .trial
        case .prepaid: return .prepaid
        @unknown default: return .unknown
        }
    }

    private static func map(_ store: Store) -> PurchasesStore {
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
