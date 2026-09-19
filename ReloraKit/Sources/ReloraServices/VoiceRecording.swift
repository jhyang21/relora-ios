import Foundation

/// The recorder as the capture layer uses it.
///
/// `RecordingController` is the only conformer that ships. The protocol
/// exists for the other side: a test that has to drive the *order* of a
/// capture — a Stop that lands while the start is still in flight, a start
/// that throws, a recording too short to have written anything — cannot do
/// that through an `AVAudioEngine` and a microphone-permission dialog. It
/// can do it through a fake that answers these seven calls.
///
/// Deliberately the surface `VoiceCaptureViewModel` and
/// `LiveTranscribingVoicePipeline` already use, and nothing else. The
/// engine, the audio session, the tap and the file are
/// `RecordingController`'s own business and stay there.
///
/// Refines `Actor` rather than `Sendable` because every conformer has to
/// serialize this state somehow, and saying so here is what lets
/// `VoiceCaptureEnvironment` keep passing the recorder across isolation
/// boundaries as it always has.
public protocol VoiceRecording: Actor {
    func start(maxDuration: Duration) async throws
    /// Nil when there is nothing to hand back — see
    /// `RecordingController.stop()`.
    func stop() async -> RecordingArtifact?
    func cancel() async
    func levelStream() -> AsyncStream<Float>
    func elapsedTimeStream(interval: Duration) -> AsyncStream<Duration>
    func events() -> AsyncStream<RecordingEvent>
    func setPCMFrameHandler(_ handler: ((Data) -> Void)?)
}

extension RecordingController: VoiceRecording {}
