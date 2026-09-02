import Testing
@testable import ReloraServices

/// Golden vectors for `PCM16`, ported from the cases implied by
/// apps/mobile/src/features/voice/realtime/audioTransform.ts's
/// `float32ToPcm16`/`computeRmsLevel`. Every expected value below is
/// computed by hand from the ported formula, not copied from a fixture,
/// since the two functions are simple enough to check by inspection:
/// `value < 0 ? round(value * 0x8000) : round(value * 0x7fff)` for
/// conversion, `min(1, sqrt(mean(clamp(x)^2)))` for RMS.
@Suite("PCM16")
struct PCM16Tests {
    @Test("full-scale positive and negative samples hit Int16's asymmetric extremes")
    func fullScaleExtremes() {
        #expect(PCM16.convert([1.0, -1.0]) == [32_767, -32_768])
    }

    @Test("zero converts to zero")
    func zeroConvertsToZero() {
        #expect(PCM16.convert([0.0]) == [0])
    }

    @Test("half-scale samples use the correct side's scale factor")
    func halfScaleUsesCorrectSideScale() {
        // round(0.5 * 32767) = round(16383.5) = 16384 (round half away from zero)
        // round(-0.5 * 32768) = round(-16384.0) = -16384 (exact, no rounding)
        #expect(PCM16.convert([0.5, -0.5]) == [16_384, -16_384])
    }

    @Test("out-of-range samples clamp to [-1, 1] before scaling")
    func outOfRangeSamplesClamp() {
        #expect(PCM16.convert([1.5, -2.0]) == [32_767, -32_768])
    }

    @Test("empty input converts to empty output")
    func emptyInputConvertsToEmpty() {
        #expect(PCM16.convert([]).isEmpty)
    }

    @Test("RMS of an empty buffer is zero")
    func rmsOfEmptyBufferIsZero() {
        #expect(PCM16.computeRMS([]) == 0)
    }

    @Test("RMS of silence is zero")
    func rmsOfSilenceIsZero() {
        #expect(PCM16.computeRMS([0, 0, 0, 0]) == 0)
    }

    @Test("RMS of full-scale samples is 1")
    func rmsOfFullScaleSamplesIsOne() {
        #expect(PCM16.computeRMS([1, 1, 1, 1]) == 1)
    }

    @Test("RMS of a mixed-sign half-scale buffer")
    func rmsOfMixedSignHalfScaleBuffer() {
        // sqrt(((0.5)^2 + (-0.5)^2) / 2) = sqrt(0.25) = 0.5
        let result = PCM16.computeRMS([0.5, -0.5])
        #expect(abs(result - 0.5) < 0.0001)
    }

    @Test("RMS clamps out-of-range samples before squaring, same as conversion")
    func rmsClampsOutOfRangeSamples() {
        // Both samples clamp to magnitude 1 regardless of how far past
        // the [-1, 1] range they started.
        #expect(PCM16.computeRMS([2, -2]) == 1)
    }

    // MARK: M7 — audioTransform.test.ts's own golden vectors

    /// The individual cases above already cover each value in isolation;
    /// this is the one array audioTransform.test.ts converts in a single
    /// call, kept as its own case so a regression that only shows up
    /// across a shared buffer (an off-by-one index, a wrong stride) has
    /// somewhere to fail.
    @Test("float32ToPcm16 golden vector: [-1, -0.5, 0, 0.5, 1]")
    func float32ToPcm16GoldenVector() {
        #expect(PCM16.convert([-1, -0.5, 0, 0.5, 1]) == [-32_768, -16_384, 0, 16_384, 32_767])
    }

    @Test("computeRmsLevel golden vector: four identical half-scale samples")
    func computeRmsLevelGoldenVectorFourHalfScaleSamples() {
        let result = PCM16.computeRMS([0.5, 0.5, 0.5, 0.5])
        #expect(abs(result - 0.5) < 0.0001)
    }
}
