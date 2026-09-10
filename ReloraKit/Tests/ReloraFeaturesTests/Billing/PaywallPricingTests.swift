import Foundation
import Testing
import ReloraCore
@testable import ReloraFeatures
@testable import ReloraServices

/// Pins every line the paywall says about money.
///
/// These strings are the ones App Review reads on the purchase screen, so
/// they are asserted whole rather than by `contains`: a renewal sentence
/// that loses its price, or a trial promise that survives an ineligible
/// Apple ID, is a rejection either way.
struct PaywallPricingTests {
    private static func product(
        id: String,
        price: String,
        period: PurchasesSubscriptionPeriod? = PurchasesSubscriptionPeriod(unit: .month, value: 1),
        offer: PurchasesIntroOffer? = nil
    ) -> PurchasesProduct {
        PurchasesProduct(
            identifier: id,
            localizedPriceString: price,
            subscriptionPeriod: period,
            introductoryOffer: offer
        )
    }

    private static let sevenDayTrial = PurchasesIntroOffer(
        period: PurchasesSubscriptionPeriod(unit: .week, value: 1),
        paymentMode: .freeTrial,
        localizedPriceString: "$0.00"
    )

    // MARK: - Plus

    @Test func plusQuotesThePriceAndItsPeriodFromTheCatalog() {
        let lines = PaywallPricing.lines(
            planID: .plus,
            product: Self.product(id: "plus", price: "$4.99"),
            eligibility: .noOffer,
            fallbackPrice: "$4.99"
        )

        #expect(lines.price == "$4.99/month")
        #expect(lines.renewal == "Renews automatically at $4.99/month until canceled.")
        #expect(lines.cta == "Choose Plus")
    }

    /// The storefront string wins over the fallback, and arrives trimmed.
    @Test func theLivePriceReplacesTheFallback() {
        let lines = PaywallPricing.lines(
            planID: .plus,
            product: Self.product(id: "plus", price: "  £5.99  "),
            eligibility: .noOffer,
            fallbackPrice: "$4.99"
        )

        #expect(lines.price == "£5.99/month")
    }

    // MARK: - Pro with a trial

    @Test func anEligibleProBuyerIsOfferedTheSevenDayTrial() {
        let lines = PaywallPricing.lines(
            planID: .pro,
            product: Self.product(id: "pro", price: "$19.99", offer: Self.sevenDayTrial),
            eligibility: .eligible,
            fallbackPrice: "$19.99"
        )

        #expect(lines.price == "7 days free, then $19.99/month")
        #expect(lines.cta == "Start 7-day free trial")
        #expect(lines.renewal == "Renews automatically at $19.99/month after the trial unless canceled.")
    }

    /// `.unknown` is StoreKit failing to answer, not a "no". Withholding an
    /// offer somebody can have is its own kind of wrong, so it reads as
    /// eligible — the same answer a missing check gets.
    @Test func anUnknownAnswerIsTreatedAsEligible() {
        let product = Self.product(id: "pro", price: "$19.99", offer: Self.sevenDayTrial)
        let unknown = PaywallPricing.lines(planID: .pro, product: product, eligibility: .unknown, fallbackPrice: "$19.99")
        let missing = PaywallPricing.lines(planID: .pro, product: product, eligibility: nil, fallbackPrice: "$19.99")

        #expect(unknown.cta == "Start 7-day free trial")
        #expect(unknown == missing)
    }

    /// A one-day trial says "1 day", not "1 days".
    @Test func aSingleDayTrialIsSingular() {
        let offer = PurchasesIntroOffer(
            period: PurchasesSubscriptionPeriod(unit: .day, value: 1),
            paymentMode: .freeTrial,
            localizedPriceString: "$0.00"
        )
        let lines = PaywallPricing.lines(
            planID: .pro,
            product: Self.product(id: "pro", price: "$19.99", offer: offer),
            eligibility: .eligible,
            fallbackPrice: "$19.99"
        )

        #expect(lines.price == "1 day free, then $19.99/month")
        #expect(lines.cta == "Start 1-day free trial")
    }

    // MARK: - Pro without a trial

    /// The whole reason eligibility is fetched: this buyer has already used
    /// the trial, and the card must not promise it again.
    @Test func anIneligibleProBuyerSeesThePlainPrice() {
        let lines = PaywallPricing.lines(
            planID: .pro,
            product: Self.product(id: "pro", price: "$19.99", offer: Self.sevenDayTrial),
            eligibility: .ineligible,
            fallbackPrice: "$19.99"
        )

        #expect(lines.price == "$19.99/month")
        #expect(lines.cta == "Subscribe to Pro")
        #expect(lines.renewal == "Renews automatically at $19.99/month until canceled.")
    }

    @Test func aProProductWithNoOfferNeverShowsTrialCopy() {
        let lines = PaywallPricing.lines(
            planID: .pro,
            product: Self.product(id: "pro", price: "$19.99"),
            eligibility: .noOffer,
            fallbackPrice: "$19.99"
        )

        #expect(lines.price == "$19.99/month")
        #expect(lines.cta == "Subscribe to Pro")
    }

    /// A paid introductory offer is not a free trial, whatever StoreKit
    /// says about eligibility.
    @Test func aPaidIntroOfferDoesNotBecomeAFreeTrial() {
        let payUpFront = PurchasesIntroOffer(
            period: PurchasesSubscriptionPeriod(unit: .month, value: 3),
            paymentMode: .payUpFront,
            localizedPriceString: "$29.99"
        )
        let lines = PaywallPricing.lines(
            planID: .pro,
            product: Self.product(id: "pro", price: "$19.99", offer: payUpFront),
            eligibility: .eligible,
            fallbackPrice: "$19.99"
        )

        #expect(lines.price == "$19.99/month")
        #expect(lines.cta == "Subscribe to Pro")
    }

    // MARK: - Periods and fallbacks

    @Test func aYearlyProductBillsPerYear() {
        let lines = PaywallPricing.lines(
            planID: .plus,
            product: Self.product(
                id: "plus.yearly",
                price: "$49.99",
                period: PurchasesSubscriptionPeriod(unit: .year, value: 1)
            ),
            eligibility: .noOffer,
            fallbackPrice: "$4.99"
        )

        #expect(lines.price == "$49.99/year")
        #expect(lines.renewal == "Renews automatically at $49.99/year until canceled.")
    }

    /// More than one unit reads as a count.
    @Test func aMultiMonthPeriodIsCounted() {
        let lines = PaywallPricing.lines(
            planID: .plus,
            product: Self.product(
                id: "plus.quarterly",
                price: "$12.99",
                period: PurchasesSubscriptionPeriod(unit: .month, value: 3)
            ),
            eligibility: .noOffer,
            fallbackPrice: "$4.99"
        )

        #expect(lines.price == "$12.99/3 months")
    }

    /// Before the catalog loads there is no product at all. The card still
    /// has to say something true, and monthly is what both plans bill at.
    @Test func noProductFallsBackToTheStaticPriceAndAMonthlyPeriod() {
        let plus = PaywallPricing.lines(planID: .plus, product: nil, eligibility: nil, fallbackPrice: "$4.99")
        let pro = PaywallPricing.lines(planID: .pro, product: nil, eligibility: nil, fallbackPrice: "$19.99")

        #expect(plus.price == "$4.99/month")
        #expect(plus.cta == "Choose Plus")
        #expect(pro.price == "$19.99/month")
        #expect(pro.cta == "Subscribe to Pro")
        #expect(pro.renewal == "Renews automatically at $19.99/month until canceled.")
    }

    /// A blank storefront string is as good as no product.
    @Test func aBlankPriceFallsBackToo() {
        let lines = PaywallPricing.lines(
            planID: .plus,
            product: Self.product(id: "plus", price: "   "),
            eligibility: .noOffer,
            fallbackPrice: "$4.99"
        )

        #expect(lines.price == "$4.99/month")
    }
}
