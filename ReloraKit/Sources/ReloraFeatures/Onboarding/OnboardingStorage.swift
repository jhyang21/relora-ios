import Foundation
import ReloraCore
import ReloraData

/// Typed reads and writes over the onboarding `app_settings` keys. Ports
/// `onboardingStorage.ts`'s six functions as one type, backed by
/// `AppSettingsStore` (ReloraData) rather than the raw `db.getFirstAsync`
/// calls that file makes directly.
///
/// Every read below uses an explicit `do`/`catch` around
/// `AppSettingsStore.getRawValue`, never a chained `try?`/`??` — a `try?` on
/// a `throws -> String?` function collapses "the read failed" and "the row
/// is absent" into the same `nil`, and an early edit in this milestone
/// (`NotificationReconciler`, see the M10 report) miscompiled exactly that
/// shape once. Explicit `do`/`catch` keeps the two cases textually distinct
/// even though this type currently treats them the same way (both read as
/// "nothing stored").
public struct OnboardingStorage: Sendable {
    private let settings: AppSettingsStore

    public init(database: AppDatabase) {
        self.settings = AppSettingsStore(database: database)
    }

    // MARK: Step

    /// Mirrors `readOnboardingStep`: absent, or anything that does not parse
    /// as an integer, reads as step 0.
    public func readStep() -> Int {
        let raw: String?
        do {
            raw = try settings.getRawValue(.onboardingStep)
        } catch {
            raw = nil
        }
        guard let raw, let parsed = Int(raw) else { return 0 }
        return parsed
    }

    public func writeStep(_ step: Int) {
        try? settings.setRawValue(.onboardingStep, String(step))
    }

    // MARK: Personalization

    /// Mirrors `readOnboardingPersonalization`: a stored value that is not
    /// valid JSON, or not a JSON array, reads as no selections rather than
    /// throwing — the same "parse failure is empty, not an error" rule
    /// `parseStoredStringArray` applies.
    public func readAudience() -> [String] {
        let raw: String?
        do {
            raw = try settings.getRawValue(.onboardingAudience)
        } catch {
            raw = nil
        }
        guard let raw, let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    public func writeAudience(_ audience: [String]) {
        guard let data = try? JSONEncoder().encode(audience), let json = String(data: data, encoding: .utf8) else { return }
        try? settings.setRawValue(.onboardingAudience, json)
    }

    // MARK: Tutorial state

    public struct TutorialState: Equatable, Sendable {
        public var completed: Bool
        public var contactID: String?
        /// Which sample persona `contactID` belongs to. `nil` covers both
        /// "never seeded" and "seeded before this key existed" — both read
        /// as "no example yet" the same way `onboardingStorage.ts`'s `null`
        /// does.
        public var seedVersion: String?

        public init(completed: Bool, contactID: String?, seedVersion: String?) {
            self.completed = completed
            self.contactID = contactID
            self.seedVersion = seedVersion
        }

        public static let empty = TutorialState(completed: false, contactID: nil, seedVersion: nil)

        /// Mirrors `hasCurrentTutorialExample`: a stored example only counts
        /// if it was seeded by the persona this build ships. A device
        /// holding an older persona's contact reads as "no example yet"
        /// rather than reusing a stale one.
        public var isCurrent: Bool {
            completed && seedVersion == AppSettingsKey.onboardingTutorialSeedVersionValue
        }
    }

    public func readTutorialState() -> TutorialState {
        let completed = (try? settings.getBooleanStrict(.onboardingTutorialCompleted)) ?? false

        let contactIDRaw: String?
        do {
            contactIDRaw = try settings.getRawValue(.onboardingTutorialContactID)
        } catch {
            contactIDRaw = nil
        }

        let seedVersionRaw: String?
        do {
            seedVersionRaw = try settings.getRawValue(.onboardingTutorialSeedVersion)
        } catch {
            seedVersionRaw = nil
        }

        return TutorialState(
            completed: completed,
            contactID: contactIDRaw?.trimmingCharacters(in: .whitespaces).isEmpty == false ? contactIDRaw : nil,
            seedVersion: seedVersionRaw?.trimmingCharacters(in: .whitespaces).isEmpty == false ? seedVersionRaw : nil
        )
    }

    public func writeTutorialState(_ state: TutorialState) {
        try? settings.setBoolean(.onboardingTutorialCompleted, state.completed)
        try? settings.setRawValue(.onboardingTutorialContactID, state.contactID)
        try? settings.setRawValue(.onboardingTutorialSeedVersion, state.seedVersion)
    }

    /// The seeded tutorial reminder's own row id — the mechanism
    /// `NotificationReconciler` (ReloraServices) checks to keep that one
    /// reminder off the OS schedule. See `TutorialSeed.swift`.
    public func readTutorialReminderID() -> String? {
        do {
            return try settings.getRawValue(.onboardingTutorialReminderID)
        } catch {
            return nil
        }
    }

    public func writeTutorialReminderID(_ reminderID: String?) {
        try? settings.setRawValue(.onboardingTutorialReminderID, reminderID)
    }

    // MARK: Completion

    public func readCompleted() -> Bool {
        (try? settings.getBooleanStrict(.onboardingCompleted)) ?? false
    }

    public func writeCompleted(_ completed: Bool) {
        try? settings.setBoolean(.onboardingCompleted, completed)
    }
}
