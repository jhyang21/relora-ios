import Foundation

/// Candidate subject name returned by transcript extraction. Mirrors
/// `ExtractionSubjectGuess`.
public struct ExtractionSubjectGuess: Codable, Equatable, Sendable {
    public var text: String
    public var confidence: Double

    public init(text: String, confidence: Double) {
        self.text = text
        self.confidence = confidence
    }
}

/// Polished memory draft returned by transcript extraction. Mirrors
/// `ExtractionMemoryDraft`.
public struct ExtractionMemoryDraft: Codable, Equatable, Sendable {
    public var text: String
    public var confidence: Double

    public init(text: String, confidence: Double) {
        self.text = text
        self.confidence = confidence
    }
}

/// Reviewable key-thing suggestion returned by transcript extraction.
/// Mirrors `ExtractionSuggestion`.
public struct ExtractionSuggestion: Codable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var labels: [String]

    public init(id: String, text: String, labels: [String]) {
        self.id = id
        self.text = text
        self.labels = labels
    }
}

/// Candidate reminder returned by transcript extraction. Mirrors
/// `ExtractionReminderSuggestion`.
public struct ExtractionReminderSuggestion: Codable, Equatable, Sendable {
    public var title: String
    public var remindAt: String
    public var confidence: Double

    private enum CodingKeys: String, CodingKey {
        case title
        case remindAt = "remind_at"
        case confidence
    }

    public init(title: String, remindAt: String, confidence: Double) {
        self.title = title
        self.remindAt = remindAt
        self.confidence = confidence
    }
}

/// Full extraction payload returned by the `extract_from_transcript` edge
/// function, decoded from its JSON response body. Mirrors `ExtractionResult`
/// in packages/shared/src/contracts/types.ts.
public struct ExtractionPayload: Codable, Equatable, Sendable {
    public var subjectNameGuess: ExtractionSubjectGuess?
    public var memoryDraft: ExtractionMemoryDraft?
    public var keyThings: [ExtractionSuggestion]
    public var reminderSuggestion: ExtractionReminderSuggestion?

    private enum CodingKeys: String, CodingKey {
        case subjectNameGuess = "subject_name_guess"
        case memoryDraft = "memory_draft"
        case keyThings = "key_things"
        case reminderSuggestion = "reminder_suggestion"
    }

    public init(
        subjectNameGuess: ExtractionSubjectGuess?,
        memoryDraft: ExtractionMemoryDraft?,
        keyThings: [ExtractionSuggestion],
        reminderSuggestion: ExtractionReminderSuggestion?
    ) {
        self.subjectNameGuess = subjectNameGuess
        self.memoryDraft = memoryDraft
        self.keyThings = keyThings
        self.reminderSuggestion = reminderSuggestion
    }
}

/// One caveat a decoded `ExtractionPayload` fails on `validate()`. Ports
/// the constraints `extractionResultSchema` (Zod) enforces in
/// packages/shared/src/extraction/validators.ts.
public enum ExtractionValidationError: Error, Equatable, Sendable {
    case invalidSubjectNameGuess
    case invalidMemoryDraft
    case tooManyKeyThings
    case invalidKeyThing(index: Int)
    case tooManyLabels(keyThingIndex: Int)
    case invalidLabel(keyThingIndex: Int, labelIndex: Int)
    case invalidReminderSuggestion
}

extension ExtractionPayload {
    /// Every caveat this payload fails against the shared extraction
    /// contract. Empty means the payload is valid. Ports
    /// `extractionResultSchema.safeParse` (Zod) from
    /// packages/shared/src/extraction/validators.ts:
    /// - a present `subject_name_guess` / `memory_draft` needs non-empty
    ///   (post-trim) text and a confidence in `0...1`
    /// - at most 5 key things, each with non-empty `id` / `text` and at
    ///   most 5 non-empty labels
    /// - a present `reminder_suggestion` needs non-empty `title`, an ISO
    ///   8601 UTC `remind_at`, and a confidence in `0...1`
    public func validate() -> [ExtractionValidationError] {
        var errors: [ExtractionValidationError] = []

        if let subjectNameGuess = subjectNameGuess,
           !Self.isValidGuess(text: subjectNameGuess.text, confidence: subjectNameGuess.confidence) {
            errors.append(.invalidSubjectNameGuess)
        }

        if let memoryDraft = memoryDraft,
           !Self.isValidGuess(text: memoryDraft.text, confidence: memoryDraft.confidence) {
            errors.append(.invalidMemoryDraft)
        }

        if keyThings.count > 5 {
            errors.append(.tooManyKeyThings)
        }

        for (index, keyThing) in keyThings.enumerated() {
            let hasEmptyIdOrText = Self.isBlank(keyThing.id) || Self.isBlank(keyThing.text)
            if hasEmptyIdOrText {
                errors.append(.invalidKeyThing(index: index))
            }
            if keyThing.labels.count > 5 {
                errors.append(.tooManyLabels(keyThingIndex: index))
            }
            for (labelIndex, label) in keyThing.labels.enumerated() where Self.isBlank(label) {
                errors.append(.invalidLabel(keyThingIndex: index, labelIndex: labelIndex))
            }
        }

        if let reminderSuggestion = reminderSuggestion {
            let hasValidTitle = !Self.isBlank(reminderSuggestion.title)
            let hasValidDate = Self.isValidISODateTime(reminderSuggestion.remindAt)
            let hasValidConfidence = Self.isValidConfidence(reminderSuggestion.confidence)
            if !hasValidTitle || !hasValidDate || !hasValidConfidence {
                errors.append(.invalidReminderSuggestion)
            }
        }

        return errors
    }

    /// Whether this payload satisfies every constraint `validate()` checks.
    public var isValid: Bool {
        validate().isEmpty
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isValidConfidence(_ confidence: Double) -> Bool {
        confidence >= 0 && confidence <= 1
    }

    private static func isValidGuess(text: String, confidence: Double) -> Bool {
        !isBlank(text) && isValidConfidence(confidence)
    }

    /// Matches Zod's `z.iso.datetime()` default (UTC only — a literal `Z`
    /// suffix, optional fractional seconds; a numeric offset like `+01:00`
    /// is rejected, matching validators.ts's default-options schema).
    private static func isValidISODateTime(_ value: String) -> Bool {
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}
