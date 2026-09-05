import Foundation
import ReloraCore
import ReloraServices
import ReloraSync

/// Legal links and support contact, ported verbatim from `legalLinks.ts`.
public enum SettingsLegal {
    public static let privacyPolicyURL = URL(string: "https://reloraapp.com/privacy")!
    public static let termsOfUseURL = URL(string: "https://reloraapp.com/terms-of-use")!
    public static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!
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
        title: "Sign Out?",
        message: "Syncing stops on this device until you sign back in. Your notes stay in your account.",
        confirmLabel: "Sign Out"
    )

    public static let deleteAccount = Dialog(
        title: "Delete Account?",
        message: "This permanently deletes your account, everything synced to it, and every note on this iPhone. Export your data first if you want a copy.",
        confirmLabel: "Delete"
    )
}

/// Plan-row and Subscription-section copy. Ports `buildPlanSummary`
/// (planPresentation.ts), split into two pure functions so the Plan row's
/// value and the section footer can sit in different places on screen.
public enum SettingsPlanCopy {
    /// The Plan row's value: "Free", "Plus", "Pro", or "Pro Trial".
    ///
    /// Reads `subscription.planID` — the real, RevenueCat-backed plan —
    /// instead of `evaluation.planID`, so the row can never disagree with
    /// the billing source of truth, whatever conformer produced the
    /// evaluation (see the M10 report).
    public static func planName(_ subscription: SubscriptionSnapshot) -> String {
        switch subscription.planID {
        case .free: return "Free"
        case .plus: return "Plus"
        case .pro: return subscription.trialIsActive ? "Pro Trial" : "Pro"
        }
    }

    /// The Subscription section's footer: one or two short sentences.
    ///
    /// `evaluation` supplies `freeNotesUsed` and `monthlyNotesRemaining` —
    /// accurate on every plan, since `QuotaPolicy.evaluate` sets
    /// `freeNotesUsed = usage.totalProcessedNotes` in all three branches.
    /// For Plus, a populated `monthlyNotesRemaining` renders the exact
    /// count (RN parity); the one honest `nil` is the pre-`load()`
    /// placeholder in `SettingsViewModel.init`, which falls back to
    /// generic copy rather than RN's `?? 0` "100 of 100 used" flash.
    public static func usageFooter(subscription: SubscriptionSnapshot, evaluation: QuotaPolicy.Evaluation) -> String {
        switch subscription.planID {
        case .free:
            return "\(formatFreeUsageLabel(evaluation.freeNotesUsed)). Voice notes up to 1 minute."

        case .plus:
            if let monthlyNotesRemaining = evaluation.monthlyNotesRemaining {
                return "\(formatPlusMonthlyUsageLabel(monthlyNotesRemaining)). Voice notes up to 1 minute."
            }
            return "Up to \(QuotaPolicy.plusMonthlyNoteLimit) notes a month. Voice notes up to 1 minute."

        case .pro:
            guard subscription.trialIsActive else {
                return "Unlimited voice notes, up to 5 minutes each."
            }
            let renewalSentence = subscription.willRenew
                ? "Becomes a paid Pro plan when the trial ends."
                : "This trial will not renew."
            guard let expirationDate = subscription.expirationDate else {
                return renewalSentence
            }
            return "Ends \(formatShortDate(expirationDate)). \(renewalSentence)"
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
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }
}

/// The Voice section's Recordings row: how many recordings this iPhone
/// holds and how much space they take.
///
/// Takes the size pre-formatted, not raw bytes, because byte formatting
/// is locale- and OS-dependent — the copy tests assert an exact string,
/// which a formatter call inside this function would not let them do.
public enum SettingsVoiceCopy {
    /// The two claims the Voice footer makes about audio, hoisted out of
    /// `SettingsView` so the first-recording disclosure can repeat them
    /// word for word instead of writing its own paraphrase. One place to
    /// change, and one place a copy test can pin.
    public static let recordingsStayOnDevice = "Recordings always stay on this iPhone for replay."
    public static let serversDoNotKeepAudio = "Relora's servers transcribe the audio and do not keep it."

    /// The Voice section's footer, byte-identical to the literal it
    /// replaces in `SettingsView`.
    public static let footer = "Keeps the text of each voice note. \(recordingsStayOnDevice) \(serversDoNotKeepAudio)"

    public static func recordingsValue(count: Int, formattedSize: String) -> String {
        guard count > 0 else { return "None" }
        let noun = count == 1 ? "recording" : "recordings"
        return "\(count) \(noun) \u{00B7} \(formattedSize)"
    }
}

/// The Account section's footer: one sentence about sync, always present
/// so the section never reflows.
public enum SettingsSyncCopy {
    public static func footer(_ status: SyncStatus, isOnline: Bool) -> String {
        switch status {
        case .syncing:
            return "Syncing…"
        case .failed:
            return isOnline
                ? "Sync failed. Relora will retry automatically."
                : "Offline. Relora will retry when you're back online."
        case .idle:
            return isOnline
                ? "Synced."
                : "Offline. Relora syncs when you're back online."
        }
    }
}
