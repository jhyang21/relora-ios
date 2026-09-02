import Foundation
import GRDB
import ReloraCore

/// Key/value reads and writes for the `app_settings` table, ported from
/// `readAppSetting`/`writeAppSetting` (apps/mobile/src/features/billing/storage.ts)
/// and the boolean-specific helpers in apps/mobile/src/features/settings/appPreferences.ts.
/// Every column is TEXT — `AppSettingsKey` (ReloraCore) is the single source
/// of truth for which key strings exist, and `AppSettingsBoolean`
/// (ReloraCore) carries the two different boolean-decoding rules the RN app
/// actually uses. See that type's doc comment for why there are two.
public struct AppSettingsStore: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// The raw stored string for `key`, or `nil` if no row exists.
    public func getRawValue(_ key: AppSettingsKey) throws -> String? {
        try database.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_settings WHERE key = ?", arguments: [key.rawValue])
        }
    }

    /// Writes `value` for `key`; a `nil` value deletes the row, matching
    /// `writeAppSetting(key, null)` in storage.ts (used there to clear
    /// optional JSON-shaped settings like the pending auth intent).
    public func setRawValue(_ key: AppSettingsKey, _ value: String?) throws {
        try database.write { db in
            if let value {
                try db.execute(
                    sql: "INSERT INTO app_settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [key.rawValue, value]
                )
            } else {
                try db.execute(sql: "DELETE FROM app_settings WHERE key = ?", arguments: [key.rawValue])
            }
        }
    }

    /// Decodes a boolean-shaped setting using `AppSettingsBoolean.decode`,
    /// applying `fallback` when the row is absent or holds neither `"1"` nor
    /// `"0"`. Use for `.reminderNotificationsEnabled` / `.saveVoiceTranscripts`.
    public func getBoolean(_ key: AppSettingsKey, fallback: Bool) throws -> Bool {
        AppSettingsBoolean.decode(try getRawValue(key), fallback: fallback)
    }

    /// Decodes a boolean-shaped setting using the bare `value === '1'` rule
    /// every other boolean key in the RN app uses: absent, or anything other
    /// than exactly `"1"`, reads as `false`.
    public func getBooleanStrict(_ key: AppSettingsKey) throws -> Bool {
        AppSettingsBoolean.decodeStrict(try getRawValue(key))
    }

    /// Encodes and writes a boolean-shaped setting as the literal `"1"`/`"0"`,
    /// matching every RN writer.
    public func setBoolean(_ key: AppSettingsKey, _ value: Bool) throws {
        try setRawValue(key, AppSettingsBoolean.encode(value))
    }

    /// `reminder_notifications_enabled`, defaulting to `true` when absent —
    /// one of the two keys `DEFAULT_APP_SETTINGS` in appPreferences.ts
    /// defaults true rather than false.
    public func reminderNotificationsEnabled() throws -> Bool {
        try getBoolean(.reminderNotificationsEnabled, fallback: AppSettingsDefaults.reminderNotificationsEnabled)
    }

    /// `save_voice_transcripts`, defaulting to `true` when absent — the other
    /// of the two default-true keys.
    public func saveVoiceTranscripts() throws -> Bool {
        try getBoolean(.saveVoiceTranscripts, fallback: AppSettingsDefaults.saveVoiceTranscripts)
    }
}
