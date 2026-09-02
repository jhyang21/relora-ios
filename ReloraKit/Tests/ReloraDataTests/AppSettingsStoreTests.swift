import Testing
@testable import ReloraData
import ReloraCore
import GRDB

@Suite("AppSettingsStore")
struct AppSettingsStoreTests {
    @Test("getRawValue returns nil when no row exists")
    func getRawValueReturnsNilWhenAbsent() throws {
        let database = try Fixtures.makeDatabase()
        let store = AppSettingsStore(database: database)
        #expect(try store.getRawValue(.onboardingStep) == nil)
    }

    @Test("setRawValue writes and getRawValue reads it back")
    func setAndGetRawValueRoundTrips() throws {
        let database = try Fixtures.makeDatabase()
        let store = AppSettingsStore(database: database)
        try store.setRawValue(.onboardingStep, "2")
        #expect(try store.getRawValue(.onboardingStep) == "2")
    }

    @Test("setRawValue with a new value overwrites the previous one")
    func setRawValueOverwrites() throws {
        let database = try Fixtures.makeDatabase()
        let store = AppSettingsStore(database: database)
        try store.setRawValue(.onboardingStep, "1")
        try store.setRawValue(.onboardingStep, "3")
        #expect(try store.getRawValue(.onboardingStep) == "3")
    }

    @Test("setRawValue with nil deletes the row")
    func setRawValueNilDeletesRow() throws {
        let database = try Fixtures.makeDatabase()
        let store = AppSettingsStore(database: database)
        try store.setRawValue(.pendingAuthIntent, "{\"kind\":\"signIn\"}")
        #expect(try store.getRawValue(.pendingAuthIntent) != nil)

        try store.setRawValue(.pendingAuthIntent, nil)
        #expect(try store.getRawValue(.pendingAuthIntent) == nil)
    }

    @Test("reminderNotificationsEnabled defaults to true when absent")
    func reminderNotificationsEnabledDefaultsTrue() throws {
        let database = try Fixtures.makeDatabase()
        let store = AppSettingsStore(database: database)
        #expect(try store.reminderNotificationsEnabled() == true)
    }

    @Test("reminderNotificationsEnabled reflects an explicit false")
    func reminderNotificationsEnabledReflectsExplicitFalse() throws {
        let database = try Fixtures.makeDatabase()
        let store = AppSettingsStore(database: database)
        try store.setBoolean(.reminderNotificationsEnabled, false)
        #expect(try store.reminderNotificationsEnabled() == false)
    }

    @Test("saveVoiceTranscripts defaults to true when absent")
    func saveVoiceTranscriptsDefaultsTrue() throws {
        let database = try Fixtures.makeDatabase()
        let store = AppSettingsStore(database: database)
        #expect(try store.saveVoiceTranscripts() == true)
    }

    @Test("getBooleanStrict defaults to false when absent, unlike getBoolean's true default")
    func getBooleanStrictDefaultsFalse() throws {
        let database = try Fixtures.makeDatabase()
        let store = AppSettingsStore(database: database)
        #expect(try store.getBooleanStrict(.onboardingCompleted) == false)
        #expect(try store.getBooleanStrict(.softUpsellDismissed) == false)
    }

    @Test("getBooleanStrict reads back an explicit '1' as true")
    func getBooleanStrictReadsExplicitTrue() throws {
        let database = try Fixtures.makeDatabase()
        let store = AppSettingsStore(database: database)
        try store.setBoolean(.onboardingCompleted, true)
        #expect(try store.getBooleanStrict(.onboardingCompleted) == true)
    }

    @Test("getBoolean falls back to the given default when the stored value is neither '1' nor '0'")
    func getBooleanFallsBackOnGarbageValue() throws {
        let database = try Fixtures.makeDatabase()
        let store = AppSettingsStore(database: database)
        try store.setRawValue(.reminderNotificationsEnabled, "yes")
        #expect(try store.getBoolean(.reminderNotificationsEnabled, fallback: true) == true)
        #expect(try store.getBoolean(.reminderNotificationsEnabled, fallback: false) == false)
    }
}
