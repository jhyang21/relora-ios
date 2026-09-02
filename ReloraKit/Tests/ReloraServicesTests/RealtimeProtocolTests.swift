import Foundation
import Testing
@testable import ReloraServices

/// Decodes `data` into a loosely-typed JSON dictionary for assertions —
/// `JSONEncoder`'s key ordering is not guaranteed stable, so comparing
/// against a raw expected string would be flaky; comparing decoded values
/// is not.
private func jsonObject(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

@Suite("RealtimeProtocol encoding")
struct RealtimeProtocolEncodingTests {
    @Test("session.update carries the exact transcription config RN sends")
    func sessionUpdateShape() {
        let object = jsonObject(RealtimeProtocol.encodeSessionUpdate())
        #expect(object["type"] as? String == "session.update")

        let session = object["session"] as? [String: Any]
        #expect(session?["type"] as? String == "transcription")
        #expect(session?["include"] as? [String] == ["item.input_audio_transcription.logprobs"])

        let input = ((session?["audio"] as? [String: Any])?["input"]) as? [String: Any]
        let format = input?["format"] as? [String: Any]
        #expect(format?["type"] as? String == "audio/pcm")
        #expect(format?["rate"] as? Int == 24_000)

        let transcription = input?["transcription"] as? [String: Any]
        #expect(transcription?["model"] as? String == "gpt-4o-transcribe")

        let turnDetection = input?["turn_detection"] as? [String: Any]
        #expect(turnDetection?["type"] as? String == "server_vad")
        #expect(turnDetection?["threshold"] as? Double == 0.5)
        #expect(turnDetection?["prefix_padding_ms"] as? Int == 300)
        #expect(turnDetection?["silence_duration_ms"] as? Int == 500)
    }

    @Test("input_audio_buffer.append base64-encodes the given PCM bytes")
    func appendEncodesBase64() {
        let pcm = Data([0x01, 0x02, 0xFF, 0x00])
        let object = jsonObject(RealtimeProtocol.encodeAppend(pcm: pcm))
        #expect(object["type"] as? String == "input_audio_buffer.append")
        #expect(object["audio"] as? String == pcm.base64EncodedString())
    }

    @Test("input_audio_buffer.commit carries only its type")
    func commitShape() {
        let object = jsonObject(RealtimeProtocol.encodeCommit())
        #expect(object["type"] as? String == "input_audio_buffer.commit")
        #expect(object.count == 1)
    }
}

@Suite("RealtimeProtocol decoding")
struct RealtimeProtocolDecodingTests {
    private func encode(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    @Test("delta event decodes item_id and delta")
    func decodesDeltaEvent() {
        let event = RealtimeProtocol.decodeServerEvent(encode([
            "type": "conversation.item.input_audio_transcription.delta",
            "item_id": "item_1",
            "delta": "hel"
        ]))
        #expect(event == .transcriptDelta(itemID: "item_1", delta: "hel"))
    }

    @Test("completed event decodes item_id and transcript")
    func decodesCompletedEvent() {
        let event = RealtimeProtocol.decodeServerEvent(encode([
            "type": "conversation.item.input_audio_transcription.completed",
            "item_id": "item_1",
            "transcript": "hello there"
        ]))
        #expect(event == .itemCompleted(itemID: "item_1", transcript: "hello there"))
    }

    @Test("committed event decodes item_id and a present previous_item_id")
    func decodesCommittedEventWithPrevious() {
        let event = RealtimeProtocol.decodeServerEvent(encode([
            "type": "input_audio_buffer.committed",
            "item_id": "item_2",
            "previous_item_id": "item_1"
        ]))
        #expect(event == .bufferCommitted(itemID: "item_2", previousItemID: "item_1"))
    }

    @Test("committed event decodes a null previous_item_id as nil")
    func decodesCommittedEventWithNullPrevious() {
        let event = RealtimeProtocol.decodeServerEvent(encode([
            "type": "input_audio_buffer.committed",
            "item_id": "item_1",
            "previous_item_id": NSNull()
        ]))
        #expect(event == .bufferCommitted(itemID: "item_1", previousItemID: nil))
    }

    @Test("speech_started and speech_stopped decode with no payload")
    func decodesSpeechEvents() {
        #expect(RealtimeProtocol.decodeServerEvent(encode(["type": "input_audio_buffer.speech_started"])) == .speechStarted)
        #expect(RealtimeProtocol.decodeServerEvent(encode(["type": "input_audio_buffer.speech_stopped"])) == .speechStopped)
    }

    @Test("error event with a plain string payload")
    func decodesStringErrorEvent() {
        let event = RealtimeProtocol.decodeServerEvent(encode([
            "type": "error",
            "error": "boom"
        ]))
        #expect(event == .serverError(message: "boom"))
    }

    @Test("error event with an object payload")
    func decodesObjectErrorEvent() {
        let event = RealtimeProtocol.decodeServerEvent(encode([
            "type": "error",
            "error": ["message": "server exploded"]
        ]))
        #expect(event == .serverError(message: "server exploded"))
    }

    @Test("error event with an object payload missing a message falls back to the default")
    func decodesObjectErrorEventMissingMessage() {
        let event = RealtimeProtocol.decodeServerEvent(encode([
            "type": "error",
            "error": [String: Any]()
        ]))
        #expect(event == .serverError(message: "REALTIME_TRANSCRIPTION_FAILED"))
    }

    @Test("unrecognized event type decodes to .unknown, not an error")
    func decodesUnknownEventType() {
        let event = RealtimeProtocol.decodeServerEvent(encode(["type": "response.done"]))
        #expect(event == .unknown(type: "response.done"))
    }

    @Test("a delta event missing item_id decodes to .unknown rather than crashing")
    func decodesDeltaEventMissingItemID() {
        let event = RealtimeProtocol.decodeServerEvent(encode([
            "type": "conversation.item.input_audio_transcription.delta",
            "delta": "hel"
        ]))
        #expect(event == .unknown(type: "conversation.item.input_audio_transcription.delta"))
    }

    @Test("non-JSON bytes decode to .parseFailed")
    func decodesGarbageAsParseFailed() {
        let event = RealtimeProtocol.decodeServerEvent(Data([0xFF, 0x00, 0x13, 0x37]))
        #expect(event == .parseFailed)
    }
}

@Suite("RealtimeProtocol.TranscriptAccumulator")
struct TranscriptAccumulatorTests {
    @Test("deltas for one turn accumulate in append order")
    func deltasAccumulateInOrder() {
        var accumulator = RealtimeProtocol.TranscriptAccumulator()
        _ = accumulator.appendDelta(itemID: "item_1", delta: "hel")
        let composed = accumulator.appendDelta(itemID: "item_1", delta: "lo")
        #expect(composed == "hello")
    }

    @Test("completing a turn overwrites its accumulated deltas with the final transcript")
    func completingOverwritesDeltas() {
        var accumulator = RealtimeProtocol.TranscriptAccumulator()
        _ = accumulator.appendDelta(itemID: "item_1", delta: "hel")
        let composed = accumulator.completeTurn(itemID: "item_1", transcript: "hello world")
        #expect(composed == "hello world")
        #expect(accumulator.isCompleted("item_1"))
    }

    @Test("two committed turns compose in previousItemID order, not arrival order")
    func multiTurnComposesInLinkOrder() {
        var accumulator = RealtimeProtocol.TranscriptAccumulator()
        // item_2 (the second turn) arrives and completes before item_1 is
        // even registered as committed — composedTranscript must still
        // read "first second" once both links are known.
        _ = accumulator.registerCommittedTurn(itemID: "item_2", previousItemID: "item_1")
        _ = accumulator.completeTurn(itemID: "item_2", transcript: "second")
        _ = accumulator.registerCommittedTurn(itemID: "item_1", previousItemID: nil)
        let composed = accumulator.completeTurn(itemID: "item_1", transcript: "first")
        #expect(composed == "first second")
    }

    @Test("a turn with no registered previousItemID is treated as a root")
    func unregisteredTurnIsRoot() {
        var accumulator = RealtimeProtocol.TranscriptAccumulator()
        let composed = accumulator.completeTurn(itemID: "item_1", transcript: "solo turn")
        #expect(composed == "solo turn")
    }

    @Test("empty-transcript turns are excluded from composition")
    func emptyTurnsExcluded() {
        var accumulator = RealtimeProtocol.TranscriptAccumulator()
        _ = accumulator.registerCommittedTurn(itemID: "item_1", previousItemID: nil)
        let composed = accumulator.completeTurn(itemID: "item_1", transcript: "   ")
        #expect(composed.isEmpty)
        #expect(!accumulator.isCompleted("item_1"))
    }
}
