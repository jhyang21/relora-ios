import SwiftUI
import ReloraCore
import ReloraDesign
import ReloraServices

/// Ports `PaywallScreen.tsx` / `PurchaseSuccessScreen.tsx`
/// (apps/mobile/src/features/billing) as one sheet: the plan list, and — once
/// a purchase or restore lands on a paid plan — an in-place success view,
/// swapped in by state rather than pushed as a second route. RN calls
/// `navigation.replace('PurchaseSuccess', …)`, which the same single-slot
/// swap matches more closely than a `navigationDestination` push would;
/// pushing would also need `SubscriptionSnapshot: Hashable` for no reason
/// beyond routing.
///
/// A guest who chooses a plan or taps Restore is routed through a nested
/// `AuthView` sheet rather than RN's separate `AuthGate` screen plus a
/// storage-persisted `pendingAuthIntent`. The intent lives in `@State` here
/// instead: once `identity.identity` becomes `.account` while that sheet is
/// showing, the pending purchase or restore resumes automatically. See the
/// M9 report for what this trades away — the intent does not survive the
/// app being killed while an email-confirmation link is pending, which RN's
/// persisted version does.
public struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss

    private let reason: AppRouter.PaywallReason?
    private let billing: BillingService
    private let identity: IdentityController
    private let toasts: ReloraToastCenter

    @State private var loadingAction: LoadingAction?
    @State private var purchasedSnapshot: SubscriptionSnapshot?
    @State private var pendingAuthGate: PendingAuthAction?
    @State private var resumeAction: PendingAuthAction?

    private enum LoadingAction: Equatable {
        case plan(QuotaPolicy.PlanID)
        case restore
    }

    private enum PendingAuthAction: Identifiable, Equatable {
        case purchase(QuotaPolicy.PlanID)
        case restore
        case signIn

        var id: String {
            switch self {
            case .purchase(let planID): return "purchase-\(planID)"
            case .restore: return "restore"
            case .signIn: return "signIn"
            }
        }
    }

    public init(reason: AppRouter.PaywallReason?, billing: BillingService, identity: IdentityController, toasts: ReloraToastCenter) {
        self.reason = reason
        self.billing = billing
        self.identity = identity
        self.toasts = toasts
    }

    private var isAccount: Bool {
        if case .account = identity.identity { return true }
        return false
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let purchasedSnapshot {
                    PurchaseSuccessView(snapshot: purchasedSnapshot, catalog: billing.purchaseCatalog) {
                        dismiss()
                    }
                } else {
                    paywallContent
                }
            }
            .background(ReloraColor.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if purchasedSnapshot == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
            }
        }
        .sheet(item: $pendingAuthGate) { action in
            AuthView(context: authGateContext(for: action), identity: identity)
        }
        .onChange(of: identity.identity) { _, newValue in
            guard case .account = newValue, let action = resumeAction else { return }
            resumeAction = nil
            pendingAuthGate = nil
            Task { await resume(action) }
        }
    }

    // MARK: - Plan list

    private var paywallContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ReloraSpacing.lg) {
                let copy = paywallCopy(for: reason)
                VStack(alignment: .leading, spacing: ReloraSpacing.sm) {
                    Text(copy.headline)
                        .font(ReloraFont.title)
                        .foregroundStyle(ReloraColor.ink)
                    Text(copy.subhead)
                        .font(ReloraFont.body)
                        .foregroundStyle(ReloraColor.mutedInk)
                }

                if !billing.isCatalogAvailable {
                    noticeCard("Plans are temporarily unavailable. Try again in a moment.")
                }

                if !isAccount {
                    noticeCard("Choosing a plan will ask you to create an account or sign in first, so your subscription can be linked to it.")
                }

                ForEach(paywallPlans, id: \.planID) { plan in
                    planCard(plan)
                }

                VStack(alignment: .leading, spacing: ReloraSpacing.sm) {
                    Button {
                        Task { await runRestore() }
                    } label: {
                        Text(loadingAction == .restore ? "Restoring..." : "Restore purchases")
                            .font(ReloraFont.footnote)
                            // Footnote text is a 16pt-tall target on its own.
                            // The frame is what makes this a control rather
                            // than a line of writing that happens to respond.
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ReloraColor.accentText)
                    .disabled(loadingAction != nil)
                    // The visible text reports progress; the name does not move.
                    .accessibilityLabel("Restore purchases")

                    if !isAccount {
                        Button {
                            pendingAuthGate = .signIn
                        } label: {
                            Text("Create account or sign in")
                                .font(ReloraFont.footnote)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(ReloraColor.accentText)
                        .disabled(loadingAction != nil)
                    }

                    if showQuotaResetLine {
                        Text("Your Plus notes reset on \(formatMonthlyQuotaResetDate()).")
                            .font(ReloraFont.footnote)
                            .foregroundStyle(ReloraColor.mutedInk)
                    }

                    Text("Manage or cancel anytime in your App Store subscription settings.")
                        .font(ReloraFont.footnote)
                        .foregroundStyle(ReloraColor.mutedInk)

                    // Apple 3.1.2 wants a working link to the terms of use
                    // and to the privacy policy on the purchase screen
                    // itself. The same links live in Settings, but this
                    // sheet is reachable without ever opening Settings, so
                    // they have to be here too.
                    HStack(spacing: 16) {
                        Link("Terms of Use", destination: SettingsLegal.termsOfUseURL)
                            .accessibilityLabel("Terms of Use, opens in Safari")
                        Link("Privacy Policy", destination: SettingsLegal.privacyPolicyURL)
                            .accessibilityLabel("Privacy Policy, opens in Safari")
                    }
                    .font(ReloraFont.footnote)
                    .foregroundStyle(ReloraColor.tertiaryInk)
                    .underline()
                }
            }
            .padding(.horizontal, ReloraLayout.screenHPadding)
            .padding(.vertical, ReloraSpacing.lg)
            .frame(maxWidth: ReloraLayout.contentMaxWidth)
        }
        .scrollContentBackground(.hidden)
    }

    private var showQuotaResetLine: Bool {
        billing.subscriptionSnapshot.planID == .plus && reason == .plusQuotaReached
    }

    @ViewBuilder
    private func planCard(_ plan: PaywallPlanDefinition) -> some View {
        let isCurrentPlan = billing.subscriptionSnapshot.planID == plan.planID
        let isLoadingThisPlan = loadingAction == .plan(plan.planID)
        // Price, renewal sentence and button label all come from the live
        // catalog entry and StoreKit's eligibility answer - see
        // `PaywallPricing`. `plan.priceLine` is only the pre-catalog
        // fallback now.
        let lines = PaywallPricing.lines(
            planID: plan.planID,
            product: billing.purchaseCatalog[plan.planID],
            eligibility: billing.trialEligibility[plan.planID],
            fallbackPrice: plan.priceLine
        )

        ReloraCard(shadow: plan.featured ? .raised : .card) {
            VStack(alignment: .leading, spacing: ReloraSpacing.sm) {
                HStack(spacing: ReloraSpacing.sm) {
                    Text(plan.title)
                        .font(ReloraFont.title3)
                        .foregroundStyle(ReloraColor.ink)
                    if plan.featured {
                        Text("Best value")
                            .font(ReloraFont.footnote)
                            .foregroundStyle(ReloraColor.onAccent)
                            .padding(.horizontal, ReloraSpacing.sm)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(ReloraColor.accent))
                    }
                    Spacer()
                }

                Text(lines.price)
                    .font(ReloraFont.body)
                    .foregroundStyle(ReloraColor.mutedInk)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(plan.bullets, id: \.self) { bullet in
                        Text("• \(bullet)")
                            .font(ReloraFont.footnote)
                            .foregroundStyle(ReloraColor.ink)
                            // The bullet is punctuation inside the string, so
                            // it cannot be hidden as a separate view — but
                            // VoiceOver says "bullet" before every feature on
                            // the plan card unless the label drops it.
                            .accessibilityLabel(bullet)
                    }
                }

                // Both cards carry it, not just Pro: Apple 3.1.2 asks for
                // the renewal terms of every auto-renewing plan the screen
                // offers.
                Text(lines.renewal)
                    .font(ReloraFont.footnote)
                    .foregroundStyle(ReloraColor.tertiaryInk)

                Button {
                    Task { await runPurchase(plan.planID) }
                } label: {
                    Text(isCurrentPlan ? "Current plan" : (isLoadingThisPlan ? "Processing..." : lines.cta))
                }
                .buttonStyle(.reloraPrimary)
                .disabled(loadingAction != nil || isCurrentPlan)
                .accessibilityLabel("\(plan.title), \(lines.price)")
            }
        }
    }

    @ViewBuilder
    private func noticeCard(_ text: String) -> some View {
        ReloraCard(surface: ReloraColor.warmCard) {
            Text(text)
                .font(ReloraFont.footnote)
                .foregroundStyle(ReloraColor.ink)
        }
    }

    // MARK: - Purchase / restore / auth-gate flow

    private func runPurchase(_ planID: QuotaPolicy.PlanID) async {
        guard isAccount else {
            resumeAction = .purchase(planID)
            pendingAuthGate = .purchase(planID)
            return
        }
        loadingAction = .plan(planID)
        defer { loadingAction = nil }
        switch await billing.purchase(planID: planID) {
        case .cancelled:
            break
        case .requiresAccount:
            resumeAction = .purchase(planID)
            pendingAuthGate = .purchase(planID)
        case .failed(let message):
            toasts.showError("Purchase unavailable", message: message)
        case .success(let snapshot):
            purchasedSnapshot = snapshot
        }
    }

    private func runRestore() async {
        guard isAccount else {
            resumeAction = .restore
            pendingAuthGate = .restore
            return
        }
        loadingAction = .restore
        defer { loadingAction = nil }
        switch await billing.restorePurchases() {
        case .noPurchasesFound:
            toasts.show("No purchases found", message: "We could not find an active subscription to restore.")
        case .requiresAccount:
            resumeAction = .restore
            pendingAuthGate = .restore
        case .failed(let message):
            toasts.showError("Restore unavailable", message: message)
        case .restored(let snapshot):
            purchasedSnapshot = snapshot
        }
    }

    private func resume(_ action: PendingAuthAction) async {
        switch action {
        case .purchase(let planID):
            await runPurchase(planID)
        case .restore:
            await runRestore()
        case .signIn:
            break
        }
    }

    private func authGateContext(for action: PendingAuthAction) -> AuthGateContext {
        switch action {
        case .purchase: return AuthGateContext(action: .purchase, source: .paywall)
        case .restore: return AuthGateContext(action: .restore, source: .paywall)
        case .signIn: return AuthGateContext(action: .signIn, source: .paywall)
        }
    }
}

// MARK: - Purchase success

/// Mirrors `PurchaseSuccessScreen.tsx`. Rendered in place of the plan list
/// inside the same `PaywallView` sheet — see that type's doc comment.
private struct PurchaseSuccessView: View {
    let snapshot: SubscriptionSnapshot
    let catalog: [QuotaPolicy.PlanID: PurchasesProduct]
    let onContinue: () -> Void

    /// Grows with the copy beneath it; a hero glyph pinned at 44pt beside
    /// accessibility-size text reads as an icon that failed to load.
    @ScaledMetric(relativeTo: .largeTitle) private var sealSize: CGFloat = 44

    /// A Pro purchase is not always a trial: an Apple ID that has already
    /// spent the free trial buys straight into a paid plan, and telling
    /// that person their "trial" is active is the same 3.1.2 problem the
    /// plan cards had.
    private var title: String {
        if snapshot.trialIsActive { return "Your Pro trial is active" }
        return snapshot.planID == .pro ? "Your Pro plan is active" : "Your Plus plan is active"
    }

    /// Eligibility is settled by what was actually bought: a snapshot in
    /// its trial period proves the offer was taken, and one that is not
    /// proves it was not.
    private var lines: PaywallPricing.Lines {
        PaywallPricing.lines(
            planID: snapshot.planID,
            product: catalog[snapshot.planID],
            eligibility: snapshot.trialIsActive ? .eligible : .ineligible,
            fallbackPrice: fallbackPrice(for: snapshot.planID)
        )
    }

    private var trialEndDateText: String? {
        guard snapshot.trialIsActive, let expirationDate = snapshot.expirationDate else { return nil }
        return shortDateFormatter.string(from: expirationDate)
    }

    /// Every paid plan says how it renews, not only Pro - the buyer has
    /// just been charged, and this is the last screen before the app.
    private var bodyText: String {
        guard snapshot.planID != .free else {
            return "You can keep creating voice notes right away."
        }
        if let trialEndDateText {
            return "Free until \(trialEndDateText). \(lines.renewal)"
        }
        return lines.renewal
    }

    var body: some View {
        VStack(spacing: ReloraSpacing.lg) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: sealSize))
                .foregroundStyle(ReloraColor.success)
                .accessibilityHidden(true)

            VStack(spacing: ReloraSpacing.sm) {
                Text(title)
                    .font(ReloraFont.title)
                    .foregroundStyle(ReloraColor.ink)
                    .multilineTextAlignment(.center)
                Text(bodyText)
                    .font(ReloraFont.body)
                    .foregroundStyle(ReloraColor.mutedInk)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: ReloraSpacing.sm) {
                Button("Continue", action: onContinue)
                    .buttonStyle(.reloraPrimary)
                Text("Manage or cancel anytime in your App Store subscription settings.")
                    .font(ReloraFont.footnote)
                    .foregroundStyle(ReloraColor.mutedInk)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(ReloraLayout.screenHPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Copy and pricing (mirrors paywallContent.ts)

private struct PaywallPlanDefinition {
    let planID: QuotaPolicy.PlanID
    let title: String
    /// The pre-catalog fallback price, and nothing else: the period, the
    /// trial wording and the button label are `PaywallPricing`'s to write
    /// from the live product.
    let priceLine: String
    let bullets: [String]
    let featured: Bool
}

/// The fallback price for a plan, for a card with no live product yet.
private func fallbackPrice(for planID: QuotaPolicy.PlanID) -> String {
    paywallPlans.first { $0.planID == planID }?.priceLine ?? ""
}

/// Mirrors `PAYWALL_PLANS` (paywallContent.ts) minus the money: the prices
/// here are bare fallbacks, and the CTA is computed.
private let paywallPlans: [PaywallPlanDefinition] = [
    PaywallPlanDefinition(
        planID: .plus,
        title: "Plus",
        priceLine: "$4.99",
        bullets: [
            "100 voice notes per month",
            "Up to 1 minute per note",
            "Organized notes and search",
        ],
        featured: false
    ),
    PaywallPlanDefinition(
        planID: .pro,
        title: "Pro",
        priceLine: "$19.99",
        bullets: [
            "Unlimited voice notes",
            "Up to 5 minutes per note",
            "Lower latency",
            "Smarter note organization",
        ],
        featured: true
    ),
]

/// Mirrors `getPaywallCopy({reason})`, all four branches. `nil` falls to
/// the free-limit copy, same as RN's undefined reason.
private func paywallCopy(for reason: AppRouter.PaywallReason?) -> (headline: String, subhead: String) {
    switch reason {
    case .plusQuotaReached:
        return (
            "You’ve reached your Plus note limit for this month",
            "Upgrade to Pro for unlimited captures and longer voice notes."
        )
    case .durationLimit:
        return (
            "Upgrade for longer voice notes",
            "Pro supports up to 5 minutes per note with faster and smarter note organization."
        )
    case .manual:
        return (
            "Upgrade when you’re ready for more",
            "Choose a plan for more captures, longer notes, and smarter organization."
        )
    case .freeLimitReached, nil:
        return (
            "You’ve used your 5 free notes",
            "Choose a plan to keep capturing notes about the people in your life."
        )
    }
}

/// Mirrors `formatMonthlyQuotaResetDate`: usage resets on the local
/// calendar month boundary `QuotaPolicy.currentMonthWindow` already
/// computes, so no separate date arithmetic is needed here.
private func formatMonthlyQuotaResetDate(now: Date = Date(), calendar: Calendar = .current) -> String {
    let window = QuotaPolicy.currentMonthWindow(now: now, calendar: calendar)
    return shortDateFormatter.string(from: window.end)
}

/// Mirrors `formatShortDate` (relativeTime.ts): fixed English month
/// abbreviations regardless of device locale, matching RN's hardcoded
/// `MONTH_NAMES` table rather than `DateFormatter`'s locale-sensitive
/// default.
private let shortDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "MMM d"
    return formatter
}()
