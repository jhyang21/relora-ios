import Testing
@testable import ReloraCore

@Suite("ContactMatching")
struct MatchingTests {
    private static func makeContact(
        id: String,
        name: String,
        lastInteractionAt: String = "2026-03-01T00:00:00.000Z"
    ) -> Contact {
        Contact(
            id: id,
            userID: "user-1",
            name: name,
            createdAt: "2026-03-01T00:00:00.000Z",
            updatedAt: "2026-03-01T00:00:00.000Z",
            lastInteractionAt: lastInteractionAt
        )
    }

    private static func ids(_ result: MatchResult) -> [String] {
        result.candidates.map(\.contactID)
    }

    // MARK: status handling

    @Test("returns idle when there is no usable evidence")
    func idleWhenNoEvidence() {
        let result = ContactMatching.matchVoiceCaptureContacts(
            contacts: [Self.makeContact(id: "alex", name: "Alex Johnson")],
            transcript: "",
            subjectNameGuess: nil,
            initialContactID: nil
        )

        #expect(result.candidates.isEmpty)
        #expect(result.defaultSelection == .notSet)
        #expect(result.status == .idle)
    }

    @Test("matches the initial contact when that is the only evidence")
    func matchesInitialContactAlone() {
        let result = ContactMatching.matchVoiceCaptureContacts(
            contacts: [Self.makeContact(id: "alex", name: "Alex Johnson"), Self.makeContact(id: "casey", name: "Casey Liu")],
            transcript: "",
            subjectNameGuess: nil,
            initialContactID: "alex"
        )

        #expect(result.status == .matched)
        #expect(result.defaultSelection == .contactID("alex"))
        #expect(result.candidates.first?.contactID == "alex")
        #expect(result.candidates.first?.reason == "Opened from this contact")
    }

    @Test("returns no_matches for short ambiguous guesses")
    func noMatchesForShortAmbiguousGuess() {
        let result = ContactMatching.matchVoiceCaptureContacts(
            contacts: [Self.makeContact(id: "alex", name: "Alex Johnson"), Self.makeContact(id: "ali", name: "Ali Rahman")],
            transcript: "",
            subjectNameGuess: "al",
            initialContactID: nil
        )

        #expect(result.candidates.isEmpty)
        #expect(result.defaultSelection == .new)
        #expect(result.status == .noMatches)
    }

    // MARK: subject-guess robustness

    @Test(
        "treats a noisy variant as a strong match for Muhamed",
        arguments: ["muhamed", "muhammed", "muhhammed", "mohamed"]
    )
    func noisyVariantsMatchMuhamed(subjectNameGuess: String) {
        let result = ContactMatching.matchVoiceCaptureContacts(
            contacts: [Self.makeContact(id: "muhamed", name: "Muhamed"), Self.makeContact(id: "ahmed", name: "Ahmed")],
            transcript: "Muhamed has daughter named Lucy.",
            subjectNameGuess: subjectNameGuess,
            initialContactID: nil
        )

        #expect(result.status == .matched)
        #expect(result.defaultSelection == .contactID("muhamed"))
        #expect(result.candidates.first?.contactID == "muhamed")
        if result.candidates.count > 1 {
            #expect(result.candidates[1].contactID != "ahmed")
        }
    }

    @Test("prefers the subject guess over transcript-wide mentions of other people")
    func prefersSubjectGuessOverTranscriptMentions() {
        let result = ContactMatching.matchVoiceCaptureContacts(
            contacts: [Self.makeContact(id: "muhamed", name: "Muhamed"), Self.makeContact(id: "ahmed", name: "Ahmed")],
            transcript: "Ahmed called earlier, but Muhamed has daughter named Lucy.",
            subjectNameGuess: "muhhammed",
            initialContactID: nil
        )

        #expect(result.status == .matched)
        #expect(result.defaultSelection == .contactID("muhamed"))
        #expect(Self.ids(result).first == "muhamed")
    }

    @Test("normalizes accents and hyphenated multi-token names")
    func normalizesAccentsAndHyphenatedNames() {
        let result = ContactMatching.matchVoiceCaptureContacts(
            contacts: [
                Self.makeContact(id: "mary-anne", name: "Mary-Anne Smith"),
                Self.makeContact(id: "mary", name: "Mary Smith"),
                Self.makeContact(id: "jose", name: "José Alvarez"),
            ],
            transcript: "Mary Anne Smith will join Jose Alvarez tomorrow.",
            subjectNameGuess: "mary anne smith",
            initialContactID: nil
        )

        #expect(result.status == .matched)
        #expect(result.defaultSelection == .contactID("mary-anne"))
        #expect(Array(Self.ids(result).prefix(2)) == ["mary-anne", "mary"])
        #expect(result.candidates[0].score > result.candidates[1].score)
    }

    @Test("penalizes extra unsupported tokens in the contact name")
    func penalizesExtraUnsupportedTokens() {
        let result = ContactMatching.matchVoiceCaptureContacts(
            contacts: [
                Self.makeContact(id: "ali", name: "Muhamed Ali"),
                Self.makeContact(id: "ali-hassan", name: "Muhamed Ali Hassan"),
            ],
            transcript: "Mohamed Ali sent the draft over.",
            subjectNameGuess: "mohamed ali",
            initialContactID: nil
        )

        #expect(result.status == .matched)
        #expect(Array(Self.ids(result).prefix(2)) == ["ali", "ali-hassan"])
        #expect(result.candidates[0].score > result.candidates[1].score)
    }

    // MARK: transcript-only behavior

    @Test("does not surface transcript-only weak overlaps as plausible matches")
    func transcriptOnlyWeakOverlapsRejected() {
        let result = ContactMatching.matchVoiceCaptureContacts(
            contacts: [Self.makeContact(id: "alex", name: "Alex Johnson"), Self.makeContact(id: "casey", name: "Casey Liu")],
            transcript: "Talked about the launch plan with Alex.",
            subjectNameGuess: nil,
            initialContactID: nil
        )

        #expect(result.candidates.isEmpty)
        #expect(result.defaultSelection == .new)
        #expect(result.status == .noMatches)
    }

    @Test("does not let transcript-only full-name mentions auto-select a contact")
    func transcriptOnlyFullNameDoesNotAutoSelect() {
        let result = ContactMatching.matchVoiceCaptureContacts(
            contacts: [Self.makeContact(id: "alex", name: "Alex Johnson"), Self.makeContact(id: "casey", name: "Casey Liu")],
            transcript: "Alex Johnson said to follow up next week.",
            subjectNameGuess: nil,
            initialContactID: nil
        )

        #expect(result.status == .noMatches)
        #expect(result.defaultSelection == .new)
    }

    // MARK: ranking and confidence

    @Test("auto-matches clear multi-token subject guesses and penalizes extra unsupported names")
    func autoMatchesClearMultiTokenGuess() {
        let result = ContactMatching.matchVoiceCaptureContacts(
            contacts: [Self.makeContact(id: "ali", name: "Muhamed Ali"), Self.makeContact(id: "hassan", name: "Mohamed Hassan")],
            transcript: "Mohamed Ali sent the draft over.",
            subjectNameGuess: "mohamed ali",
            initialContactID: nil
        )

        #expect(result.status == .matched)
        #expect(result.defaultSelection == .contactID("ali"))
        #expect(result.candidates.first?.contactID == "ali")
        #expect(result.candidates.first?.reason == "Strong subject-name match, supported by transcript")
        #expect(result.candidates.count > 1 && result.candidates[1].contactID == "hassan")
        #expect(result.candidates[0].score > result.candidates[1].score)
    }

    @Test("returns needs_review when the top two candidates are effectively tied")
    func needsReviewOnEffectiveTie() {
        let result = ContactMatching.matchVoiceCaptureContacts(
            contacts: [
                Self.makeContact(id: "older", name: "Priya Patel", lastInteractionAt: "2026-03-01T00:00:00.000Z"),
                Self.makeContact(id: "newer", name: "Priya Patel", lastInteractionAt: "2026-03-07T00:00:00.000Z"),
            ],
            transcript: "Need to call Priya Patel tomorrow.",
            subjectNameGuess: "priya patel",
            initialContactID: nil
        )

        #expect(result.status == .needsReview)
        #expect(result.defaultSelection == .notSet)
        #expect(Self.ids(result) == ["newer", "older"])
    }

    @Test("does not let recency outrank a materially better name match")
    func recencyDoesNotOutrankBetterNameMatch() {
        let result = ContactMatching.matchVoiceCaptureContacts(
            contacts: [
                Self.makeContact(id: "older", name: "Mohamed Ali", lastInteractionAt: "2026-03-01T00:00:00.000Z"),
                Self.makeContact(id: "newer", name: "Muhamed Ali", lastInteractionAt: "2026-03-07T00:00:00.000Z"),
            ],
            transcript: "",
            subjectNameGuess: "mohamed ali",
            initialContactID: nil
        )

        #expect(Self.ids(result).first == "older")
        #expect(result.candidates[0].score > result.candidates[1].score)
    }

    @Test("uses deterministic fallback ordering when score and recency are tied")
    func deterministicFallbackOrdering() {
        let result = ContactMatching.matchVoiceCaptureContacts(
            contacts: [
                Self.makeContact(id: "b-contact", name: "Priya Patel", lastInteractionAt: "2026-03-01T00:00:00.000Z"),
                Self.makeContact(id: "a-contact", name: "Priya Patel", lastInteractionAt: "2026-03-01T00:00:00.000Z"),
            ],
            transcript: "",
            subjectNameGuess: "priya patel",
            initialContactID: nil
        )

        #expect(Self.ids(result) == ["a-contact", "b-contact"])
    }

    @Test("caps the candidate list at four entries")
    func capsCandidateListAtFour() {
        let contacts = (1...5).map { Self.makeContact(id: "\($0)", name: "Priya Patel") }
        let result = ContactMatching.matchVoiceCaptureContacts(
            contacts: contacts,
            transcript: "",
            subjectNameGuess: "priya patel",
            initialContactID: nil
        )

        #expect(result.candidates.count == 4)
    }

    // MARK: initial-contact conflicts

    @Test("falls back to review when initial contact context conflicts with a strong subject guess")
    func fallsBackToReviewOnInitialContactConflict() {
        let result = ContactMatching.matchVoiceCaptureContacts(
            contacts: [Self.makeContact(id: "alex", name: "Alex Johnson"), Self.makeContact(id: "casey", name: "Casey Liu")],
            transcript: "Casey asked about dinner plans.",
            subjectNameGuess: "Casey Liu",
            initialContactID: "alex"
        )

        #expect(result.status == .needsReview)
        #expect(result.defaultSelection == .notSet)
        #expect(result.candidates.first?.contactID == "alex")
        #expect(result.candidates.first?.reason == "Opened from this contact")
        #expect(result.candidates.count > 1 && result.candidates[1].contactID == "casey")
    }

    @Test("keeps the initial contact matched when other evidence is weak")
    func keepsInitialContactMatchedWhenEvidenceWeak() {
        let result = ContactMatching.matchVoiceCaptureContacts(
            contacts: [Self.makeContact(id: "alex", name: "Alex Johnson"), Self.makeContact(id: "casey", name: "Casey Liu")],
            transcript: "Alex mentioned that Casey may join later.",
            subjectNameGuess: "alex",
            initialContactID: "alex"
        )

        #expect(result.status == .matched)
        #expect(result.defaultSelection == .contactID("alex"))
        #expect(Self.ids(result).first == "alex")
    }
}
