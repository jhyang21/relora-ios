import Foundation

/// Wire-level encode/decode for the OpenAI Realtime transcription
/// WebSocket protocol, factored out of `RealtimeTranscriber` so the JSON
/// shapes and the transcript-accumulation rules can be tested without a
/// socket. Ports
/// apps/mobile/src/features/voice/realtime/realtimeTranscriptionClient.ts
/// (message shapes, event switch) and
/// apps/mobile/src/features/voice/realtime/transcriptAccumulator.ts
/// (turn ordering/composition) as directly as Swift's type system allows.
enum RealtimeProtocol {
    static let sampleRate = 24_000
    static let transcriptionModel = "gpt-4o-transcribe"

    // MARK: - Outgoing messages

    /// Mirrors `buildRealtimeSessionUpdateEvent`. Sent once, right after
    /// the socket's handshake completes. Field names/nesting matter to
    /// the server — this mirrors RN's object shape exactly, down to
    /// `session.audio.input.{format,transcription,turn_detection}`.
    static func encodeSessionUpdate() -> Data {
        struct Message: Encodable {
            let type = "session.update"
            let session: Session
            struct Session: Encodable {
                let type = "transcription"
                let audio: Audio
                let include: [String]
                struct Audio: Encodable {
                    let input: Input
                    struct Input: Encodable {
                        let format: Format
                        let transcription: Transcription
                        let turn_detection: TurnDetection
                        struct Format: Encodable {
                            let type = "audio/pcm"
                            let rate: Int
                        }
                        struct Transcription: Encodable {
                            let model: String
                        }
                        struct TurnDetection: Encodable {
                            let type = "server_vad"
                            let threshold: Double
                            let prefix_padding_ms: Int
                            let silence_duration_ms: Int
                        }
                    }
                }
            }
        }

        let message = Message(session: .init(
            audio: .init(input: .init(
                format: .init(rate: sampleRate),
                transcription: .init(model: transcriptionModel),
                turn_detection: .init(threshold: 0.5, prefix_padding_ms: 300, silence_duration_ms: 500)
            )),
            include: ["item.input_audio_transcription.logprobs"]
        ))
        // Every field is a Swift literal or a caller-supplied Int/Data —
        // encoding this can only fail if JSONEncoder itself is broken.
        return (try? JSONEncoder().encode(message)) ?? Data()
    }

    /// Mirrors `appendAudio`: base64-encodes `pcm` into
    /// `input_audio_buffer.append`.
    static func encodeAppend(pcm: Data) -> Data {
        struct Message: Encodable {
            let type = "input_audio_buffer.append"
            let audio: String
        }
        let message = Message(audio: pcm.base64EncodedString())
        return (try? JSONEncoder().encode(message)) ?? Data()
    }

    /// Mirrors `commitAudio`.
    static func encodeCommit() -> Data {
        struct Message: Encodable {
            let type = "input_audio_buffer.commit"
        }
        return (try? JSONEncoder().encode(Message())) ?? Data()
    }

    // MARK: - Incoming events

    /// One decoded server event, mirroring the `switch (payload.type)` in
    /// `RealtimeTranscriptionClient.handleMessage`. `.unknown` and
    /// `.parseFailed` correspond to RN's `default: return` and
    /// `catch { onError }` branches respectively — kept distinct here so
    /// tests can tell "recognized event type but missing a required
    /// field" apart from "not JSON at all".
    enum DecodedEvent: Equatable {
        case transcriptDelta(itemID: String, delta: String)
        case itemCompleted(itemID: String, transcript: String)
        case bufferCommitted(itemID: String, previousItemID: String?)
        case speechStarted
        case speechStopped
        case serverError(message: String)
        case unknown(type: String?)
        case parseFailed
    }

    private struct ServerEventEnvelope: Decodable {
        let type: String?
        let delta: String?
        let item_id: String?
        let previous_item_id: String?
        let transcript: String?
        let error: ErrorPayload?
    }

    /// RN's `RealtimeServerEvent.error` is typed `{ message?: string } |
    /// string`. Mirrors `resolveRealtimeServerErrorMessage`'s handling of
    /// both shapes.
    private enum ErrorPayload: Decodable, Equatable {
        case string(String)
        case object(message: String?)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let stringValue = try? container.decode(String.self) {
                self = .string(stringValue)
                return
            }
            struct Wrapper: Decodable { let message: String? }
            let wrapper = try container.decode(Wrapper.self)
            self = .object(message: wrapper.message)
        }

        var resolvedMessage: String {
            switch self {
            case .string(let value): return value
            case .object(let message): return message ?? "REALTIME_TRANSCRIPTION_FAILED"
            }
        }
    }

    static func decodeServerEvent(_ data: Data) -> DecodedEvent {
        guard let envelope = try? JSONDecoder().decode(ServerEventEnvelope.self, from: data) else {
            return .parseFailed
        }

        switch envelope.type {
        case "conversation.item.input_audio_transcription.delta":
            guard let itemID = envelope.item_id, let delta = envelope.delta else {
                return .unknown(type: envelope.type)
            }
            return .transcriptDelta(itemID: itemID, delta: delta)

        case "conversation.item.input_audio_transcription.completed":
            guard let itemID = envelope.item_id, let transcript = envelope.transcript else {
                return .unknown(type: envelope.type)
            }
            return .itemCompleted(itemID: itemID, transcript: transcript)

        case "input_audio_buffer.committed":
            guard let itemID = envelope.item_id else {
                return .unknown(type: envelope.type)
            }
            return .bufferCommitted(itemID: itemID, previousItemID: envelope.previous_item_id)

        case "input_audio_buffer.speech_started":
            return .speechStarted

        case "input_audio_buffer.speech_stopped":
            return .speechStopped

        case "error":
            return .serverError(message: envelope.error?.resolvedMessage ?? "REALTIME_TRANSCRIPTION_FAILED")

        default:
            return .unknown(type: envelope.type)
        }
    }

    // MARK: - Transcript accumulation

    /// Mirrors `createTranscriptAccumulator`'s closures one-for-one as
    /// methods on a value type. `previousItemID` links each turn to the
    /// turn the server VAD segmented it from; `composedTranscript()`
    /// walks those links depth-first from every root (a turn with no
    /// known parent) so multi-turn dictation composes in speech order
    /// even when `.completed` events arrive out of order across turns.
    struct TranscriptAccumulator: Equatable {
        private struct Turn: Equatable {
            var itemID: String
            var previousItemID: String?
            var transcript: String = ""
        }

        private var turns: [String: Turn] = [:]
        private var orderedItemIDs: [String] = []

        private mutating func touchTurn(_ itemID: String) -> Turn {
            if let existing = turns[itemID] { return existing }
            let created = Turn(itemID: itemID)
            turns[itemID] = created
            orderedItemIDs.append(itemID)
            return created
        }

        private func dedupeOrdered(_ list: [Turn]) -> [Turn] {
            var seen = Set<String>()
            var ordered: [Turn] = []
            for turn in list where !seen.contains(turn.itemID) {
                seen.insert(turn.itemID)
                ordered.append(turn)
            }
            return ordered
        }

        func composedTranscript() -> String {
            var byPreviousItemID: [String?: [Turn]] = [:]
            for itemID in orderedItemIDs {
                guard let turn = turns[itemID], !turn.transcript.trimmed.isEmpty else { continue }
                byPreviousItemID[turn.previousItemID, default: []].append(turn)
            }

            var ordered: [Turn] = []
            let nonEmptyInOrder = orderedItemIDs
                .compactMap { turns[$0] }
                .filter { !$0.transcript.trimmed.isEmpty }
            let roots = dedupeOrdered((byPreviousItemID[nil] ?? []) + nonEmptyInOrder)

            func walk(_ turn: Turn) {
                ordered.append(turn)
                for child in dedupeOrdered(byPreviousItemID[turn.itemID] ?? []) {
                    walk(child)
                }
            }

            for turn in roots where !ordered.contains(where: { $0.itemID == turn.itemID }) {
                walk(turn)
            }

            return ordered
                .map { $0.transcript.trimmed }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmed
        }

        @discardableResult
        mutating func appendDelta(itemID: String, delta: String) -> String {
            var turn = touchTurn(itemID)
            turn.transcript += delta
            turns[itemID] = turn
            return composedTranscript()
        }

        @discardableResult
        mutating func completeTurn(itemID: String, transcript: String) -> String {
            var turn = touchTurn(itemID)
            turn.transcript = transcript.trimmed
            turns[itemID] = turn
            return composedTranscript()
        }

        @discardableResult
        mutating func registerCommittedTurn(itemID: String, previousItemID: String?) -> String {
            var turn = touchTurn(itemID)
            turn.previousItemID = previousItemID
            turns[itemID] = turn
            return composedTranscript()
        }

        func isCompleted(_ itemID: String) -> Bool {
            !(turns[itemID]?.transcript.trimmed.isEmpty ?? true)
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
