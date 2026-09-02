import Foundation
import Testing
@testable import ReloraServices

/// Covers only what `RecordingController` exposes as pure, AVAudioEngine-
/// free logic: frame-count→duration math, and the value types callers
/// pattern-match on. The engine-driven behavior (tap installation,
/// AAC encoding, auto-stop timing, interruption handling) needs a real
/// `AVAudioEngine`/`AVAudioSession` and so isn't unit-testable here —
/// that would need a running iOS simulator/device, not a place a plain
/// `swift test` can reach.
@Suite("RecordingController pure helpers")
struct RecordingControllerPureHelperTests {
    @Test("durationMS converts a whole second of frames at the recorded sample rate")
    func durationMSWholeSecond() {
        #expect(RecordingController.durationMS(framesWritten: 48_000, sampleRate: 48_000) == 1_000)
    }

    @Test("durationMS handles a fractional-second frame count")
    func durationMSFractionalSecond() {
        #expect(RecordingController.durationMS(framesWritten: 24_000, sampleRate: 48_000) == 500)
    }

    @Test("durationMS of zero frames is zero")
    func durationMSZeroFrames() {
        #expect(RecordingController.durationMS(framesWritten: 0, sampleRate: 48_000) == 0)
    }

    @Test("durationMS guards against a zero sample rate rather than dividing by zero")
    func durationMSGuardsZeroSampleRate() {
        #expect(RecordingController.durationMS(framesWritten: 48_000, sampleRate: 0) == 0)
    }
}

@Suite("RecordingArtifact / StopReason")
struct RecordingArtifactValueTypeTests {
    @Test("RecordingArtifact equality compares every field")
    func recordingArtifactEquality() {
        let url = URL(fileURLWithPath: "/tmp/one.m4a")
        let a = RecordingArtifact(fileURL: url, durationMS: 1_000, mimeType: "audio/m4a", stopReason: .manual)
        let b = RecordingArtifact(fileURL: url, durationMS: 1_000, mimeType: "audio/m4a", stopReason: .manual)
        let differentReason = RecordingArtifact(fileURL: url, durationMS: 1_000, mimeType: "audio/m4a", stopReason: .stoppedAtLimit)

        #expect(a == b)
        #expect(a != differentReason)
    }

    @Test("StopReason distinguishes manual, limit, and interruption")
    func stopReasonCases() {
        let reasons: [StopReason] = [.manual, .stoppedAtLimit, .interrupted]
        #expect(reasons[0] != reasons[1])
        #expect(reasons[1] != reasons[2])
        #expect(reasons[0] != reasons[2])
    }
}
