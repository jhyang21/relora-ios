import Foundation

/// Whether the composer opens on the "How voice notes work" panel or goes
/// straight to the meter.
///
/// ## Ordering
///
/// The disclosure runs **before** `VoiceQuotaGate.decide` and before the
/// microphone. Someone recording for the first time is told what happens to
/// their audio before any of it happens — not after a paywall has already
/// judged them, and not after iOS has already asked for the mic. Continue is
/// the only thing that writes the flag: a swipe or the X is a dismissal, not
/// consent, so the panel comes back on the next attempt.
public enum VoiceDisclosureGate {
    public enum Decision: Equatable, Sendable {
        /// Show the panel and hold everything else.
        case disclose
        /// Already acknowledged. Gate, then record.
        case proceed
    }

    public static func decide(hasSeenDisclosure: Bool) -> Decision {
        hasSeenDisclosure ? .proceed : .disclose
    }
}
