import Foundation
import ReloraCore
import ReloraServices

/// Legal links and support contact, ported verbatim from `legalLinks.ts`.
public enum SettingsLegal {
    public static let privacyPolicyURL = URL(string: "https://reloraapp.com/privacy")!
    public static let termsOfUseURL = URL(string: "https://reloraapp.com/terms-of-use")!
    public static let supportEmail = "contact@immform.com"

    public struct SupportEmailContext {
        public var appName: String
        public var appVersion: String
        public var platform: String
        public var signedIn: Bool

        public init(appName: String, appVersion: String, platform: String, signedIn: Bool) {
            self.appName = appName
            self.appVersion = appVersion
            self.platform = platform
            self.signedIn = signedIn
        }
    }

    private static func normalize(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    public static func supportEmailSubject(appName: String) -> String {
        "\(normalize(appName, fallback: "Relora")) support request"
    }

    public static func supportEmailBody(_ context: SupportEmailContext) -> String {
        let appName = normalize(context.appName, fallback: "Relora")
        let appVersion = normalize(context.appVersion, fallback: "unknown")
        let platform = normalize(context.platform, fallback: "unknown")
        return [
            "Please describe your issue or request below.",
            "",
            "App: \(appName)",
            "Version: \(appVersion)",
            "Platform: \(platform)",
            "Signed in: \(context.signedIn ? "Yes" : "No")",
            "",
            "Details:",
            "",
        ].joined(separator: "\n")
    }

    public static func supportEmailURL(_ context: SupportEmailContext) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: supportEmailSubject(appName: context.appName)),
            URLQueryItem(name: "body", value: supportEmailBody(context)),
        ]
        // `URLComponents` percent-encodes query items itself; `mailto:` uses
        // an opaque path rather than `//host`, so `url` only comes out right
        // when `path` (not `host`) carries the address, matched above.
        return components.url
    }
}

/// Destructive-confirmation copy. Ports `createSignOutAlertOptions` and
/// `createDeleteAccountAlertOptions` — the only two confirmation dialogs in
/// the app, per the milestone brief.
public enum SettingsConfirmation {
    public struct Dialog {
        public var title: String
        public var message: String
        public var confirmLabel: String

        public init(title: String, message: String, confirmLabel: String) {
            self.title = title
            self.message = message
            self.confirmLabel = confirmLabel
        }
    }

    public static let signOut = Dialog(
        title: "Sign out?",
        message: "Relora stops syncing on this device and hides your notes until you sign back in. Nothing is deleted — your notes stay in your account and on this device.",
        confirmLabel: "Sign out"
    )

    public static let deleteAccount = Dialog(
        title: "Delete account?",
        message: "This permanently deletes your Relora account and everything synced to it, and wipes every contact, memory, key thing, and reminder stored on this device. Scheduled reminder notifications are cancelled. Nothing can be recovered — export your data first if you want a copy.",
        confirmLabel: "Delete"
    )
}

/// Plan-row title and description. Ports `buildPlanSummary`
/// (planPresentation.ts), with one forced simplification — see the Plus
/// branch's comment.
public enum SettingsPlanCopy {
    public struct Summary: Equatable, Sendable {
        public var title: String
        public var description: String
    }

    /// - Parameters:
    ///   - subscription: `billing.subscriptionSnapshot` — the real,
    ///     RevenueCat-backed plan. Used for `planID` instead of
    ///     `evaluation.planID` so the row can never disagree with the
    ///     billing source of truth, whatever conformer produced the
    ///     evaluation (see the M10 report).
    ///   - evaluation: the voice-access evaluation, used only for
    ///     `freeNotesUsed` — accurate on every plan, since
    ///     `QuotaPolicy.evaluate` sets `freeNotesUsed = usage.totalProcessedNotes`
    ///     in all three branches.
    public static func build(subscription: SubscriptionSnapshot, evaluation: QuotaPolicy.Evaluation) -> Summary {
        switch subscription.planID {
        case .pro:
            if subscription.trialIsActive {
                let endDate = subscription.expirationDate.map(Self.formatShortDate)
                return Summary(
                    title: endDate.map { "Pro trial — ends \($0)" } ?? "Pro trial",
                    description: subscription.willRenew
                        ? "Unlimited voice notes up to 5 minutes. Becomes a paid Pro plan when the trial ends."
                        : "Unlimited voice notes up to 5 minutes. This trial will not renew."
                )
            }
            return Summary(title: "Pro", description: "Unlimited voice notes, up to 5 minutes each.")

        case .plus:
            // RN shows "12 of 100 notes used this month" — and since M9's
            // `RevenueCatVoiceAccess` swap, `evaluation` is computed against
            // the real plan, so `monthlyNotesRemaining` is populated for a
            // Plus subscriber. (The M10 draft assumed the pre-M9 interim
            // conformer's always-free evaluation and used generic
            // copy; corrected in review.) The one honest `nil` left is the
            // pre-`load()` placeholder in `SettingsViewModel.init` — RN's
            // `?? 0` would render that as "100 of 100 used" for a frame, so
            // `nil` keeps the generic line instead of a fabricated count.
            if let monthlyNotesRemaining = evaluation.monthlyNotesRemaining {
                return Summary(title: "Plus", description: "\(formatPlusMonthlyUsageLabel(monthlyNotesRemaining)). Voice notes up to 1 minute.")
            }
            return Summary(title: "Plus", description: "Voice notes up to 1 minute. Up to \(QuotaPolicy.plusMonthlyNoteLimit) notes a month.")

        case .free:
            return Summary(title: "Free", description: "\(formatFreeUsageLabel(evaluation.freeNotesUsed)). Voice notes up to 1 minute.")
        }
    }

    /// Mirrors `formatPlusMonthlyUsageLabel`: "12 of 100 notes used this
    /// month", derived from the remaining allowance, clamped the same way.
    public static func formatPlusMonthlyUsageLabel(_ monthlyNotesRemaining: Int) -> String {
        let remaining = min(QuotaPolicy.plusMonthlyNoteLimit, max(0, monthlyNotesRemaining))
        return "\(QuotaPolicy.plusMonthlyNoteLimit - remaining) of \(QuotaPolicy.plusMonthlyNoteLimit) notes used this month"
    }

    /// Mirrors `formatFreeUsageLabel`: the used count is clamped so an
    /// over-quota ledger still reads sanely.
    public static func formatFreeUsageLabel(_ freeNotesUsed: Int) -> String {
        let used = min(QuotaPolicy.freeNoteLimit, max(0, freeNotesUsed))
        return "\(used) of \(QuotaPolicy.freeNoteLimit) free notes used"
    }

    private static func formatShortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
