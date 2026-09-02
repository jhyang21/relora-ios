import Foundation

/// What the recorder is doing right now, as the screen describes it. Ports
/// `VoiceRecordingState` in `useVoiceRecorder.ts`.
public enum VoiceRecordingState: String, Equatable, Sendable {
    /// Recording, nothing loud enough to call speech yet.
    case listening
    /// Speech heard. Sticky once past `VoiceMeter.minRecording`: a pause does
    /// not put the meter back to `listening`, because a screen that flickers
    /// between two words is reporting the microphone, not the conversation.
    /// Inside the first two and a half seconds it does fall back, which is
    /// RN's behavior and matters little — nobody has said a whole word yet.
    case speaking
    /// Stop was asked for and the file is being closed.
    case finishing
}

/// The input meter, and the two decisions it drives.
///
/// Ports the batch metering loop in `useVoiceRecorder.ts` — level smoothing,
/// the speech/silence test, and the silence auto-stop. A value type with one
/// `tick` method rather than a timer of its own, so every rule below can be
/// tested by calling it with a sequence of samples.
///
/// ## Two scales
///
/// `RecordingController.levelStream()` emits **linear RMS** (0…1) from
/// `PCM16.computeRMS`. RN's constants are on a different scale entirely:
/// `expo-audio` reports dBFS, which `normalizeMetering` maps to 0…1 as
/// `(dB + 60) / 60`. Applying `SILENCE_THRESHOLD = 0.11` straight to linear
/// RMS would put the speech gate at a level nothing short of shouting reaches
/// — RMS 0.11 is roughly -19 dBFS, where the ported threshold means -53 dBFS.
/// So `normalize` converts first, and the ported constants keep their meaning.
public struct VoiceMeter: Equatable, Sendable {
    /// Above this, on the normalized dB scale, counts as speech. RN's
    /// `SILENCE_THRESHOLD`.
    public static let silenceThreshold: Float = 0.11
    /// Silence this long ends the recording. RN's `SILENCE_WINDOW_MS`.
    public static let silenceWindow = Duration.seconds(10)
    /// No auto-stop before this — someone gathering their thoughts is not
    /// finished. RN's `MIN_RECORDING_MS`.
    public static let minRecording = Duration.milliseconds(2500)
    /// How often `tick` should be called. RN's `METER_POLL_MS`.
    public static let pollInterval = Duration.milliseconds(120)
    /// How many samples the on-screen meter keeps. At 120ms a tick, about
    /// five seconds of history.
    public static let historyLength = 42

    /// The smoothed level, 0…1, on RN's normalized dB scale.
    public private(set) var level: Float = 0
    /// Recent levels, oldest first. What the meter draws: a record of what was
    /// actually heard, not a decoration that moves on its own.
    public private(set) var history: [Float] = []
    public private(set) var state: VoiceRecordingState = .listening

    /// Elapsed time at the last sample loud enough to be speech.
    private var lastSpeechAt: Duration = .zero

    public init() {}

    /// What a tick decided.
    public enum Outcome: Equatable, Sendable {
        case keepRecording
        /// Ten seconds of silence after the minimum. RN's `stop('auto')`.
        case stopForSilence
    }

    /// Advances the meter one poll interval.
    ///
    /// - Parameters:
    ///   - rms: the newest linear RMS sample, or nil when the recorder
    ///     reported no level this interval. Nil is not silence — RN's
    ///     `hasMetering` guard keeps a missing reading from either counting as
    ///     speech or arming the auto-stop, because a recorder that stopped
    ///     answering is not a room that went quiet.
    ///   - elapsed: how long the recording has been running.
    public mutating func tick(rms: Float?, elapsed: Duration) -> Outcome {
        let sample = rms.map { Self.normalize(rms: $0) }
        level = Self.blend(current: level, next: sample)
        appendHistory(level)

        // The gate reads the raw sample, not the smoothed level: smoothing
        // exists to keep the drawing calm, and letting it decide what counts
        // as speech would delay the answer by several ticks in both
        // directions. RN tests `nextLevel` for the same reason.
        if let sample, sample > Self.silenceThreshold {
            lastSpeechAt = elapsed
            state = .speaking
            return .keepRecording
        }

        if elapsed < Self.minRecording {
            state = .listening
            return .keepRecording
        }

        if sample != nil, elapsed - lastSpeechAt > Self.silenceWindow {
            return .stopForSilence
        }

        return .keepRecording
    }

    /// Stop was asked for. The meter stops moving and says so.
    public mutating func finish() {
        state = .finishing
        level = 0
    }

    private mutating func appendHistory(_ value: Float) {
        history.append(value)
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
    }

    // MARK: Pure math

    /// Linear RMS to RN's normalized dB scale. Ports `normalizeMetering`,
    /// with the RMS-to-dBFS conversion `expo-audio` does for us on the RN side.
    ///
    /// The floor on the logarithm matters: RMS is exactly zero on a digital
    /// silence, and `log10(0)` is negative infinity, which would poison the
    /// clamp and every blend after it.
    public static func normalize(rms: Float) -> Float {
        let decibels = 20 * log10(max(rms, 1e-7))
        return min(max((decibels + 60) / 60, 0), 1)
    }

    /// Ports `blendMeterLevel`: a weighted average toward the new sample, or a
    /// decay when there is no sample. The dead band keeps the meter from
    /// redrawing over changes too small to see.
    public static func blend(current: Float, next: Float?) -> Float {
        let blended = next.map { current * 0.55 + $0 * 0.45 } ?? current * 0.7
        return abs(blended - current) < 0.005 ? current : blended
    }
}
