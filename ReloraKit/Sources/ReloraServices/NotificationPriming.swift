import Foundation
import ReloraData

/// The pre-prompt decision, ported from `decideReminderNotificationPriming`.
/// Pure, so the decision order is testable without a permission dialog.
public enum ReminderNotificationPrimingDecision: Equatable, Sendable {
    case skip
    case prime
}

public struct ReminderNotificationPrimingContext: Sendable {
    public var notificationsEnabled: Bool
    public var authorizationStatus: NotificationAuthorizationStatus
    /// Whether the priming sheet has already shown once in this app
    /// session — an in-memory flag, never persisted, so it resets on every
    /// launch.
    public var primedThisSession: Bool
    public var declineCount: Int

    public init(
        notificationsEnabled: Bool,
        authorizationStatus: NotificationAuthorizationStatus,
        primedThisSession: Bool,
        declineCount: Int
    ) {
        self.notificationsEnabled = notificationsEnabled
        self.authorizationStatus = authorizationStatus
        self.primedThisSession = primedThisSession
        self.declineCount = declineCount
    }
}

public enum ReminderNotificationPriming {
    /// RN's max decline count before the pre-prompt stops appearing for
    /// good.
    public static let maxDeclines = 3

    /// Checked in order, exactly as RN does: the setting, then whatever the
    /// OS already decided, then this session, then the decline count. Each
    /// step is a reason to skip; only falling through all of them primes.
    public static func decide(_ context: ReminderNotificationPrimingContext) -> ReminderNotificationPrimingDecision {
        guard context.notificationsEnabled else { return .skip }
        switch context.authorizationStatus {
        case .authorized, .provisional, .denied:
            return .skip
        case .notDetermined:
            break
        }
        guard !context.primedThisSession else { return .skip }
        guard context.declineCount < maxDeclines else { return .skip }
        return .prime
    }
}

/// Persists the decline counter across launches, and resets it on a grant.
///
/// `app_settings` stores it as a plain integer string under
/// `AppSettingsKey.reminderNotificationPrimingDeclines`; an absent row reads
/// as 0 — the opposite default sense from `reminderNotificationsEnabled`
/// (which defaults *true* when absent). See that key's doc comment in
/// `ReloraCore/Settings.swift` for why the two are not the same rule.
public struct ReminderNotificationPrimingStore: Sendable {
    private let settings: AppSettingsStore

    public init(database: AppDatabase) {
        self.settings = AppSettingsStore(database: database)
    }

    public func declineCount() -> Int {
        let raw = (try? settings.getRawValue(.reminderNotificationPrimingDeclines)) ?? nil
        return raw.flatMap(Int.init) ?? 0
    }

    public func recordDecline() {
        try? settings.setRawValue(.reminderNotificationPrimingDeclines, String(declineCount() + 1))
    }

    /// RN clears the counter on a grant, so a user who declines twice and
    /// later turns permission on from Settings is never penalized for the
    /// declines that came before.
    public func reset() {
        try? settings.setRawValue(.reminderNotificationPrimingDeclines, nil)
    }
}
