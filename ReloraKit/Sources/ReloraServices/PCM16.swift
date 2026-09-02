import Foundation
import AVFoundation

/// Pure PCM16 math ported from
/// apps/mobile/src/features/voice/realtime/audioTransform.ts. Resampling
/// is intentionally NOT ported here — `resampleLinearPcm` in that file
/// exists only because a JS `AudioBuffer` has no built-in resampler;
/// `AVAudioConverter` (used by `RecordingController`) is the correct,
/// higher-quality way to do this on iOS, so hand-rolling linear
/// interpolation here would be a downgrade, not a port. What *is* ported
/// verbatim is the sample-level math: the asymmetric float→Int16 scaling
/// and the RMS meter formula, both usable independent of AVFoundation so
/// they can be covered by golden-vector tests mirroring
/// audioTransform.ts's cases without any audio hardware or engine.
public enum PCM16 {
    private static func clamp(_ value: Float) -> Float {
        min(1, max(-1, value))
    }

    /// Mirrors `float32ToPcm16`. Deliberately asymmetric: negative values
    /// scale by 0x8000 (32768) and non-negative values scale by 0x7fff
    /// (32767), matching Int16's asymmetric range instead of clipping the
    /// negative side one unit short.
    public static func convert(_ samples: [Float]) -> [Int16] {
        samples.map { sample in
            let value = clamp(sample)
            return value < 0
                ? Int16((value * 0x8000).rounded())
                : Int16((value * 0x7fff).rounded())
        }
    }

    /// Mirrors `computeRmsLevel`: root-mean-square of the clamped
    /// samples, capped at 1. Returns 0 for an empty buffer, matching RN's
    /// explicit `samples.length === 0` guard.
    public static func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { partial, sample in
            let value = clamp(sample)
            return partial + value * value
        }
        return min(1, (sumSquares / Float(samples.count)).squareRoot())
    }
}

extension AVAudioPCMBuffer {
    /// Copies channel 0 out as `[Float]` so the pure helpers above (and
    /// their tests) never need to know about `AVAudioPCMBuffer` at all.
    /// A copy rather than a pointer handoff — these buffers are tiny
    /// (one tap callback's worth of audio) and a copy keeps `PCM16`
    /// itself free of any unsafe-pointer lifetime concerns.
    func floatChannelDataSamples() -> [Float] {
        guard let channelData = floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(frameLength)))
    }

    /// Copies an interleaved Int16 buffer's raw bytes into `Data`, in the
    /// platform's native (little-endian) byte order — the same layout
    /// `float32ToPcm16`/`buildRealtimeAudioChunk` produce before RN
    /// base64-encodes them for `input_audio_buffer.append`.
    func int16Data() -> Data? {
        guard let channelData = int16ChannelData else { return nil }
        let frameCount = Int(frameLength)
        guard frameCount > 0 else { return nil }
        let byteCount = frameCount * Int(format.channelCount) * MemoryLayout<Int16>.size
        return Data(bytes: channelData[0], count: byteCount)
    }
}
