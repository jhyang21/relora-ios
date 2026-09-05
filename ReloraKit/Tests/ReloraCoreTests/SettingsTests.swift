import Testing
@testable import ReloraCore

@Suite("Settings")
struct SettingsTests {
    @Test("decode(_:fallback:) applies the fallback when the row is absent or unrecognized")
    func decodeAppliesFallback() {
        #expect(AppSettingsBoolean.decode("1", fallback: false) == true)
        #expect(AppSettingsBoolean.decode("0", fallback: true) == false)
        #expect(AppSettingsBoolean.decode(nil, fallback: true) == true)
        #expect(AppSettingsBoolean.decode(nil, fallback: false) == false)
        #expect(AppSettingsBoolean.decode("garbage", fallback: true) == true)
        #expect(AppSettingsBoolean.decode("garbage", fallback: false) == false)
    }

    @Test("decodeStrict treats anything but the literal \"1\" as false, including absence")
    func decodeStrictDefaultsFalse() {
        #expect(AppSettingsBoolean.decodeStrict("1") == true)
        #expect(AppSettingsBoolean.decodeStrict("0") == false)
        #expect(AppSettingsBoolean.decodeStrict(nil) == false)
        #expect(AppSettingsBoolean.decodeStrict("garbage") == false)
        #expect(AppSettingsBoolean.decodeStrict("true") == false)
    }

    @Test("encode writes the literal \"1\"/\"0\" strings every RN writer uses")
    func encodeWritesLiteralDigits() {
        #expect(AppSettingsBoolean.encode(true) == "1")
        #expect(AppSettingsBoolean.encode(false) == "0")
    }

    @Test("reminderNotificationsEnabled and saveVoiceTranscripts default to true when absent")
    func readAppSettingsKeysDefaultTrue() {
        #expect(AppSettingsBoolean.decode(nil, fallback: AppSettingsDefaults.reminderNotificationsEnabled) == true)
        #expect(AppSettingsBoolean.decode(nil, fallback: AppSettingsDefaults.saveVoiceTranscripts) == true)
    }

    @Test("every other boolean-shaped key defaults to false when absent, unlike the two readAppSettings keys")
    func otherBooleanKeysDefaultFalse() {
        // Mirrors the bare `value === '1'` reads in onboardingStorage.ts and
        // billing/storage.ts -- a real asymmetry with readAppSettings, not
        // an oversight.
        #expect(AppSettingsBoolean.decodeStrict(nil) == false) // onboarding_completed, onboarding_tutorial_completed, soft_upsell_dismissed, ...
    }

    @Test("app_settings key strings match the RN storage constants verbatim")
    func keyStringsMatchRNConstants() {
        #expect(AppSettingsKey.reminderNotificationsEnabled.rawValue == "reminder_notifications_enabled")
        #expect(AppSettingsKey.saveVoiceTranscripts.rawValue == "save_voice_transcripts")
        #expect(AppSettingsKey.onboardingCompleted.rawValue == "onboarding_completed")
        #expect(AppSettingsKey.onboardingStep.rawValue == "onboarding_step")
        #expect(AppSettingsKey.onboardingAudience.rawValue == "onboarding_audience")
        #expect(AppSettingsKey.onboardingTutorialCompleted.rawValue == "onboarding_tutorial_completed")
        #expect(AppSettingsKey.onboardingTutorialContactID.rawValue == "onboarding_tutorial_contact_id")
        #expect(AppSettingsKey.onboardingTutorialSeedVersion.rawValue == "onboarding_tutorial_seed_version")
        #expect(AppSettingsKey.softUpsellDismissed.rawValue == "soft_upsell_dismissed")
        #expect(AppSettingsKey.pendingAuthIntent.rawValue == "pending_auth_intent")
        #expect(AppSettingsKey.subscriptionSnapshot.rawValue == "subscription_snapshot")
        #expect(AppSettingsKey.localAnonymousUserID.rawValue == "local_anonymous_user_id")
    }

    /// Separate from the test above because this key mirrors nothing: the
    /// Expo client never showed the disclosure. The string is still pinned
    /// — renaming it would silently re-show the panel to every user who
    /// has already acknowledged it.
    @Test("the voice disclosure key string is stable across releases")
    func voiceDisclosureKeyStringIsStable() {
        #expect(AppSettingsKey.voiceDisclosureSeen.rawValue == "voice_disclosure_seen")
    }

    @Test("every app_settings key string is unique")
    func keyStringsAreUnique() {
        let rawValues = AppSettingsKey.allCases.map(\.rawValue)
        #expect(Set(rawValues).count == rawValues.count)
    }

    @Test("the onboarding tutorial seed version matches ONBOARDING_TUTORIAL_SEED_VERSION")
    func onboardingTutorialSeedVersionMatches() {
        #expect(AppSettingsKey.onboardingTutorialSeedVersionValue == "priya-v1")
    }

    @Test("DEFAULT_APP_SETTINGS mirrors both settings defaulting true")
    func defaultAppSettingsBothTrue() {
        #expect(AppSettingsDefaults.reminderNotificationsEnabled == true)
        #expect(AppSettingsDefaults.saveVoiceTranscripts == true)
    }
}
