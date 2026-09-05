import Foundation
import ReloraCore
import ReloraData

/// Typed reads and writes over the one `app_settings` key behind the
/// first-recording disclosure, shaped exactly like
/// `OnboardingStorage.readCompleted`/`writeCompleted`.
///
/// No RN counterpart: the Expo client never showed this screen, so there is
/// no `voiceDisclosureStorage.ts` to port. `getBooleanStrict` through a
/// `try?` means a failed read and an absent row both answer false — the
/// safe direction for a disclosure, because the cost of showing it a second
/// time is a tap and the cost of skipping it is showing none at all.
///
/// Deliberately not `@MainActor`: the composer's view model builds one in
/// `init` before `self` exists, and a main-actor type could not be
/// constructed there.
public struct VoiceDisclosureStorage: Sendable {
    private let settings: AppSettingsStore

    public init(database: AppDatabase) {
        self.settings = AppSettingsStore(database: database)
    }

    public func readSeen() -> Bool {
        (try? settings.getBooleanStrict(.voiceDisclosureSeen)) ?? false
    }

    public func writeSeen(_ seen: Bool = true) {
        try? settings.setBoolean(.voiceDisclosureSeen, seen)
    }
}
