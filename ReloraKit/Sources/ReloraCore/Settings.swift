import Foundation

/// Keys in the SQLite `app_settings` key/value store. Every column is
/// TEXT — the schema carries no types beyond that — so this enum is the
/// single source of truth for which key strings exist. Ports the scattered
/// `STORAGE_KEY_BY_SETTING` / `ONBOARDING_*_KEY` constants in
/// apps/mobile/src/features/settings/appPreferences.ts,
/// apps/mobile/src/features/onboarding/onboardingStorage.ts, and
/// apps/mobile/src/features/billing/storage.ts.
public enum AppSettingsKey: String, Equatable, Sendable, CaseIterable {
    case reminderNotificationsEnabled = "reminder_notifications_enabled"
    case saveVoiceTranscripts = "save_voice_transcripts"
    case onboardingCompleted = "onboarding_completed"
    case onboardingStep = "onboarding_step"
    case onboardingAudience = "onboarding_audience"
    case onboardingTutorialCompleted = "onboarding_tutorial_completed"
    case onboardingTutorialContactID = "onboarding_tutorial_contact_id"
    case onboardingTutorialSeedVersion = "onboarding_tutorial_seed_version"

    /// The onboarding tutorial reminder's own row id, once seeded. Added by
    /// M10 (`OnboardingTutorialSeedWriter.swift`, ReloraFeatures) as the
    /// mechanism `NotificationReconciler` checks instead of the reminder's
    /// title — see that file's doc comment. Chosen over a sentinel
    /// `notification_id` because it survives the reminder-notifications
    /// toggle's unconditional `notification_id = NULL` clear
    /// (`ReminderNotificationsToggle.swift`).
    case onboardingTutorialReminderID = "onboarding_tutorial_reminder_id"

    /// Whether the one-time "How voice notes work" disclosure has been
    /// shown and acknowledged. Written only by the disclosure's Continue
    /// button, never by a dismiss — a swipe is not consent. Absent reads as
    /// false through `getBooleanStrict`, the same default-false sense every
    /// boolean key but the two in `AppSettingsDefaults` uses. No RN
    /// counterpart: the Expo client never shipped this screen, so there is
    /// no storage constant to mirror. Added by 2.4.0
    /// (`VoiceDisclosureStorage.swift`, ReloraFeatures).
    case voiceDisclosureSeen = "voice_disclosure_seen"

    case softUpsellDismissed = "soft_upsell_dismissed"
    case pendingAuthIntent = "pending_auth_intent"
    case subscriptionSnapshot = "subscription_snapshot"
    case localAnonymousUserID = "local_anonymous_user_id"

    /// How many times in a row someone has declined the pre-permission
    /// priming sheet for reminder notifications. Stored as a plain integer
    /// string; absent reads as 0 through `getRawValue`/`Int.init`, the same
    /// default-false-shaped sense every boolean key but the two in
    /// `AppSettingsDefaults` uses — not the `reminderNotificationsEnabled`
    /// pattern. Reset to absent on a grant. Added by M8
    /// (`NotificationPriming.swift`, ReloraServices); mirrors RN's decline
    /// counter in `reminderNotificationPreferences.ts`.
    case reminderNotificationPrimingDeclines = "reminder_notification_priming_declines"

    /// Durable marker for an in-progress (or stranded) guest → account
    /// ownership migration. Mirrors `PENDING_OWNERSHIP_MIGRATION_KEY` in
    /// apps/mobile/src/state/ownershipMigration.ts. See `GuestMigration`
    /// (ReloraData) — the only reader/writer of this key.
    case pendingOwnershipMigration = "pending_ownership_migration"

    /// The onboarding sample persona's version tag, stored under
    /// `onboardingTutorialSeedVersion`. Bump this (and the RN constant it
    /// mirrors) whenever the seeded persona's content changes — a device
    /// holding an older seed reads as "no example yet" rather than showing
    /// stale copy naming the new persona. Mirrors
    /// `ONBOARDING_TUTORIAL_SEED_VERSION` in
    /// apps/mobile/src/features/onboarding/types.ts.
    public static let onboardingTutorialSeedVersionValue = "priya-v1"
}

/// How boolean-shaped `app_settings` values are stored and read back.
///
/// This is not one uniform rule. `reminderNotificationsEnabled` and
/// `saveVoiceTranscripts` — the two keys read through
/// `readAppSettings`/`readBooleanSetting` in appPreferences.ts — default to
/// `true` when no row exists (`DEFAULT_APP_SETTINGS`). Every other
/// boolean-shaped key (`onboardingCompleted`, `onboardingTutorialCompleted`,
/// `softUpsellDismissed`) is read elsewhere in the RN source with a bare
/// `value === '1'`, i.e. it defaults to `false` when absent. This asymmetry
/// is real in the app being ported, not an oversight here — callers must
/// pick `decode(_:fallback:)` or `decodeStrict(_:)` deliberately per key.
public enum AppSettingsBoolean {
    /// Decodes a raw `app_settings.value`, applying `fallback` when the row
    /// is absent or holds neither `"1"` nor `"0"`. Use for
    /// `reminderNotificationsEnabled` / `saveVoiceTranscripts`. Mirrors
    /// `readBooleanSetting` in appPreferences.ts.
    public static func decode(_ rawValue: String?, fallback: Bool) -> Bool {
        switch rawValue {
        case "1": return true
        case "0": return false
        default: return fallback
        }
    }

    /// Decodes a raw value with the bare `value === '1'` rule every other
    /// boolean key uses: absent, or anything other than exactly `"1"`,
    /// reads as `false`.
    public static func decodeStrict(_ rawValue: String?) -> Bool {
        rawValue == "1"
    }

    /// Encodes a `Bool` the way every RN writer does: the literal strings
    /// `"1"` / `"0"`.
    public static func encode(_ value: Bool) -> String {
        value ? "1" : "0"
    }
}

/// Defaults `readAppSettings` applies for the settings it manages. Mirrors
/// `DEFAULT_APP_SETTINGS` in appPreferences.ts.
public enum AppSettingsDefaults {
    public static let reminderNotificationsEnabled = true
    public static let saveVoiceTranscripts = true
}
