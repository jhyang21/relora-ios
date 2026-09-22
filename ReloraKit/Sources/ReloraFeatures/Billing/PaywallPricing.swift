import Foundation
import ReloraCore
import ReloraServices

/// Writes the three lines a plan card says about money: the price, the
/// renewal sentence, and the button.
///
/// App Review 3.1.2 wants the price, the billing period and the renewal
/// terms shown on the purchase screen itself, and wants them true: a
/// storefront in another currency, a price change in App Store Connect, or
/// an Apple ID that has already spent the free trial each make a hardcoded
/// line a lie. So the lines are computed from the live `PurchasesProduct`
/// and StoreKit's own eligibility answer. With no live price there is no
/// price to quote at all: the card says why (`MissingPrice`) and
/// `hasLivePrice` is false, which is what disables its button.
///
/// Pure and free of SwiftUI on purpose: this is the part with rules in it,
/// and `PaywallPricingTests` asserts every branch without a screen.
enum PaywallPricing {
    struct Lines: Equatable {
        var price: String
        var renewal: String
        var cta: String
        /// False when `price` is a placeholder rather than the storefront's
        /// price. A card with no live price must not sell anything.
        var hasLivePrice: Bool = true
    }

    /// Why a card has no live price to quote.
    enum MissingPrice: Equatable {
        /// The first product lookup has not answered yet.
        case loading
        /// The lookup answered without this product, or failed.
        case unavailable
        /// A guest: the catalog loads only for an account, and choosing a
        /// plan opens sign-in first.
        case afterSignIn

        var text: String {
            switch self {
            case .loading: return "Loading price…"
            case .unavailable: return "Price unavailable"
            case .afterSignIn: return "Price shown after you sign in"
            }
        }
    }

    /// - Parameters:
    ///   - product: the live catalog entry, or `nil` when there is none.
    ///     `nil`, or a blank storefront price, gives placeholder lines
    ///     worded by `missingPrice`.
    ///   - eligibility: StoreKit's answer for this product. `nil` and
    ///     `.unknown` both count as eligible — the check not having landed
    ///     is not evidence the buyer has used the trial, and hiding an
    ///     offer somebody can have is its own kind of wrong.
    static func lines(
        planID: QuotaPolicy.PlanID,
        product: PurchasesProduct?,
        eligibility: PurchasesIntroEligibility?,
        missingPrice: MissingPrice = .unavailable
    ) -> Lines {
        guard let product, let price = livePrice(product) else {
            return placeholderLines(planID: planID, missingPrice: missingPrice)
        }
        let period = periodText(product.subscriptionPeriod)
        let perPeriod = "\(price)/\(period)"

        guard planID == .pro, let trial = eligibleFreeTrial(product: product, eligibility: eligibility) else {
            return Lines(
                price: perPeriod,
                renewal: "Renews automatically at \(perPeriod) until canceled.",
                cta: plainCTA(planID)
            )
        }

        return Lines(
            price: "\(trial.phrase) free, then \(perPeriod)",
            renewal: "Renews automatically at \(perPeriod) after the trial unless canceled.",
            cta: "Start \(trial.count)-\(trial.unit) free trial"
        )
    }

    // MARK: - Pieces

    /// Lines for a card with no live price. No amount is quoted: a static
    /// one is wrong in every other storefront. Monthly is what both plans
    /// bill at, so the renewal sentence can still say that much.
    private static func placeholderLines(planID: QuotaPolicy.PlanID, missingPrice: MissingPrice) -> Lines {
        Lines(
            price: missingPrice.text,
            renewal: "Renews automatically every month until canceled.",
            cta: plainCTA(planID),
            hasLivePrice: false
        )
    }

    /// `.free` is not a purchasable card — `paywallPlans` lists Plus and
    /// Pro only — so it shares Plus's wording rather than earning a branch
    /// of its own.
    private static func plainCTA(_ planID: QuotaPolicy.PlanID) -> String {
        planID == .pro ? "Subscribe to Pro" : "Choose Plus"
    }

    /// The storefront's own price string, trimmed, or `nil` when it came
    /// back blank.
    private static func livePrice(_ product: PurchasesProduct) -> String? {
        let trimmed = product.localizedPriceString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What follows the slash in "$19.99/month". A period of more than one
    /// unit reads as a count ("3 months"), which is why this is not a
    /// straight unit-to-word table.
    private static func periodText(_ period: PurchasesSubscriptionPeriod?) -> String {
        guard let period else { return "month" }
        let unit = unitWord(period.unit)
        return period.value == 1 ? unit : "\(period.value) \(unit)s"
    }

    private static func unitWord(_ unit: PurchasesSubscriptionPeriod.Unit) -> String {
        switch unit {
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        case .year: return "year"
        }
    }

    /// The free trial this buyer may actually take, or `nil` — no offer, a
    /// paid introductory offer, or an Apple ID StoreKit says is
    /// ineligible.
    ///
    /// Weeks are converted to days: "7 days free" is what the offer means
    /// to a reader, and "1 week free" beside a "Start 7-day free trial"
    /// button would look like two different offers.
    private static func eligibleFreeTrial(
        product: PurchasesProduct?,
        eligibility: PurchasesIntroEligibility?
    ) -> (count: Int, unit: String, phrase: String)? {
        guard let offer = product?.introductoryOffer, offer.paymentMode == .freeTrial else { return nil }
        switch eligibility {
        case .eligible, .unknown, .none:
            break
        case .ineligible, .noOffer:
            return nil
        }

        let count: Int
        let unit: String
        switch offer.period.unit {
        case .week:
            count = offer.period.value * 7
            unit = "day"
        case .day, .month, .year:
            count = offer.period.value
            unit = unitWord(offer.period.unit)
        }
        let phrase = count == 1 ? "\(count) \(unit)" : "\(count) \(unit)s"
        return (count, unit, phrase)
    }
}
