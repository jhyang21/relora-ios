import Foundation
import AVFoundation

/// Owns the process-wide `AVAudioSession` configuration for voice
/// capture: category, activation, microphone permission, and the
/// interruption/route-change notifications every recorder needs to react
/// to. `RecordingController` composes this rather than touching
/// `AVAudioSession` itself, so activation/permission/interruption
/// handling has exactly one implementation shared by batch and realtime
/// capture.
///
/// RN's counterpart is `setAudioModeAsync({ allowsRecording, playsInSilentMode })`
/// in apps/mobile/src/features/voice/voiceService.ts, which only ever
/// toggles between a minimal playback-only mode and a minimal recording
/// mode via Expo's abstraction. `AVAudioSession` gives direct control, so
/// this configures deliberately rather than mirroring RN's two-mode
/// toggle:
///
/// - **Category `.playAndRecord`**: the only category that allows
///   simultaneous mic input and (later) transcript/review playback.
/// - **Mode `.spokenAudio`**: Apple's guidance for apps that primarily
///   record speech for later transcription/playback (voice memo / podcast
///   style capture) — it selects EQ and AGC tuning for a single spoken
///   voice. `.voiceChat` is the wrong choice here: it enables telephony
///   echo cancellation tuned for two-way calls, which degrades a
///   single-speaker recording. `.default` and `.measurement` are both
///   flat/generic and skip the speech tuning `.spokenAudio` exists for.
/// - **Options `[.defaultToSpeaker, .allowBluetooth]`**: `.defaultToSpeaker`
///   keeps output on the built-in speaker instead of the earpiece
///   (matches the `voiceService.ts` comment about earpiece-only replay
///   being "nearly inaudible"); `.allowBluetooth` lets a paired
///   hands-free accessory's microphone be selected as the input route.
public actor AudioSessionController {
    public enum ActivationError: Error, Sendable, Equatable {
        case categoryConfigurationFailed(String)
        case activationFailed(String)
    }

    /// Mirrors `AVAudioSession.RouteChangeReason`'s cases this app acts
    /// on distinctly, collapsing the rest into `.other` so callers don't
    /// need to import AVFoundation just to switch on this.
    public enum RouteChangeReason: Sendable, Equatable {
        case oldDeviceUnavailable
        case newDeviceAvailable
        case categoryChange
        case override
        case other(rawValue: Int)

        init(_ reason: AVAudioSession.RouteChangeReason) {
            switch reason {
            case .oldDeviceUnavailable: self = .oldDeviceUnavailable
            case .newDeviceAvailable: self = .newDeviceAvailable
            case .categoryChange: self = .categoryChange
            case .override: self = .override
            default: self = .other(rawValue: Int(reason.rawValue))
            }
        }
    }

    public enum SessionEvent: Sendable, Equatable {
        case interruptionBegan
        case interruptionEnded(shouldResume: Bool)
        case routeChanged(reason: RouteChangeReason)
    }

    private let session = AVAudioSession.sharedInstance()
    private var eventContinuation: AsyncStream<SessionEvent>.Continuation?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    public init() {}

    deinit {
        // Actor `deinit` runs after every isolated reference to `self` is
        // gone, so touching these actor-isolated stored properties here
        // directly (no `await`) is exactly what Swift's actor model
        // permits deinit to do.
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
    }

    /// One event stream for interruptions and route changes. Starts the
    /// underlying `NotificationCenter` observers on first call.
    public func events() -> AsyncStream<SessionEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: SessionEvent.self)
        eventContinuation = continuation
        startObservingIfNeeded()
        return stream
    }

    /// Configures the category/mode/options above and activates the
    /// session. Safe to call repeatedly (e.g. once per recording) —
    /// `AVAudioSession` no-ops a redundant `setCategory`/`setActive(true)`.
    public func activate() throws {
        do {
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
        } catch {
            throw ActivationError.categoryConfigurationFailed(String(describing: error))
        }
        do {
            try session.setActive(true, options: [])
        } catch {
            throw ActivationError.activationFailed(String(describing: error))
        }
        startObservingIfNeeded()
    }

    /// Deactivates the session, notifying other apps they can reclaim
    /// audio focus. Best-effort: a failure here (e.g. another route
    /// change racing this call) is not actionable by the caller, so it is
    /// swallowed rather than thrown — mirroring `restoreAudioMode`'s
    /// `catch { console.warn(...) }` in voiceService.ts, which never lets
    /// a session-restore failure surface as a capture error.
    public func deactivate() {
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Requests microphone permission via `AVAudioApplication` (iOS 17),
    /// the replacement for the deprecated `AVAudioSession.requestRecordPermission`.
    /// Returns immediately for an already-decided permission; only
    /// prompts when `.undetermined`.
    public static func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    // MARK: - Notification bridging

    private func startObservingIfNeeded() {
        guard interruptionObserver == nil else { return }

        // NotificationCenter's callback runs off the actor's executor, so
        // it cannot touch `self.eventContinuation` directly — Swift 6
        // would reject that as an actor-isolation violation regardless of
        // when the block actually happens to run. Hopping back in via
        // `Task { await self... }` is the standard, safe bridge.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            Task { await self.handleInterruptionNotification(notification) }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            Task { await self.handleRouteChangeNotification(notification) }
        }
    }

    private func handleInterruptionNotification(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let rawType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }

        switch type {
        case .began:
            eventContinuation?.yield(.interruptionBegan)
        case .ended:
            let rawOptions = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            eventContinuation?.yield(.interruptionEnded(shouldResume: shouldResume))
        @unknown default:
            return
        }
    }

    private func handleRouteChangeNotification(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let rawReason = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        else { return }
        eventContinuation?.yield(.routeChanged(reason: RouteChangeReason(reason)))
    }
}
