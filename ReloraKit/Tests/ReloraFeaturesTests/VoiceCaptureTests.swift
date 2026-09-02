import Foundation
import Testing
import ReloraCore
import ReloraData
@testable import ReloraFeatures

// MARK: - Fixtures

private let fixedNow = ReloraTimestamp.parse("2026-08-31T12:00:00.000Z")!
private let fixedNowISO = ReloraTimestamp.from(fixedNow)

private func suggestion(_ id: String, _ text: String, labels: [String] = []) -> ExtractionSuggestion {
    ExtractionSuggestion(id: id, text: text, labels: labels)
}

private func extraction(
    subject: String? = nil,
    draft: String? = nil,
    keyThings: [ExtractionSuggestion] = [],
    reminder: ExtractionReminderSuggestion? = nil
) -> ExtractionPayload {
    ExtractionPayload(
        subjectNameGuess: subject.map { ExtractionSubjectGuess(text: $0, confidence: 0.9) },
        memoryDraft: draft.map { ExtractionMemoryDraft(text: $0, confidence: 0.8) },
        keyThings: keyThings,
        reminderSuggestion: reminder
    )
}

private let reminderSuggestion = ExtractionReminderSuggestion(
    title: "  Send the deck  ",
    remindAt: "2026-09-05T17:00:00.000Z",
    confidence: 0.7
)

private func candidate(_ id: String, _ name: String, score: Double, reason: String) -> MatchCandidate {
    MatchCandidate(contactID: id, name: name, score: score, reason: reason)
}

private func contact(_ id: String, _ name: String) -> Contact {
    Contact(
        id: id,
        userID: "user-1",
        name: name,
        descriptors: [],
        createdAt: fixedNowISO,
        updatedAt: fixedNowISO
    )
}

private func item(
    _ id: String,
    kind: VoiceReviewItemKind,
    text: String,
    keep: Bool = true,
    labels: [String] = []
) -> VoiceReviewItem {
    VoiceReviewItem(id: id, kind: kind, text: text, labels: labels, keep: keep)
}

// MARK: - Quota gate

@Suite("Voice quota gate")
struct VoiceQuotaGateTests {

    private func snapshot(_ planID: QuotaPolicy.PlanID, total: Int, month: Int = 0) -> VoiceAccessSnapshot {
        VoiceAccessSnapshot(
            evaluation: QuotaPolicy.evaluate(
                planID: planID,
                usage: QuotaPolicy.UsageSummary(
                    totalProcessedNotes: total,
                    processedNotesThisMonth: month
                )
            )
        )
    }

    @Test func aFreshFreeInstallRecordsForOneMinute() {
        #expect(VoiceQuotaGate.decide(.freeAndUnused) == .record(cap: .seconds(60)))
    }

    @Test func theFifthFreeNoteIsTheLastOne() {
        #expect(VoiceQuotaGate.decide(snapshot(.free, total: 4)) == .record(cap: .seconds(60)))
        #expect(VoiceQuotaGate.decide(snapshot(.free, total: 5)) == .paywall(.freeLimitReached))
    }

    /// Plus is counted per month, not per lifetime: someone well past five
    /// notes overall still records, and only the monthly ceiling stops them.
    @Test func plusIsGatedOnTheMonthAndProNeverIs() {
        #expect(VoiceQuotaGate.decide(snapshot(.plus, total: 400, month: 99)) == .record(cap: .seconds(60)))
        #expect(VoiceQuotaGate.decide(snapshot(.plus, total: 400, month: 100)) == .paywall(.plusQuotaReached))
        #expect(VoiceQuotaGate.decide(snapshot(.pro, total: 9_000, month: 9_000)) == .record(cap: .seconds(300)))
    }

    /// A block with no reason attached is treated as the hard free limit —
    /// the wall a user is most likely behind, and the only one the paywall
    /// can do something about without knowing more.
    @Test func aMissingBlockReasonFallsBackToTheFreeLimit() {
        #expect(VoiceQuotaGate.paywallReason(for: nil) == .freeLimitReached)
        #expect(VoiceQuotaGate.paywallReason(for: .freeLimitReached) == .freeLimitReached)
        #expect(VoiceQuotaGate.paywallReason(for: .plusQuotaReached) == .plusQuotaReached)
    }

    /// A mid-processing 402 carries the server's own verdict on which wall
    /// was hit. Losing the code would send a Plus subscriber to the
    /// free-limit paywall, which tells them to buy the plan they have.
    @Test func aServer402OpensTheWallItsCodeNames() {
        #expect(
            VoiceQuotaGate.paywallReason(forServerCode: BackendError.plusQuotaReached)
                == .plusQuotaReached
        )
        #expect(
            VoiceQuotaGate.paywallReason(forServerCode: BackendError.freeLimitReached)
                == .freeLimitReached
        )
        #expect(VoiceQuotaGate.paywallReason(forServerCode: "SOMETHING_ELSE") == .freeLimitReached)
    }

    /// Pro is already at the longest cap, so its alert acknowledges and
    /// offers nothing to buy.
    @Test func onlyPlansBelowProAreOfferedAnUpgradeAtTheCap() {
        #expect(VoiceQuotaGate.offersUpgrade(for: .free))
        #expect(VoiceQuotaGate.offersUpgrade(for: .plus))
        #expect(VoiceQuotaGate.offersUpgrade(for: .pro) == false)
        #expect(VoiceQuotaGate.durationLimitMessage(for: .pro).contains("5 minutes"))
        #expect(VoiceQuotaGate.durationLimitMessage(for: .free).contains("Upgrade to Pro"))
    }
}

// MARK: - Review state machine

@Suite("Voice review items")
struct VoiceReviewTests {

    @Test func extractionBecomesADraftThenTheKeyThings() throws {
        let items = VoiceReview.buildItems(
            extraction: extraction(
                draft: "  Coffee with Ada.  ",
                keyThings: [suggestion("kt-1", "Allergic to shellfish."), suggestion("kt-2", "Runs on Sundays.")]
            ),
            transcript: "Had coffee with Ada."
        )

        #expect(items.map(\.id) == [VoiceReviewItem.memoryDraftID, "kt-1", "kt-2"])
        #expect(items.map(\.kind) == [.memory, .keyThing, .keyThing])
        let draft = items[0]
        #expect(draft.text == "Coffee with Ada.")
        let labels = draft.labels
        #expect(labels == VoiceReviewItem.memoryLabels)
        #expect(items.allSatisfy(\.keep))
    }

    /// With no usable draft the transcript itself becomes the note, so the
    /// review always opens on something to edit rather than an empty screen.
    @Test func aWhitespaceOnlyDraftFallsBackToTheTranscript() {
        let items = VoiceReview.buildItems(
            extraction: extraction(draft: "   ", keyThings: [suggestion("kt-1", "Runs on Sundays.")]),
            transcript: "  Had coffee with Ada.  "
        )

        #expect(items.map(\.id) == ["kt-1", VoiceReviewItem.fallbackTranscriptID])
        #expect(items[1].text == "Had coffee with Ada.")
        #expect(items[1].kind == .memory)
    }

    /// A guest's transcription never reaches the server, so the fallback is
    /// empty and the placeholder is the whole instruction.
    @Test func noExtractionAndNoTranscriptStillOffersOneEmptyMemory() {
        let items = VoiceReview.buildItems(extraction: nil, transcript: "")

        #expect(items.count == 1)
        #expect(items[0].id == VoiceReviewItem.fallbackTranscriptID)
        #expect(items[0].text.isEmpty)
    }

    /// The ensure checks kind and text, never `keep`. Switching the one
    /// memory off must not grow a second one underneath it — that would make
    /// the toggle look broken.
    @Test func switchingTheOnlyMemoryOffDoesNotAppendAnother() {
        let existing = [item("memory-draft", kind: .memory, text: "Coffee with Ada.", keep: false)]
        #expect(VoiceReview.ensuringMemoryDraft(existing, transcript: "Had coffee.") == existing)
    }

    @Test func onlyKeptItemsWithTextAreAccepted() {
        let items = [
            item("m", kind: .memory, text: "Coffee with Ada."),
            item("kt-1", kind: .keyThing, text: "Allergic to shellfish.", keep: false),
            item("kt-2", kind: .keyThing, text: "   "),
            item("kt-3", kind: .keyThing, text: "Runs on Sundays.")
        ]

        #expect(VoiceReview.acceptedItems(items).map(\.id) == ["m", "kt-3"])
    }

    /// Editing leaves the text exactly as typed. Trimming here would eat the
    /// space before the next word; the save path trims instead.
    @Test func editingKeepsTrailingSpaceAndTouchesNothingElse() {
        let items = [
            item("m", kind: .memory, text: "Coffee"),
            item("kt-1", kind: .keyThing, text: "Shellfish")
        ]

        let edited = VoiceReview.settingText(items, id: "m", text: "Coffee with ")
        #expect(edited[0].text == "Coffee with ")
        #expect(edited[1] == items[1])
    }

    @Test func toggleFlipsOneItemAndOnlyThatItem() {
        let items = [
            item("m", kind: .memory, text: "Coffee"),
            item("kt-1", kind: .keyThing, text: "Shellfish")
        ]

        let once = VoiceReview.togglingKeep(items, id: "kt-1")
        #expect(once[0].keep)
        #expect(once[1].keep == false)
        #expect(VoiceReview.togglingKeep(once, id: "kt-1") == items)
    }

    @Test func sectionsSplitByKindAndKeepTheirOrder() {
        let sections = VoiceReview.sections([
            item("m1", kind: .memory, text: "One"),
            item("kt-1", kind: .keyThing, text: "Two"),
            item("m2", kind: .memory, text: "Three")
        ])

        #expect(sections.memories.map(\.id) == ["m1", "m2"])
        #expect(sections.keyThings.map(\.id) == ["kt-1"])
    }

    /// A suggestion only exists because the user said something that sounded
    /// like a commitment, so it starts accepted and the toggle says otherwise.
    @Test func aSuggestedReminderStartsAccepted() {
        #expect(VoiceReview.initialReminderSelection(reminderSuggestion))
        #expect(VoiceReview.initialReminderSelection(nil) == false)
    }
}

// MARK: - Matcher to chips

@Suite("Voice contact resolution")
struct VoiceContactResolutionTests {

    private let result = MatchResult(
        candidates: [
            candidate("c-1", "Ada Lovelace", score: 0.9, reason: "Strong subject-name match"),
            candidate("c-2", "Ada Byron", score: 0.4, reason: "Partial name match")
        ],
        defaultSelection: .contactID("c-1"),
        status: .matched
    )

    /// "Someone new" is always last and always there: a guess the user cannot
    /// decline is not a guess.
    @Test func chipsKeepCandidateOrderAndAlwaysEndWithSomeoneNew() {
        let chips = VoiceContactResolution.chips(for: result, newContactName: "  Grace Hopper  ")

        #expect(chips.map(\.id) == ["c-1", "c-2", "new"])
        #expect(chips[0].reason == "Strong subject-name match")
        #expect(chips[2].name == "Grace Hopper")
        #expect(chips[2].reason == nil)
    }

    @Test func theNewChipIsLabelledGenericallyUntilThereIsAName() {
        let chips = VoiceContactResolution.chips(for: result, newContactName: "   ")
        #expect(chips.last?.name == "Someone new")
    }

    /// A composer opened from a contact is about that contact, whatever the
    /// transcript sounded like.
    @Test func openingFromAContactOverridesTheMatch() {
        let selection = VoiceContactResolution.initialSelection(result: result, initialContactID: "c-9")
        #expect(selection == .existing(contactID: "c-9"))
    }

    @Test func onlyAConfidentMatchPreselectsAnything() {
        #expect(
            VoiceContactResolution.initialSelection(result: result, initialContactID: nil)
                == .existing(contactID: "c-1")
        )

        let unsure = MatchResult(
            candidates: result.candidates,
            defaultSelection: .contactID("c-1"),
            status: .needsReview
        )
        #expect(VoiceContactResolution.initialSelection(result: unsure, initialContactID: nil) == nil)

        let noneFound = MatchResult(candidates: [], defaultSelection: .new, status: .matched)
        #expect(VoiceContactResolution.initialSelection(result: noneFound, initialContactID: nil) == .new)

        let unset = MatchResult(candidates: [], defaultSelection: .notSet, status: .matched)
        #expect(VoiceContactResolution.initialSelection(result: unset, initialContactID: nil) == nil)
    }

    /// An empty string is the same as no id at all — it arrives that way from
    /// a route parameter, and treating it as a contact would preselect a chip
    /// nothing matches.
    @Test func anEmptyInitialContactIDIsIgnored() {
        #expect(
            VoiceContactResolution.initialSelection(result: result, initialContactID: "")
                == .existing(contactID: "c-1")
        )
    }

    @Test func newContactNamePrefersTheTranscriptGuess() {
        #expect(
            VoiceContactResolution.initialNewContactName(
                subjectNameGuess: "  Ada  ",
                initialContactName: "Grace Hopper"
            ) == "Ada"
        )
        #expect(
            VoiceContactResolution.initialNewContactName(
                subjectNameGuess: "   ",
                initialContactName: "  Grace Hopper  "
            ) == "Grace Hopper"
        )
        #expect(
            VoiceContactResolution.initialNewContactName(
                subjectNameGuess: nil,
                initialContactName: nil
            ).isEmpty
        )
    }

    /// A `.new` chip with no name typed is not a selection yet — which is
    /// what keeps Save disabled rather than writing a nameless contact.
    @Test func aNewChipWithoutANameIsNotAChoice() {
        #expect(VoiceContactResolution.canConfirm(selection: .new, newContactName: "   ") == false)
        #expect(VoiceContactResolution.canConfirm(selection: .new, newContactName: "Ada"))
        #expect(VoiceContactResolution.canConfirm(selection: .existing(contactID: "c-1"), newContactName: ""))
        #expect(VoiceContactResolution.canConfirm(selection: nil, newContactName: "Ada") == false)
    }

    @Test func resolveTrimsTheNewNameAndLooksUpTheExistingOne() {
        let names = ["c-1": "Ada Lovelace"]

        #expect(
            VoiceContactResolution.resolve(
                selection: .existing(contactID: "c-1"),
                newContactName: "",
                nameForContactID: { names[$0] }
            ) == .existing(contactID: "c-1", contactName: "Ada Lovelace")
        )

        #expect(
            VoiceContactResolution.resolve(
                selection: .new,
                newContactName: "  Grace Hopper  ",
                nameForContactID: { names[$0] }
            ) == .new(name: "Grace Hopper")
        )

        // A candidate whose contact has since been deleted resolves to
        // nothing rather than to a row that is no longer there.
        #expect(
            VoiceContactResolution.resolve(
                selection: .existing(contactID: "c-gone"),
                newContactName: "",
                nameForContactID: { names[$0] }
            ) == nil
        )
    }
}

// MARK: - Picker list

@Suite("Voice contact picker list")
struct VoiceContactPickerListTests {

    private let candidates = [
        candidate("c-1", "Ada Lovelace", score: 0.9, reason: "Strong subject-name match")
    ]
    private let contacts = [
        contact("c-1", "Ada Lovelace"),
        contact("c-2", "Grace Hopper"),
        contact("c-3", "   ")
    ]

    /// Scored candidates first, then the rest of the address book. A note
    /// that matched nobody must still offer the contacts that already exist.
    @Test func withNoQueryCandidatesLeadAndEveryoneElseFollows() {
        let options = VoiceContactPickerList.options(
            candidates: candidates,
            contacts: contacts,
            query: ""
        )

        #expect(options.map(\.id) == ["c-1", "c-2"])
        #expect(options[0].reason == "Strong subject-name match")
        // Offered because it exists, not because the transcript pointed at it.
        #expect(options[1].reason == nil)
    }

    @Test func aQuerySearchesTheWholeAddressBookCaseInsensitively() {
        let options = VoiceContactPickerList.options(
            candidates: candidates,
            contacts: contacts,
            query: "  HOPPER "
        )

        #expect(options.map(\.id) == ["c-2"])
    }

    /// Nothing to show on the row and nothing to search against.
    @Test func namelessContactsAreNeverOffered() {
        let options = VoiceContactPickerList.options(candidates: [], contacts: contacts, query: "")
        #expect(options.map(\.id) == ["c-1", "c-2"])
    }

    @Test func theListIsCappedInBothBranches() {
        let many = (0..<40).map { contact("c-\($0)", "Person \($0)") }

        #expect(
            VoiceContactPickerList.options(candidates: [], contacts: many, query: "").count
                == VoiceContactPickerList.limit
        )
        #expect(
            VoiceContactPickerList.options(candidates: [], contacts: many, query: "Person").count
                == VoiceContactPickerList.limit
        )
    }
}

// MARK: - Meter

@Suite("Voice meter")
struct VoiceMeterTests {

    /// The scale conversion is the whole point of `normalize`: RN's constants
    /// live on a normalized dBFS scale, and `RecordingController` emits linear
    /// RMS. Silence must land at the floor and a full-scale sample at the top.
    @Test func normalizeMapsLinearRMSOntoTheNormalizedDecibelScale() {
        #expect(VoiceMeter.normalize(rms: 0) == 0)
        #expect(VoiceMeter.normalize(rms: 1) == 1)
        // -60 dBFS is the bottom of the scale.
        #expect(VoiceMeter.normalize(rms: 0.001) < 0.001)
        // -40 dBFS sits a third of the way up.
        #expect(abs(VoiceMeter.normalize(rms: 0.01) - 1.0 / 3.0) < 0.01)
    }

    /// The bug this guards against: applying the ported threshold straight to
    /// linear RMS would put the speech gate at a level nothing short of
    /// shouting reaches. Ordinary speech must clear it and room tone must not.
    @Test func ordinarySpeechClearsTheThresholdAndRoomToneDoesNot() {
        #expect(VoiceMeter.normalize(rms: 0.05) > VoiceMeter.silenceThreshold)
        #expect(VoiceMeter.normalize(rms: 0.0005) < VoiceMeter.silenceThreshold)
    }

    @Test func blendLeansTowardTheNewSampleAndDecaysWithoutOne() {
        #expect(abs(VoiceMeter.blend(current: 0, next: 1) - 0.45) < 1e-5)
        #expect(abs(VoiceMeter.blend(current: 0.5, next: nil) - 0.35) < 1e-5)
    }

    /// The dead band returns the current value unchanged, so a meter sitting
    /// near zero stops redrawing instead of creeping.
    @Test func changesTooSmallToSeeAreNotApplied() {
        #expect(VoiceMeter.blend(current: 0.01, next: nil) == 0.01)
        #expect(VoiceMeter.blend(current: 0.5, next: 0.5) == 0.5)
    }

    @Test func aLoudSampleMarksSpeech() {
        var meter = VoiceMeter()
        #expect(meter.tick(rms: 0.05, elapsed: .zero) == .keepRecording)
        #expect(meter.state == .speaking)
        #expect(meter.level > 0)
    }

    @Test func tenSecondsOfSilenceAfterSpeechEndsTheRecording() {
        var meter = VoiceMeter()
        _ = meter.tick(rms: 0.05, elapsed: .zero)

        #expect(meter.tick(rms: 0, elapsed: .seconds(9)) == .keepRecording)
        #expect(meter.tick(rms: 0, elapsed: .seconds(10)) == .keepRecording)
        #expect(meter.tick(rms: 0, elapsed: .seconds(11)) == .stopForSilence)
    }

    /// Someone gathering their thoughts is not finished. Below the minimum the
    /// meter also drops back to `listening`, which is RN's behavior — the
    /// sticky `speaking` state only holds once past that floor.
    @Test func nothingAutoStopsBeforeTheMinimumRecordingLength() {
        var meter = VoiceMeter()
        _ = meter.tick(rms: 0.05, elapsed: .zero)

        #expect(meter.tick(rms: 0, elapsed: .milliseconds(2_400)) == .keepRecording)
        #expect(meter.state == .listening)
    }

    /// A recorder that stopped answering is not a room that went quiet. A nil
    /// sample neither counts as speech nor arms the auto-stop, so a device
    /// with no metering records until the user stops it.
    @Test func missingSamplesNeverEndTheRecording() {
        var meter = VoiceMeter()
        _ = meter.tick(rms: 0.05, elapsed: .zero)

        #expect(meter.tick(rms: nil, elapsed: .seconds(60)) == .keepRecording)
        #expect(meter.state == .speaking)
    }

    @Test func historyIsBoundedToWhatTheMeterDraws() {
        var meter = VoiceMeter()
        for step in 0..<(VoiceMeter.historyLength * 2) {
            _ = meter.tick(rms: 0.05, elapsed: .milliseconds(120 * step))
        }

        #expect(meter.history.count == VoiceMeter.historyLength)
    }

    @Test func finishingStopsTheMeterAndSaysSo() {
        var meter = VoiceMeter()
        _ = meter.tick(rms: 0.05, elapsed: .zero)
        meter.finish()

        #expect(meter.state == .finishing)
        #expect(meter.level == 0)
    }
}

// MARK: - Copy

@Suite("Voice capture copy")
struct VoiceCaptureCopyTests {

    /// The difference between a slow app and a broken one. The message
    /// escalates once, at thirty seconds, and never before.
    @Test func theProcessingNoteEscalatesAtThirtySeconds() {
        #expect(VoiceCaptureCopy.processingStatus(slowMarkSeconds: 0) == "Still polishing that note...")
        #expect(VoiceCaptureCopy.processingStatus(slowMarkSeconds: 15) == "Still polishing that note...")
        #expect(VoiceCaptureCopy.processingStatus(slowMarkSeconds: 30) == "Taking longer than usual...")
        #expect(VoiceCaptureCopy.processingStatus(slowMarkSeconds: 45) == "Taking longer than usual...")
    }

    /// M7: the realtime branch M6 left unported. The two lines must never
    /// swap — promising a live transcript a capture that fell back to
    /// batch cannot produce is exactly the lie the doc comment warns
    /// against.
    @Test func recordingSubtitlePicksTheRealtimeLineOnlyWhenLive() {
        #expect(
            VoiceCaptureCopy.recordingSubtitle(isLiveTranscribing: true)
                == "You will see the transcript build while you talk."
        )
        #expect(
            VoiceCaptureCopy.recordingSubtitle(isLiveTranscribing: false)
                == "Pause when you are done and we will pull out the note for you."
        )
    }

    @Test func theTimerShowsTheCapBesideTheElapsedTime() {
        #expect(VoiceElapsedFormat.label(elapsed: .seconds(12), cap: .seconds(60)) == "0:12 of 1:00")
        #expect(VoiceElapsedFormat.label(elapsed: .zero, cap: .seconds(300)) == "0:00 of 5:00")
        #expect(VoiceElapsedFormat.clock(.seconds(125)) == "2:05")
    }

    /// Said in words for VoiceOver rather than a colon a screen reader spells
    /// out one character at a time.
    @Test func voiceOverHearsTheTimerAsWords() {
        #expect(
            VoiceElapsedFormat.accessibilityLabel(elapsed: .seconds(12), cap: .seconds(60))
                == "12 seconds recorded of 1 minute"
        )
        #expect(
            VoiceElapsedFormat.accessibilityLabel(elapsed: .seconds(61), cap: .seconds(300))
                == "1 minute 1 second recorded of 5 minutes"
        )
        #expect(
            VoiceElapsedFormat.accessibilityLabel(elapsed: .zero, cap: .seconds(60))
                == "0 seconds recorded of 1 minute"
        )
    }
}

// MARK: - Save transaction: planning

@Suite("Voice save plan")
struct VoiceSavePlanTests {

    private func input(
        selection: VoiceContactSelection = .new(name: "  Ada Lovelace  "),
        items: [VoiceReviewItem]? = nil,
        transcript: String = "  Had coffee with Ada.  ",
        persistTranscript: Bool = true,
        reminder: ExtractionReminderSuggestion? = reminderSuggestion,
        acceptReminder: Bool = true,
        reminderRemindAt: String? = nil,
        audioLocalURI: String? = "file:///tmp/capture.m4a",
        recordsUsageEvent: Bool = true
    ) -> VoiceSaveInput {
        VoiceSaveInput(
            userID: "user-1",
            selection: selection,
            items: items ?? [
                item("memory-draft", kind: .memory, text: "  Coffee with Ada.  ", labels: VoiceReviewItem.memoryLabels),
                item("kt-1", kind: .keyThing, text: "  Allergic to shellfish.  "),
                item("kt-2", kind: .keyThing, text: "Runs on Sundays.", keep: false),
                item("kt-3", kind: .keyThing, text: "    ")
            ],
            transcript: transcript,
            persistTranscript: persistTranscript,
            reminderSuggestion: reminder,
            acceptReminder: acceptReminder,
            reminderRemindAt: reminderRemindAt,
            audioLocalURI: audioLocalURI,
            recordsUsageEvent: recordsUsageEvent
        )
    }

    /// Every text field is trimmed on the way to a row — including the
    /// reminder title, which RN leaves as the model wrote it.
    @Test func everythingWrittenIsTrimmed() throws {
        var ids = VoiceSaveIDs()
        let plan = try VoiceSaveTransaction.plan(input(), ids: &ids, now: fixedNow)

        #expect(plan.contact?.name == "Ada Lovelace")
        #expect(plan.memory?.text == "Coffee with Ada.")
        #expect(plan.memory?.transcript == "Had coffee with Ada.")
        #expect(plan.keyThings.map(\.text) == ["Allergic to shellfish."])
        #expect(plan.reminder?.title == "Send the deck")
    }

    @Test func theMemoryCarriesTheAudioTheLabelsAndItsSource() throws {
        var ids = VoiceSaveIDs()
        let plan = try VoiceSaveTransaction.plan(input(), ids: &ids, now: fixedNow)
        let memory = try #require(plan.memory)

        #expect(memory.audioLocalURI == "file:///tmp/capture.m4a")
        #expect(memory.labels == VoiceReviewItem.memoryLabels)
        #expect(memory.source == .voice)
        #expect(memory.contactID == plan.contactID)
        #expect(memory.createdAt == fixedNowISO)
    }

    /// Transcripts are kept only when the setting is on and the text came
    /// back from the server. A guest's self-written note has none to keep.
    @Test func aTranscriptIsOnlyStoredWhenItIsMeantToBe() throws {
        var ids = VoiceSaveIDs()
        let plan = try VoiceSaveTransaction.plan(
            input(persistTranscript: false),
            ids: &ids,
            now: fixedNow
        )

        #expect(plan.memory?.transcript == nil)
        // The note itself is unaffected — only the raw material is dropped.
        #expect(plan.memory?.text == "Coffee with Ada.")
    }

    /// A capture is one thing that happened, so it is one timeline entry
    /// however many memory drafts the review list holds.
    @Test func onlyTheFirstMemoryIsWritten() throws {
        var ids = VoiceSaveIDs()
        let plan = try VoiceSaveTransaction.plan(
            input(items: [
                item("memory-draft", kind: .memory, text: "Coffee with Ada."),
                item("fallback-transcript", kind: .memory, text: "Had coffee with Ada.")
            ]),
            ids: &ids,
            now: fixedNow
        )

        #expect(plan.memory?.text == "Coffee with Ada.")
    }

    /// M8 owns scheduling. The row lands now and the notification is attached
    /// later, which is also what makes a reminder survive a denied permission.
    @Test func theReminderLinksToTheMemoryAndCarriesNoNotificationYet() throws {
        var ids = VoiceSaveIDs()
        let plan = try VoiceSaveTransaction.plan(input(), ids: &ids, now: fixedNow)
        let reminder = try #require(plan.reminder)

        #expect(reminder.memoryID == plan.memory?.id)
        #expect(reminder.notificationID == nil)
        #expect(reminder.status == .scheduled)
        #expect(reminder.remindAt == "2026-09-05T17:00:00.000Z")
    }

    @Test func movingTheSuggestedDateOverridesTheSuggestion() throws {
        var ids = VoiceSaveIDs()
        let plan = try VoiceSaveTransaction.plan(
            input(reminderRemindAt: "2026-09-06T09:00:00.000Z"),
            ids: &ids,
            now: fixedNow
        )

        #expect(plan.reminder?.remindAt == "2026-09-06T09:00:00.000Z")
    }

    @Test func decliningTheReminderWritesNoReminderRow() throws {
        var ids = VoiceSaveIDs()
        let plan = try VoiceSaveTransaction.plan(input(acceptReminder: false), ids: &ids, now: fixedNow)
        #expect(plan.reminder == nil)
    }

    /// A capture can be a reminder and nothing else. The link is nil rather
    /// than a failure.
    @Test func aReminderCanBeSavedWithNoMemoryBehindIt() throws {
        var ids = VoiceSaveIDs()
        let plan = try VoiceSaveTransaction.plan(
            input(
                items: [item("memory-draft", kind: .memory, text: "Coffee with Ada.", keep: false)],
                transcript: "   "
            ),
            ids: &ids,
            now: fixedNow
        )

        #expect(plan.memory == nil)
        #expect(plan.reminder?.memoryID == nil)
    }

    /// A user who switched the one memory off still gets the transcript saved
    /// as a note — but only when there is a transcript to make a note out of.
    @Test func theTranscriptIsSavedEvenAfterTheMemoryIsSwitchedOff() throws {
        var ids = VoiceSaveIDs()
        let plan = try VoiceSaveTransaction.plan(
            input(
                items: [item("memory-draft", kind: .memory, text: "Coffee with Ada.", keep: false)],
                acceptReminder: false
            ),
            ids: &ids,
            now: fixedNow
        )

        #expect(plan.memory?.text == "Had coffee with Ada.")
    }

    @Test func nothingKeptAndNoReminderIsNotASave() {
        var ids = VoiceSaveIDs()
        #expect(throws: VoiceSaveError.noReviewItems) {
            _ = try VoiceSaveTransaction.plan(
                input(
                    items: [item("memory-draft", kind: .memory, text: "Coffee with Ada.", keep: false)],
                    transcript: "   ",
                    acceptReminder: false
                ),
                ids: &ids,
                now: fixedNow
            )
        }
    }

    /// The ledger asymmetry: a signed-in user's note was counted by
    /// `transcribe_audio` on the server before it ever came back, so writing
    /// one here would charge them twice.
    @Test func onlyAGuestSpendsQuotaFromTheClient() throws {
        var guestIDs = VoiceSaveIDs()
        let guest = try VoiceSaveTransaction.plan(input(), ids: &guestIDs, now: fixedNow)
        let event = try #require(guest.usageEvent)
        #expect(event.source == QuotaPolicy.clientUsageEventSource)
        #expect(event.source == "voice_capture_review")
        #expect(event.processedAt == fixedNowISO)
        #expect(event.serverSyncedAt == nil)

        var signedInIDs = VoiceSaveIDs()
        let signedIn = try VoiceSaveTransaction.plan(
            input(recordsUsageEvent: false),
            ids: &signedInIDs,
            now: fixedNow
        )
        #expect(signedIn.usageEvent == nil)
    }

    /// A save that failed halfway and is tried again must land the same rows,
    /// not a second set. Fresh ids would turn one interrupted save into two
    /// memories about the same conversation — and two spent notes.
    @Test func aRetryReusesEveryID() throws {
        var ids = VoiceSaveIDs()
        let first = try VoiceSaveTransaction.plan(input(), ids: &ids, now: fixedNow)
        let second = try VoiceSaveTransaction.plan(input(), ids: &ids, now: fixedNow)

        #expect(first.contactID == second.contactID)
        #expect(first.memory?.id == second.memory?.id)
        #expect(first.keyThings.map(\.id) == second.keyThings.map(\.id))
        #expect(first.reminder?.id == second.reminder?.id)
        #expect(first.usageEvent?.id == second.usageEvent?.id)
    }

    /// An existing contact is left untouched: nothing about a voice note
    /// should rewrite the name, phone, or email already on the row.
    @Test func choosingAnExistingContactWritesNoContactRow() throws {
        var ids = VoiceSaveIDs()
        let plan = try VoiceSaveTransaction.plan(
            input(selection: .existing(contactID: "c-1", contactName: "Ada Lovelace")),
            ids: &ids,
            now: fixedNow
        )

        #expect(plan.contact == nil)
        #expect(plan.contactID == "c-1")
    }
}

// MARK: - Save transaction: the write

@Suite("Voice save write")
struct VoiceSaveWriteTests {

    private func plannedSave(recordsUsageEvent: Bool = true) throws -> VoiceCapturePlan {
        var ids = VoiceSaveIDs()
        return try VoiceSaveTransaction.plan(
            VoiceSaveInput(
                userID: "user-1",
                selection: .new(name: "  Ada Lovelace  "),
                items: [
                    item("memory-draft", kind: .memory, text: "  Coffee with Ada.  ", labels: VoiceReviewItem.memoryLabels),
                    item("kt-1", kind: .keyThing, text: "  Allergic to shellfish.  "),
                    item("kt-2", kind: .keyThing, text: "Runs on Sundays.")
                ],
                transcript: "  Had coffee with Ada.  ",
                persistTranscript: true,
                reminderSuggestion: reminderSuggestion,
                acceptReminder: true,
                audioLocalURI: "file:///tmp/capture.m4a",
                recordsUsageEvent: recordsUsageEvent
            ),
            ids: &ids,
            now: fixedNow
        )
    }

    @Test func oneCaptureLandsAContactAMemoryItsKeyThingsAndAReminder() async throws {
        let database = try AppDatabase.inMemory()
        let plan = try plannedSave()

        let result = try await VoiceSaveTransaction.execute(plan, database: database)

        #expect(result.createdNewContact)
        #expect(result.memoryCount == 1)
        #expect(result.keyThingCount == 2)
        #expect(result.reminderSaved)
        #expect(result.contactID == plan.contactID)

        let contacts = try ContactRepository(database: database).list(userID: "user-1")
        #expect(contacts.map(\.name) == ["Ada Lovelace"])

        let memories = try MemoryRepository(database: database).list(contactID: plan.contactID)
        #expect(memories.map(\.text) == ["Coffee with Ada."])
        #expect(memories.first?.transcript == "Had coffee with Ada.")
        #expect(memories.first?.source == .voice)

        let keyThings = try KeyThingRepository(database: database).list(contactID: plan.contactID)
        #expect(Set(keyThings.map(\.text)) == ["Allergic to shellfish.", "Runs on Sundays."])

        let reminders = try ReminderRepository(database: database).list(contactID: plan.contactID)
        #expect(reminders.map(\.title) == ["Send the deck"])
        #expect(reminders.first?.memoryID == memories.first?.id)
        #expect(reminders.first?.notificationID == nil)

        let events = try UsageLedgerRepository(database: database).list(userID: "user-1")
        #expect(events.map(\.source) == ["voice_capture_review"])
    }

    /// Every write is an upsert keyed on the ids minted once per capture, so
    /// running the same plan twice is the retry path and lands nothing extra.
    @Test func runningTheSamePlanTwiceChangesNothing() async throws {
        let database = try AppDatabase.inMemory()
        let plan = try plannedSave()

        _ = try await VoiceSaveTransaction.execute(plan, database: database)
        _ = try await VoiceSaveTransaction.execute(plan, database: database)

        let memories = try MemoryRepository(database: database).list(contactID: plan.contactID)
        let keyThings = try KeyThingRepository(database: database).list(contactID: plan.contactID)
        let reminders = try ReminderRepository(database: database).list(contactID: plan.contactID)
        let spent = try UsageLedgerRepository(database: database).count(userID: "user-1")

        #expect(memories.count == 1)
        #expect(keyThings.count == 2)
        #expect(reminders.count == 1)
        #expect(spent == 1)
    }

    /// The counterpart to the plan-level test, at the row that matters: a
    /// signed-in user's save leaves the local ledger empty.
    @Test func aSignedInSaveWritesNoLedgerRow() async throws {
        let database = try AppDatabase.inMemory()
        let plan = try plannedSave(recordsUsageEvent: false)

        _ = try await VoiceSaveTransaction.execute(plan, database: database)

        let spent = try UsageLedgerRepository(database: database).count(userID: "user-1")
        let memories = try MemoryRepository(database: database).list(contactID: plan.contactID)

        #expect(spent == 0)
        #expect(memories.count == 1)
    }
}
