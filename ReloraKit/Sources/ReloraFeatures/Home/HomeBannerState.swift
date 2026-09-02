import Foundation
import ReloraSync

/// The one status banner Home may show.
public enum HomeBanner: Equatable, Sendable {
    /// A guest → account migration is stranded and can be retried.
    case migrationPending
    /// No network. Everything still works; nothing is leaving the device.
    case offline
    /// A sync attempt failed while online.
    case syncFailed

    public var title: String {
        switch self {
        case .migrationPending: return "Still moving your notes"
        case .offline: return "You are offline"
        case .syncFailed: return "Sync failed"
        }
    }

    public var message: String {
        switch self {
        case .migrationPending:
            return "Your earlier notes are being moved to your account."
        case .offline:
            return "Your notes are saved on this device and will sync when you are back."
        case .syncFailed:
            return "Your notes are safe on this device. Relora will try again."
        }
    }

    public var tone: HomeBannerTone {
        switch self {
        case .offline: return .system
        case .migrationPending, .syncFailed: return .warning
        }
    }

    /// Only the two failures offer a retry. "You are offline" with a Retry
    /// button invites a user to fix something they cannot fix.
    public var isRetryable: Bool {
        switch self {
        case .offline: return false
        case .migrationPending, .syncFailed: return true
        }
    }
}

/// Mirrors `ReloraBanner.Tone` without ReloraFeatures leaking a design type into
/// its pure model layer.
public enum HomeBannerTone: Equatable, Sendable {
    case system
    case warning
}

public enum HomeBannerState {
    /// Picks the single banner to show.
    ///
    /// Precedence, ported from `HomeScreen.tsx`: **migration pending > offline >
    /// sync failed**, and never more than one. Stacking them would push the
    /// content down a whole card's height to say three versions of the same
    /// thing, and the order is the order of what a user can act on: a stranded
    /// migration is the only one with a fix behind it, and a sync failure while
    /// offline is not news.
    public static func banner(
        ownershipMigrationPending: Bool,
        isOnline: Bool,
        syncStatus: SyncStatus
    ) -> HomeBanner? {
        if ownershipMigrationPending {
            return .migrationPending
        }
        if !isOnline {
            return .offline
        }
        if syncStatus == .failed {
            return .syncFailed
        }
        return nil
    }
}
