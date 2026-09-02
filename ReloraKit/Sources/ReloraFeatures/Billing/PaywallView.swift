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
/// `AuthGateView` sheet rather than RN's separate `AuthGate` screen plus a
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
            AuthGateView(context: authGateContext(for: action), identity: identity, toasts: toasts)
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
                            Text("Create account or sign in with email and password")
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
        let priceText = displayedPrice(for: plan.planID, catalog: billing.purchaseCatalog, fallback: plan.priceLine)

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

                Text(priceText)
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

                if plan.planID == .pro {
                    Text(buildProRenewalLine(proRenewalPrice(catalog: billing.purchaseCatalog)))
                        .font(ReloraFont.footnote)
                        .foregroundStyle(ReloraColor.tertiaryInk)
                }

                Button {
                    Task { await runPurchase(plan.planID) }
                } label: {
                    Text(isCurrentPlan ? "Current plan" : (isLoadingThisPlan ? "Processing..." : plan.cta))
                }
                .buttonStyle(.reloraPrimary)
                .disabled(loadingAction != nil || isCurrentPlan)
                .accessibilityLabel("\(plan.title), \(priceText)")
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

    private var title: String {
        snapshot.planID == .pro ? "Your Pro trial is active" : "Your Plus plan is active"
    }

    private var trialEndDateText: String? {
        guard snapshot.trialIsActive, let expirationDate = snapshot.expirationDate else { return nil }
        return shortDateFormatter.string(from: expirationDate)
    }

    private var bodyText: String {
        guard snapshot.planID == .pro else {
            return "You can keep creating voice notes right away."
        }
        let renewalLine = buildProRenewalLine(proRenewalPrice(catalog: catalog))
        if let trialEndDateText {
            return "Free until \(trialEndDateText). \(renewalLine)"
        }
        return renewalLine
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
    let priceLine: String
    let bullets: [String]
    let cta: String
    let featured: Bool
}

/// Mirrors `PAYWALL_PLANS` (paywallContent.ts) verbatim.
private let paywallPlans: [PaywallPlanDefinition] = [
    PaywallPlanDefinition(
        planID: .plus,
        title: "Plus",
        priceLine: "$4.99/month",
        bullets: [
            "100 voice notes per month",
            "Up to 1 minute per note",
            "Organized notes and search",
        ],
        cta: "Choose Plus",
        featured: false
    ),
    PaywallPlanDefinition(
        planID: .pro,
        title: "Pro",
        priceLine: "7 days free, then $19.99/month",
        bullets: [
            "Unlimited voice notes",
            "Up to 5 minutes per note",
            "Lower latency",
            "Smarter note organization",
        ],
        cta: "Start 7-day free trial",
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

/// Mirrors `getDisplayedPlanPrice`: the live storefront price when the
/// catalog has one, else the copy's static `priceLine`.
private func displayedPrice(for planID: QuotaPolicy.PlanID, catalog: [QuotaPolicy.PlanID: PurchasesProduct], fallback: String) -> String {
    if let product = catalog[planID] {
        let trimmed = product.localizedPriceString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
    }
    return fallback
}

/// Mirrors `getPlanRenewalPrice(catalog, 'pro')`.
private func proRenewalPrice(catalog: [QuotaPolicy.PlanID: PurchasesProduct]) -> String? {
    guard let product = catalog[.pro] else { return nil }
    let trimmed = product.localizedPriceString.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// Mirrors `buildProRenewalLine`.
private func buildProRenewalLine(_ renewalPrice: String?) -> String {
    if let renewalPrice {
        return "Renews automatically at \(renewalPrice)/month unless canceled before the trial ends."
    }
    return "Renews automatically unless canceled before the trial ends."
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
