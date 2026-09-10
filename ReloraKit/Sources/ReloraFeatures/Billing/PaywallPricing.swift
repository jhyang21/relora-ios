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
/// and StoreKit's own eligibility answer; `fallbackPrice` is the static
/// price a card shows before the catalog loads, or when it fails to.
///
/// Pure and free of SwiftUI on purpose: this is the part with rules in it,
/// and `PaywallPricingTests` asserts every branch without a screen.
enum PaywallPricing {
    struct Lines: Equatable {
        var price: String
        var renewal: String
        var cta: String
    }

    /// - Parameters:
    ///   - product: the live catalog entry, or `nil` before the catalog
    ///     loads. `nil` falls back to `fallbackPrice` and a monthly period,
    ///     which is what both plans actually bill at.
    ///   - eligibility: StoreKit's answer for this product. `nil` and
    ///     `.unknown` both count as eligible — the check not having landed
    ///     is not evidence the buyer has used the trial, and hiding an
    ///     offer somebody can have is its own kind of wrong.
    static func lines(
        planID: QuotaPolicy.PlanID,
        product: PurchasesProduct?,
        eligibility: PurchasesIntroEligibility?,
        fallbackPrice: String
    ) -> Lines {
        let price = displayPrice(product: product, fallbackPrice: fallbackPrice)
        let period = periodText(product?.subscriptionPeriod)
        let perPeriod = "\(price)/\(period)"

        guard planID == .pro, let trial = eligibleFreeTrial(product: product, eligibility: eligibility) else {
            return Lines(
                price: perPeriod,
                renewal: "Renews automatically at \(perPeriod) until canceled.",
                // `.free` is not a purchasable card — `paywallPlans` lists
                // Plus and Pro only — so it shares Plus's wording rather
                // than earning a branch of its own.
                cta: planID == .pro ? "Subscribe to Pro" : "Choose Plus"
            )
        }

        return Lines(
            price: "\(trial.phrase) free, then \(perPeriod)",
            renewal: "Renews automatically at \(perPeriod) after the trial unless canceled.",
            cta: "Start \(trial.count)-\(trial.unit) free trial"
        )
    }

    // MARK: - Pieces

    /// The storefront's own price string, or the fallback when there is no
    /// product yet or it came back blank.
    private static func displayPrice(product: PurchasesProduct?, fallbackPrice: String) -> String {
        guard let product else { return fallbackPrice }
        let trimmed = product.localizedPriceString.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackPrice : trimmed
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
