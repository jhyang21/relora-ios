import Foundation
import ReloraCore
import ReloraData

/// Typed reads and writes over the `app_settings` key behind the voice
/// disclosure: consent to send voice notes to OpenAI.
///
/// Consent is versioned. `readSeen()` is true only when the stored version
/// equals `currentVersion`, so bumping the constant asks everyone again.
/// Version 2 is the first panel that names OpenAI; the 2.4.0 boolean
/// (`voiceDisclosureSeen`) is never read, so people who agreed to the
/// unnamed version see the new one before their next recording.
///
/// Reads go through `try?`, so a failed read and an absent row both answer
/// false. That is the safe direction: the cost of asking again is a tap,
/// and the cost of skipping it is sending audio without consent.
///
/// Deliberately not `@MainActor`: the composer's view model builds one in
/// `init` before `self` exists, and a main-actor type could not be
/// constructed there.
public struct VoiceDisclosureStorage: Sendable {
    public static let currentVersion = "2"

    private let settings: AppSettingsStore

    public init(database: AppDatabase) {
        self.settings = AppSettingsStore(database: database)
    }

    public func readSeen() -> Bool {
        (try? settings.getRawValue(.voiceDisclosureVersion)) == Self.currentVersion
    }

    public func writeSeen() {
        try? settings.setRawValue(.voiceDisclosureVersion, Self.currentVersion)
    }

    /// Withdraws consent: the next recording shows the disclosure again.
    public func clear() {
        try? settings.setRawValue(.voiceDisclosureVersion, nil)
    }
}
