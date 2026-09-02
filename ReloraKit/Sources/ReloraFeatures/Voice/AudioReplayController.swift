import SwiftUI
import Observation
import ReloraDesign
import ReloraServices

/// Bridges `ReloraServices.AudioReplayPlayer` (an actor) into `@Observable`
/// state a SwiftUI view can bind to, and maps its `AudioReplayState` onto
/// `ReloraDesign.ReloraAudioReplayButton.Style` — the one place that needs
/// to know about both, since `ReloraDesign` cannot import `ReloraServices`.
///
/// One instance per replay control — the review section's recording and
/// each memory row each own one, exactly as RN mints one `useAudioPlayer`
/// per `AudioReplayButton`. Constructs its own `AudioSessionController`
/// rather than sharing the recorder's: both wrap the same process-wide
/// `AVAudioSession`, so activation/deactivation still coordinate correctly
/// across instances — see `AudioReplayPlayer`'s doc comment.
@MainActor
@Observable
final class AudioReplayController {
    private(set) var buttonStyle: ReloraAudioReplayButton.Style = .idle

    @ObservationIgnored private let player: AudioReplayPlayer
    @ObservationIgnored private let url: URL
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    init(url: URL, sessionController: AudioSessionController = AudioSessionController()) {
        self.url = url
        self.player = AudioReplayPlayer(sessionController: sessionController)
    }

    /// Starts observing playback state. Call once, from `.task` — calling
    /// again while already observing is a no-op, matching how the review
    /// section and a memory row each own exactly one controller for the
    /// lifetime of their view.
    func start() {
        guard eventTask == nil else { return }
        let player = self.player
        eventTask = Task { [weak self] in
            for await state in await player.events() {
                self?.buttonStyle = state.style
            }
        }
    }

    /// Stops observing and tells the player to stop, for `.onDisappear` —
    /// playback should not keep going once the row that started it is gone.
    func stop() {
        eventTask?.cancel()
        eventTask = nil
        let player = self.player
        Task { await player.stop() }
    }

    func toggle() {
        let player = self.player
        let url = self.url
        Task { await player.toggle(url: url) }
    }
}

private extension AudioReplayState {
    var style: ReloraAudioReplayButton.Style {
        switch self {
        case .idle: return .idle
        case .playing: return .playing
        case .paused: return .paused
        case .failed: return .failed
        }
    }
}

// MARK: - Reusable pill

/// The replay control wired to a real player, shared by
/// `VoiceCaptureReviewSection` (the recording just captured) and
/// `ContactDetailView` (a memory's `audioLocalURI`) — the two surfaces
/// docs/milestone-notes.md names for M7's audio replay deliverable.
struct AudioReplayPill: View {
    let url: URL
    @State private var controller: AudioReplayController

    init(url: URL) {
        self.url = url
        _controller = State(initialValue: AudioReplayController(url: url))
    }

    var body: some View {
        ReloraAudioReplayButton(style: controller.buttonStyle) {
            controller.toggle()
        }
        .task { controller.start() }
        .onDisappear { controller.stop() }
    }
}
