import Foundation
import os
import ReloraServices

/// The id the sync engine uploads under, readable from anywhere.
///
/// `SyncEngine` asks for its user id through a synchronous `@Sendable` closure,
/// and the truth lives on `IdentityController`, which is `@MainActor`. A
/// `@MainActor` read is not available synchronously from an actor's context, so
/// the value is mirrored here instead — one lock around one optional string.
///
/// It holds `Identity.syncUserID`, not `ownerUserID`: only a real account syncs.
/// A local guest and an anonymous session own local rows but are deliberately
/// never uploaded (see `Identity.syncUserID`).
public final class SyncIdentityBox: Sendable {
    private let state = OSAllocatedUnfairLock<String?>(initialState: nil)

    public init() {}

    public var syncUserID: String? {
        state.withLock { $0 }
    }

    public func set(_ userID: String?) {
        state.withLock { $0 = userID }
    }

    public func update(from identity: Identity) {
        set(identity.syncUserID)
    }
}
