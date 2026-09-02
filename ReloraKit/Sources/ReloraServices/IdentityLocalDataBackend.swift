import Foundation
import ReloraCore
import ReloraData

/// Wraps a real `GuestMigration` (ReloraData) to conform to
/// `OwnershipMigrating`, translating between its RN-shaped
/// `IdentityKind`/`MigrationOutcome` and this module's `Identity`/
/// `OwnershipMigrationOutcome`. The composition root (wherever
/// `IdentityController` is constructed — outside this milestone's scope)
/// builds one of these around the app's `AppDatabase` and passes it in.
///
/// A wrapper struct rather than `extension GuestMigration:
/// OwnershipMigrating` on purpose: `GuestMigration.runMigration` already
/// has a 5-parameter form with defaulted `delays`/`now` (for
/// `GuestMigrationTests` to inject fast retry timing) — an extension
/// witnessing the protocol's 3-parameter requirement under the same name
/// would sit right next to it as a second, easily-confused overload with
/// an overlapping call shape. A distinct type keeps the two call sites
/// unambiguous.
public struct OwnershipMigrationAdapter: OwnershipMigrating {
    private let migration: GuestMigration

    public init(_ migration: GuestMigration) {
        self.migration = migration
    }

    public func hasPending() throws -> Bool {
        try migration.hasPending()
    }

    public func runMigration(fromUserID: String, toUserID: String, source: String) async -> OwnershipMigrationOutcome {
        OwnershipMigrationOutcome(await migration.runMigration(fromUserID: fromUserID, toUserID: toUserID, source: source))
    }

    public func resumePendingMigrationIfAny(
        currentIdentity: Identity, source: String
    ) async -> (outcome: OwnershipMigrationOutcome, fromUserID: String?, toUserID: String?) {
        let result = await migration.resumePendingMigrationIfAny(
            toUserID: currentIdentity.syncUserID, identityKind: currentIdentity.kind, source: source
        )
        return (OwnershipMigrationOutcome(result.outcome), result.fromUserID, result.toUserID)
    }

    public func clearAllLocalData() throws {
        try migration.clearAllLocalData()
    }
}

private extension OwnershipMigrationOutcome {
    init(_ outcome: MigrationOutcome) {
        switch outcome {
        case .succeeded: self = .succeeded
        case .deferred: self = .deferred
        case .skipped: self = .skipped
        }
    }
}

/// Wraps a real `AppSettingsStore` (ReloraData) to conform to
/// `LocalGuestIDStore`, fixed to the one key `IdentityController` reads
/// and writes.
public struct AppSettingsGuestIDStore: LocalGuestIDStore {
    private let settings: AppSettingsStore

    public init(database: AppDatabase) {
        self.settings = AppSettingsStore(database: database)
    }

    public func read() throws -> String? {
        try settings.getRawValue(.localAnonymousUserID)
    }

    public func write(_ userID: String?) throws {
        try settings.setRawValue(.localAnonymousUserID, userID)
    }
}
