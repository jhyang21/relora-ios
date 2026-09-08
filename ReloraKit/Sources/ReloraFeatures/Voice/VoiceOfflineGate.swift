import Foundation

/// Whether a capture may start with no network.
///
/// ## Ordering
///
/// Third of four: disclosure → quota → offline → microphone. It runs after
/// `VoiceQuotaGate.decide` because a user who is out of notes should be told
/// that, not told to find Wi‑Fi and then told that. It runs before the
/// microphone because the whole point is to refuse before the recording, not
/// after it.
///
/// ## Why this exists again
///
/// M6 shipped with no offline gate on purpose (`docs/milestone-notes.md`):
/// a signed-in user's audio is kept on failure and Retry re-sends it, so
/// recording offline was meant to read as "capture the thought now, send it
/// later". Andrew's 2026-09-07 QA pass reversed that. Nothing on screen said
/// so, and the only way to find out was to talk for a minute and then watch
/// it fail. Being told first is worth more than a fallback nobody knew about.
///
/// Guests are untouched: a local guest writes the note by hand and never
/// makes a request, so there is nothing for a connection to be needed for.
public enum VoiceOfflineGate {
    public enum Decision: Equatable, Sendable {
        /// Show the offline panel and start nothing.
        case block
        /// Record.
        case proceed
    }

    public static func decide(isOnline: Bool, allowsLocalGuestFallback: Bool) -> Decision {
        (isOnline || allowsLocalGuestFallback) ? .proceed : .block
    }
}
