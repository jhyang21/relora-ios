import Foundation
import AVFoundation

/// Why a recording ended. `.stoppedAtLimit` and `.interrupted` are
/// reported distinctly from `.manual` so a future orchestrator can tell
/// "the user tapped stop" apart from "we cut it off" without inspecting
/// duration math.
public enum StopReason: Sendable, Equatable {
    case manual
    case stoppedAtLimit
    case interrupted
}

/// The finished recording. Always an `.m4a` file — see
/// `RecordingController`'s doc comment for how its settings compare to
/// RN's.
public struct RecordingArtifact: Sendable, Equatable {
    public var fileURL: URL
    public var durationMS: Int
    public var mimeType: String
    public var stopReason: StopReason

    public init(fileURL: URL, durationMS: Int, mimeType: String, stopReason: StopReason) {
        self.fileURL = fileURL
        self.durationMS = durationMS
        self.mimeType = mimeType
        self.stopReason = stopReason
    }
}

public enum RecordingControllerError: Error, Sendable, Equatable {
    case permissionDenied
    case alreadyRecording
    /// A second `start()` while the first has not finished opening the
    /// microphone. Distinct from `alreadyRecording` because nothing is
    /// recording yet — see `RecordingController.start`'s doc comment for
    /// the window this covers.
    case alreadyStarting
    case sessionActivationFailed(String)
    case fileCreationFailed(String)
    case converterCreationFailed
    case engineStartFailed(String)
}

/// Pushed when a recording ends on its own — the caller does not have to
/// poll `stop()` to find out a limit was hit or a call interrupted
/// capture. A subsequent manual `stop()`/`cancel()` call is still safe:
/// both see the cached result and act on it idempotently.
public enum RecordingEvent: Sendable {
    case autoStopped(RecordingArtifact)
    case interrupted(RecordingArtifact)
}

/// One `AVAudioEngine`-based recorder. Every recording always writes a
/// mono AAC `.m4a` (the batch-transcription artifact), and — whenever
/// `setPCMFrameHandler` has installed a handler — simultaneously converts
/// the same tap buffers to 24 kHz mono Int16 for `RealtimeTranscriber`.
///
/// ## File settings vs. RN
///
/// `apps/mobile/src/features/voice/voiceService.ts` records through
/// `expo-audio`'s `RecordingPresets.HIGH_QUALITY`
/// (`node_modules/expo-audio/src/RecordingConstants.ts`): `.m4a`,
/// 44.1 kHz, **stereo**, 128 kbps, `AVAudioQuality.MAX`, `MPEG4AAC`. This
/// recorder instead writes **mono**, at the input hardware's native
/// sample rate (`AVAudioQuality.high`, 64 kbps — see
/// `Self.aacSettings(for:)`). Two deliberate departures:
///
/// - **Mono, not stereo.** The task calls for a mono file; halving the
///   channel count is also why the bitrate below is halved from RN's
///   128 kbps to 64 kbps — the per-channel budget is unchanged.
/// - **Native sample rate, not a fixed 44.1 kHz.** `AVAudioEngine`'s
///   input node format is already the hardware's native processing rate
///   (commonly 48 kHz under `.playAndRecord`/`.spokenAudio` on current
///   iPhones); resampling down to 44.1 kHz before AAC encoding would only
///   throw away fidelity the encoder itself will filter anyway.
///
/// ## Bridging the tap into an actor
///
/// `installTap`'s block runs on AVAudioEngine's internal render thread —
/// outside Swift Concurrency entirely, and definitely not on this actor's
/// executor. It cannot `await` into actor-isolated state (that would
/// block the render thread) and touching it synchronously would be an
/// isolation violation regardless. `RecordingTapSink` below is the fix:
/// a plain `@unchecked Sendable` class (the same NSLock-guarded pattern
/// `MockURLProtocol` uses in ReloraServicesTests) that owns everything
/// the tap needs — the file, the converters, the level continuation, the
/// frame handler — so the tap closure never has to reach back into the
/// actor at all.
///
/// ## Why an actor is not enough on its own
///
/// An actor serializes *statements*, not *operations*: every `await`
/// inside `start()` is a point where another call can run on this actor,
/// and `start()` has several — the microphone permission dialog above all,
/// which on a first run is however long the user takes to read it. An
/// unguarded `stop()` arriving in that window would find `isRecording`
/// still false and report a recording that had never begun; App Review
/// found exactly that on 2026-09-18. `startTask` below closes the window:
/// `stop()` and `cancel()` wait for the start they can see in flight
/// before they act on anything.
public actor RecordingController {
    private let sessionController: AudioSessionController
    private let engine = AVAudioEngine()

    private var isRecording = false
    private var startedAt: Date?
    private var fileURL: URL?
    private var finishedArtifact: RecordingArtifact?

    private var tapSink: RecordingTapSink?
    private var pendingPCMFrameHandler: ((Data) -> Void)?

    private var levelContinuation: AsyncStream<Float>.Continuation?
    private var elapsedContinuation: AsyncStream<Duration>.Continuation?
    private var eventContinuation: AsyncStream<RecordingEvent>.Continuation?

    private var maxDurationTask: Task<Void, Never>?
    private var elapsedTickTask: Task<Void, Never>?
    private var sessionEventTask: Task<Void, Never>?

    /// The start that is still opening the microphone, if there is one.
    /// Held as a `Task` rather than a bare flag so `stop()` and `cancel()`
    /// can *wait* for it rather than only notice it.
    private var startTask: Task<Void, Error>?

    public init(sessionController: AudioSessionController) {
        self.sessionController = sessionController
    }

    // MARK: - Streams

    public func levelStream() -> AsyncStream<Float> {
        let (stream, continuation) = AsyncStream.makeStream(of: Float.self)
        levelContinuation = continuation
        tapSink?.levelContinuation = continuation
        return stream
    }

    public func elapsedTimeStream(interval: Duration = .milliseconds(100)) -> AsyncStream<Duration> {
        let (stream, continuation) = AsyncStream.makeStream(of: Duration.self)
        elapsedContinuation = continuation
        return stream
    }

    public func events() -> AsyncStream<RecordingEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: RecordingEvent.self)
        eventContinuation = continuation
        return stream
    }

    /// Installs (or clears) the realtime PCM handler. Can be called
    /// before `start()` or mid-recording — either way the active tap
    /// sink (if any) picks it up immediately.
    public func setPCMFrameHandler(_ handler: ((Data) -> Void)?) {
        pendingPCMFrameHandler = handler
        tapSink?.pcmFrameHandler = handler
    }

    // MARK: - start / stop / cancel

    /// Opens the microphone and begins writing the file.
    ///
    /// The work runs inside a `Task` this actor keeps hold of, rather than
    /// straight down this function's body, for one reason: a caller that
    /// is no longer interested — a Stop or a cancel that arrives while the
    /// permission dialog is still up — has to be able to wait for the
    /// start to finish before tearing it down. See the type's "Why an
    /// actor is not enough on its own".
    public func start(maxDuration: Duration) async throws {
        guard startTask == nil else { throw RecordingControllerError.alreadyStarting }
        guard !isRecording else { throw RecordingControllerError.alreadyRecording }

        let task = Task { try await self.performStart(maxDuration: maxDuration) }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    /// Waits out an in-flight `start()`, if any, and swallows its failure —
    /// a caller that is stopping or cancelling wants the microphone
    /// settled, not the reason it would not open. `start()`'s own caller
    /// still sees the error.
    private func awaitPendingStart() async {
        guard let startTask else { return }
        _ = try? await startTask.value
    }

    private func performStart(maxDuration: Duration) async throws {
        guard await AudioSessionController.requestMicrophonePermission() else {
            throw RecordingControllerError.permissionDenied
        }

        do {
            try await sessionController.activate()
        } catch {
            throw RecordingControllerError.sessionActivationFailed(String(describing: error))
        }

        let hardwareFormat = engine.inputNode.outputFormat(forBus: 0)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("relora-recording-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        // AVAudioEngine node formats are always float32, non-interleaved,
        // at the session's true sample rate — only the channel count can
        // legitimately differ from the mono file we want to write.
        let writeFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: hardwareFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(
                forWriting: outputURL,
                settings: Self.aacSettings(for: hardwareFormat),
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            await sessionController.deactivate()
            throw RecordingControllerError.fileCreationFailed(String(describing: error))
        }

        var monoDownmixConverter: AVAudioConverter?
        if hardwareFormat.channelCount != 1 {
            guard let converter = AVAudioConverter(from: hardwareFormat, to: writeFormat) else {
                await sessionController.deactivate()
                throw RecordingControllerError.converterCreationFailed
            }
            monoDownmixConverter = converter
        }

        // AVAudioConverter here does both the channel downmix and the
        // sample-rate conversion to 24 kHz in one step, straight from the
        // raw hardware buffer — do NOT hand-roll resampling (see
        // PCM16.swift's doc comment for why).
        let realtimeFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        )!
        guard let realtimeConverter = AVAudioConverter(from: hardwareFormat, to: realtimeFormat) else {
            await sessionController.deactivate()
            throw RecordingControllerError.converterCreationFailed
        }

        let sink = RecordingTapSink(
            audioFile: audioFile,
            writeFormat: writeFormat,
            monoDownmixConverter: monoDownmixConverter,
            realtimeConverter: realtimeConverter,
            realtimeFormat: realtimeFormat
        )
        sink.pcmFrameHandler = pendingPCMFrameHandler
        sink.levelContinuation = levelContinuation
        tapSink = sink

        engine.inputNode.installTap(onBus: 0, bufferSize: 4_096, format: hardwareFormat) { buffer, _ in
            sink.process(buffer: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            tapSink = nil
            await sessionController.deactivate()
            throw RecordingControllerError.engineStartFailed(String(describing: error))
        }

        fileURL = outputURL
        startedAt = Date()
        isRecording = true
        finishedArtifact = nil

        scheduleAutoStop(after: maxDuration)
        observeSessionEvents()
        scheduleElapsedTicks(interval: .milliseconds(100))
    }

    /// Manual stop. If the recording already ended on its own
    /// (`.stoppedAtLimit` / `.interrupted`, surfaced first through
    /// `events()`), this just returns that cached result — safe to call
    /// even after an auto-stop the caller hasn't reacted to yet.
    ///
    /// Waits for a start that is still in flight, so a Stop tapped while
    /// the permission dialog was up stops the recording that dialog was
    /// about instead of racing past it.
    ///
    /// Returns nil when there is nothing to hand back: a start that threw,
    /// or one that never happened. That is a distinct answer from "here is
    /// a recording of no length" — the caller has no file to upload and
    /// must not pretend otherwise.
    public func stop() async -> RecordingArtifact? {
        await awaitPendingStart()
        if let finishedArtifact {
            return finishedArtifact
        }
        guard isRecording else { return nil }
        return await teardown(reason: .manual)
    }

    /// Stops (if still running) and discards the file — used when the
    /// user backs out of a recording rather than confirming it.
    ///
    /// Waits out an in-flight start for the same reason `stop()` does, and
    /// for one more: without the wait, a cancel mid-start was a no-op and
    /// the microphone stayed open behind a closed sheet.
    public func cancel() async {
        await awaitPendingStart()
        if let finishedArtifact {
            try? FileManager.default.removeItem(at: finishedArtifact.fileURL)
            self.finishedArtifact = nil
            return
        }
        guard isRecording else { return }
        if let artifact = await teardown(reason: .manual) {
            try? FileManager.default.removeItem(at: artifact.fileURL)
        }
    }

    // MARK: - Teardown

    /// Shuts the engine and the session down and returns what was
    /// recorded.
    ///
    /// Optional only for the impossible case: every caller guards on
    /// `isRecording`, and `fileURL` is set in the same breath as
    /// `isRecording` becomes true, so a nil here would mean the two had
    /// drifted apart. It reports that rather than papering over it with a
    /// path to a directory, which is what the old fallback did and what
    /// reached App Review as "could not read that recording".
    private func teardown(reason: StopReason) async -> RecordingArtifact? {
        maxDurationTask?.cancel()
        elapsedTickTask?.cancel()
        sessionEventTask?.cancel()
        maxDurationTask = nil
        elapsedTickTask = nil
        sessionEventTask = nil

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        await sessionController.deactivate()

        let artifact = fileURL.map { url in
            RecordingArtifact(
                fileURL: url,
                durationMS: Self.durationMS(
                    framesWritten: tapSink?.totalFramesWritten ?? 0,
                    sampleRate: tapSink?.writeSampleRate ?? 1
                ),
                mimeType: "audio/m4a",
                stopReason: reason
            )
        }

        tapSink = nil
        isRecording = false
        levelContinuation?.finish()
        elapsedContinuation?.finish()

        return artifact
    }

    private func scheduleAutoStop(after duration: Duration) {
        maxDurationTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, !Task.isCancelled else { return }
            await self.handleAutoStop()
        }
    }

    private func handleAutoStop() async {
        guard isRecording else { return }
        guard let artifact = await teardown(reason: .stoppedAtLimit) else { return }
        finishedArtifact = artifact
        eventContinuation?.yield(.autoStopped(artifact))
    }

    private func observeSessionEvents() {
        sessionEventTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.sessionController.events()
            for await event in stream {
                if Task.isCancelled { break }
                if case .interruptionBegan = event {
                    await self.handleInterruption()
                }
            }
        }
    }

    /// Preserves the partial file rather than discarding it — an
    /// interrupted voice note (e.g. an incoming call) still has whatever
    /// was captured before the interruption, matching the brief's "stops
    /// cleanly with the partial file preserved."
    private func handleInterruption() async {
        guard isRecording else { return }
        guard let artifact = await teardown(reason: .interrupted) else { return }
        finishedArtifact = artifact
        eventContinuation?.yield(.interrupted(artifact))
    }

    private func scheduleElapsedTicks(interval: Duration) {
        elapsedTickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                guard await self.tickElapsed() else { return }
            }
        }
    }

    /// Reads `isRecording`/`startedAt` and yields one elapsed-time tick
    /// as a single actor-isolated hop, so the polling loop above can't
    /// observe a torn state between `stop()`/`cancel()` clearing
    /// `startedAt` and the loop's next iteration.
    private func tickElapsed() -> Bool {
        guard isRecording, let startedAt else { return false }
        let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1_000)
        elapsedContinuation?.yield(.milliseconds(elapsedMS))
        return true
    }

    // MARK: - Pure helpers (unit-testable without AVAudioEngine)

    /// RN parity: see the type-level doc comment. Bitrate is halved from
    /// RN's 128 kbps to 64 kbps because this file is mono where RN's was
    /// stereo.
    static func aacSettings(for hardwareFormat: AVAudioFormat) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: hardwareFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 64_000
        ]
    }

    /// Frame-accurate duration from what was actually written to the
    /// file, rather than wall-clock elapsed time — avoids drift from
    /// however long `stop()` itself takes to run.
    static func durationMS(framesWritten: AVAudioFramePosition, sampleRate: Double) -> Int {
        guard sampleRate > 0 else { return 0 }
        return max(0, Int((Double(framesWritten) / sampleRate) * 1_000))
    }
}

/// See `RecordingController`'s "Bridging the tap into an actor" doc
/// comment. Every method here runs on AVAudioEngine's render thread
/// except the `pcmFrameHandler`/`levelContinuation` setters, which run on
/// whatever isolation context `RecordingController` calls them from —
/// hence the lock, which only ever has to serialize those rare
/// cross-thread writes against the tap's own serial reads.
private final class RecordingTapSink: @unchecked Sendable {
    private let lock = NSLock()
    private let audioFile: AVAudioFile
    private let writeFormat: AVAudioFormat
    private let monoDownmixConverter: AVAudioConverter?
    private let realtimeConverter: AVAudioConverter
    private let realtimeFormat: AVAudioFormat

    private var _pcmFrameHandler: ((Data) -> Void)?
    private var _levelContinuation: AsyncStream<Float>.Continuation?
    private var _totalFramesWritten: AVAudioFramePosition = 0

    init(
        audioFile: AVAudioFile,
        writeFormat: AVAudioFormat,
        monoDownmixConverter: AVAudioConverter?,
        realtimeConverter: AVAudioConverter,
        realtimeFormat: AVAudioFormat
    ) {
        self.audioFile = audioFile
        self.writeFormat = writeFormat
        self.monoDownmixConverter = monoDownmixConverter
        self.realtimeConverter = realtimeConverter
        self.realtimeFormat = realtimeFormat
    }

    var pcmFrameHandler: ((Data) -> Void)? {
        get { lock.withLock { _pcmFrameHandler } }
        set { lock.withLock { _pcmFrameHandler = newValue } }
    }

    var levelContinuation: AsyncStream<Float>.Continuation? {
        get { lock.withLock { _levelContinuation } }
        set { lock.withLock { _levelContinuation = newValue } }
    }

    var totalFramesWritten: AVAudioFramePosition { lock.withLock { _totalFramesWritten } }
    var writeSampleRate: Double { writeFormat.sampleRate }

    /// Runs on the audio render thread for every tap buffer. The file
    /// write happens first and unconditionally — a realtime-path
    /// conversion failure must never cost the batch artifact any audio.
    func process(buffer: AVAudioPCMBuffer) {
        let monoBuffer: AVAudioPCMBuffer
        if let monoDownmixConverter {
            guard let converted = Self.convert(buffer, using: monoDownmixConverter, to: writeFormat) else {
                return
            }
            monoBuffer = converted
        } else {
            monoBuffer = buffer
        }

        if let framesWritten = try? write(monoBuffer) {
            lock.withLock { _totalFramesWritten += framesWritten }
        }

        levelContinuation?.yield(PCM16.computeRMS(monoBuffer.floatChannelDataSamples()))

        if let handler = pcmFrameHandler,
           let realtimeBuffer = Self.convert(buffer, using: realtimeConverter, to: realtimeFormat),
           let data = realtimeBuffer.int16Data() {
            handler(data)
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws -> AVAudioFramePosition {
        try audioFile.write(from: buffer)
        return AVAudioFramePosition(buffer.frameLength)
    }

    /// Feeds one buffer through `converter` and pulls exactly one output
    /// buffer back. `AVAudioConverter` is pull-based: it invokes the
    /// input block repeatedly until told `.noDataNow`, so `provided`
    /// below — flipped after the single buffer is handed over — is what
    /// stops the pull after one round trip per call.
    ///
    /// Output capacity is sized from the sample-rate ratio plus 32 frames
    /// of slack: the converter's internal resampling filter can hold a
    /// few frames back around each call, and an undersized buffer
    /// surfaces as a truncated `.haveData` (fewer frames than expected)
    /// rather than a thrown error — slack is cheap insurance against
    /// silently dropped samples.
    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter,
        to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var provided = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return buffer
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return outputBuffer.frameLength > 0 ? outputBuffer : nil
        case .error:
            return nil
        @unknown default:
            return nil
        }
    }
}
