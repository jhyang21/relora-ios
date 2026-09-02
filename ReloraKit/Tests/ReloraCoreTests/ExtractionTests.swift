import Testing
import Foundation
@testable import ReloraCore

@Suite("ExtractionPayload")
struct ExtractionTests {
    @Test("accepts one memory draft plus key things and reminder data")
    func acceptsFullValidPayload() {
        let payload = ExtractionPayload(
            subjectNameGuess: ExtractionSubjectGuess(text: "Priya Patel", confidence: 0.81),
            memoryDraft: ExtractionMemoryDraft(text: "She is moving in July.", confidence: 0.84),
            keyThings: [ExtractionSuggestion(id: "item-2", text: "Her husband's name is Tom.", labels: ["family"])],
            reminderSuggestion: ExtractionReminderSuggestion(
                title: "Follow up after the move",
                remindAt: "2026-03-10T10:00:00.000Z",
                confidence: 0.7
            )
        )

        #expect(payload.validate().isEmpty)
    }

    @Test("rejects more than five key things")
    func rejectsMoreThanFiveKeyThings() {
        let keyThings = (1...6).map { index in
            ExtractionSuggestion(id: "item-\(index)", text: "Key thing \(index)", labels: ["voice"])
        }
        let payload = ExtractionPayload(
            subjectNameGuess: nil,
            memoryDraft: ExtractionMemoryDraft(text: "Memory 1", confidence: 0.5),
            keyThings: keyThings,
            reminderSuggestion: nil
        )

        #expect(payload.validate().contains(.tooManyKeyThings))
        #expect(!payload.isValid)
    }

    @Test("every field is optional; an empty payload is valid")
    func emptyPayloadIsValid() {
        let payload = ExtractionPayload(subjectNameGuess: nil, memoryDraft: nil, keyThings: [], reminderSuggestion: nil)
        #expect(payload.isValid)
    }

    @Test("rejects a blank key-thing id or text")
    func rejectsBlankKeyThingIdOrText() {
        let payload = ExtractionPayload(
            subjectNameGuess: nil,
            memoryDraft: nil,
            keyThings: [ExtractionSuggestion(id: "  ", text: "Something", labels: [])],
            reminderSuggestion: nil
        )
        #expect(payload.validate().contains(.invalidKeyThing(index: 0)))
    }

    @Test("rejects more than five labels on a key thing")
    func rejectsMoreThanFiveLabels() {
        let payload = ExtractionPayload(
            subjectNameGuess: nil,
            memoryDraft: nil,
            keyThings: [ExtractionSuggestion(id: "item-1", text: "Text", labels: ["a", "b", "c", "d", "e", "f"])],
            reminderSuggestion: nil
        )
        #expect(payload.validate().contains(.tooManyLabels(keyThingIndex: 0)))
    }

    @Test("rejects a blank label")
    func rejectsBlankLabel() {
        let payload = ExtractionPayload(
            subjectNameGuess: nil,
            memoryDraft: nil,
            keyThings: [ExtractionSuggestion(id: "item-1", text: "Text", labels: ["family", "   "])],
            reminderSuggestion: nil
        )
        #expect(payload.validate().contains(.invalidLabel(keyThingIndex: 0, labelIndex: 1)))
    }

    @Test("rejects a subject-name guess with confidence outside 0...1")
    func rejectsOutOfRangeSubjectConfidence() {
        let payload = ExtractionPayload(
            subjectNameGuess: ExtractionSubjectGuess(text: "Priya Patel", confidence: 1.5),
            memoryDraft: nil,
            keyThings: [],
            reminderSuggestion: nil
        )
        #expect(payload.validate().contains(.invalidSubjectNameGuess))
    }

    @Test("rejects a blank memory draft text")
    func rejectsBlankMemoryDraftText() {
        let payload = ExtractionPayload(
            subjectNameGuess: nil,
            memoryDraft: ExtractionMemoryDraft(text: "   ", confidence: 0.5),
            keyThings: [],
            reminderSuggestion: nil
        )
        #expect(payload.validate().contains(.invalidMemoryDraft))
    }

    @Test("rejects a reminder suggestion with a non-ISO remind_at")
    func rejectsMalformedRemindAt() {
        let payload = ExtractionPayload(
            subjectNameGuess: nil,
            memoryDraft: nil,
            keyThings: [],
            reminderSuggestion: ExtractionReminderSuggestion(
                title: "Follow up",
                remindAt: "next Tuesday",
                confidence: 0.6
            )
        )
        #expect(payload.validate().contains(.invalidReminderSuggestion))
    }

    @Test("accepts a reminder suggestion with fractional seconds in remind_at")
    func acceptsRemindAtWithFractionalSeconds() {
        let payload = ExtractionPayload(
            subjectNameGuess: nil,
            memoryDraft: nil,
            keyThings: [],
            reminderSuggestion: ExtractionReminderSuggestion(
                title: "Follow up",
                remindAt: "2026-03-10T10:00:00.123Z",
                confidence: 0.6
            )
        )
        #expect(payload.isValid)
    }

    @Test("decodes the snake_case wire contract via Codable")
    func decodesSnakeCaseWireContract() throws {
        let json = """
        {
          "subject_name_guess": { "text": "Priya Patel", "confidence": 0.81 },
          "memory_draft": { "text": "She is moving in July.", "confidence": 0.84 },
          "key_things": [{ "id": "item-2", "text": "Her husband's name is Tom.", "labels": ["family"] }],
          "reminder_suggestion": { "title": "Follow up after the move", "remind_at": "2026-03-10T10:00:00.000Z", "confidence": 0.7 }
        }
        """
        let payload = try JSONDecoder().decode(ExtractionPayload.self, from: Data(json.utf8))

        #expect(payload.subjectNameGuess?.text == "Priya Patel")
        #expect(payload.reminderSuggestion?.remindAt == "2026-03-10T10:00:00.000Z")
        #expect(payload.isValid)
    }
}
