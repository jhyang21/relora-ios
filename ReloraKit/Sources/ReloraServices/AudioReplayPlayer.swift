import Foundation
import AVFoundation

/// Whether a replay control is idle, playing, paused, or failed. Drives
/// `ReloraDesign.ReloraAudioReplayButton`'s icon and label — that type has
/// its own `Style` enum rather than importing this one, since ReloraDesign
/// does not (and should not) depend on ReloraServices; the mapping between
/// the two lives in ReloraFeatures, which depends on both.
public enum AudioReplayState: Sendable, Equatable {
    case idle
    case playing
    case paused
    case failed
}

/// Plays back one locally recorded voice note through `AVAudioPlayer`,
/// coordinating with `AudioSessionController` so replay and recording never
/// fight over the audio session. Ports the playback half of RN's
/// `AudioReplayButton.tsx` (an `expo-audio` player) — the visual half is
/// `ReloraDesign.ReloraAudioReplayButton`, and the two are wired together by
/// `ReloraFeatures.AudioReplayController`.
///
/// One instance per replay control. The voice review section's recording
/// and each contact's memory rows each mint their own, so two rows hold
/// independent playing/paused state exactly as two separate RN
/// `AudioReplayButton` instances would — and each activates/deactivates the
/// *same* process-wide `AVAudioSession` underneath, which is what actually
/// keeps playback and recording from fighting, not a shared instance.
public actor AudioReplayPlayer {
    private let sessionController: AudioSessionController
    private var player: AVAudioPlayer?
    private var currentURL: URL?
    private var delegateBridge: PlaybackDelegateBridge?
    private var stateContinuation: AsyncStream<AudioReplayState>.Continuation?

    public init(sessionController: AudioSessionController) {
        self.sessionController = sessionController
    }

    /// One continuation per call, same shape as `RecordingController`'s
    /// streams — call once, before `toggle(url:)`.
    public func events() -> AsyncStream<AudioReplayState> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudioReplayState.self)
        stateContinuation = continuation
        return stream
    }

    /// Plays if idle or paused, pauses if already playing this URL.
    public func toggle(url: URL) async {
        if let player, player.isPlaying, currentURL == url {
            await pause()
            return
        }
        await play(url: url)
    }

    private func play(url: URL) async {
        do {
            if currentURL != url || player == nil {
                let newPlayer = try AVAudioPlayer(contentsOf: url)
                let bridge = PlaybackDelegateBridge(owner: self)
                newPlayer.delegate = bridge
                delegateBridge = bridge
                player = newPlayer
                currentURL = url
            }
            try await sessionController.activate()
            guard player?.play() == true else {
                stateContinuation?.yield(.failed)
                return
            }
            stateContinuation?.yield(.playing)
        } catch {
            stateContinuation?.yield(.failed)
        }
    }

    private func pause() async {
        player?.pause()
        stateContinuation?.yield(.paused)
        await sessionController.deactivate()
    }

    fileprivate func handleFinished() async {
        player?.currentTime = 0
        stateContinuation?.yield(.idle)
        await sessionController.deactivate()
    }

    /// Stops and resets to the start, for a caller leaving the screen
    /// (`.onDisappear`) — playback should not keep going once the row that
    /// started it is gone.
    public func stop() async {
        player?.stop()
        player?.currentTime = 0
        stateContinuation?.yield(.idle)
        await sessionController.deactivate()
    }
}

/// Bridges `AVAudioPlayerDelegate`'s finish callback (which AVFoundation
/// can call on any thread) into the actor. The same shape
/// `RealtimeTranscriber`'s `OpenSignal` uses for `URLSessionWebSocketDelegate`
/// — an `NSObject` outside the actor, `weak`-holding it so a finished
/// player does not keep its bridge (and the actor it points back to) alive
/// past the view that owns it.
private final class PlaybackDelegateBridge: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private weak var owner: AudioReplayPlayer?

    init(owner: AudioReplayPlayer) {
        self.owner = owner
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard let owner else { return }
        Task { await owner.handleFinished() }
    }
}
