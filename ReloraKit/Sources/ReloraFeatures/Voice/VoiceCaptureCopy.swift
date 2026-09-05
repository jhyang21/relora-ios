import Foundation
import ReloraCore

/// Which part of the capture the composer is showing. Ports `CaptureStage`
/// in `VoiceCaptureComposerScreen.tsx`.
public enum VoiceCaptureStage: String, Equatable, Sendable {
    /// The one-time "How voice notes work" panel. First because it runs
    /// before everything else — the quota gate and the microphone included.
    /// No RN counterpart; the Expo client never showed it.
    case disclosure
    case recording
    case processing
    /// The review screen. RN's `'draft'`.
    case draft
    case error
}

/// Every user-facing string in the composer, in one place.
///
/// Ported word for word from `VoiceCaptureComposerScreen.tsx` and
/// `VoiceCaptureReviewSection.tsx`. Copy is behavior here: the difference
/// between "Still polishing that note..." at fifteen seconds and silence is
/// the difference between a slow app and a broken one. Keeping it in pure
/// functions is also what lets a test assert the escalation without a screen.
public enum VoiceCaptureCopy {

    // MARK: Disclosure

    /// The one-time panel shown before the first recording. It never names
    /// the transcription vendor: the privacy policy, the App Privacy labels
    /// and the App Review notes carry that name, and in-app copy that reads
    /// like a legal disclosure is copy nobody reads.
    ///
    /// The two privacy sentences are the Settings footer's own, not a
    /// paraphrase — see `SettingsVoiceCopy`.
    public static let disclosureTitle = "How voice notes work"
    public static let disclosureBody =
        "You talk, and Relora writes the note. You review it before anything is saved."
    public static let disclosurePrivacy =
        "\(SettingsVoiceCopy.serversDoNotKeepAudio) \(SettingsVoiceCopy.recordingsStayOnDevice)"
    public static let disclosureMicNotice = "iOS will ask for microphone access next."
    public static let disclosurePrivacyLink = "Privacy Policy"
    public static let disclosureContinue = "Continue"
    public static let disclosureNotNow = "Not now"

    // MARK: Header

    /// The small state line above the meter. RN's `getStateLabel`.
    public static func stateLabel(stage: VoiceCaptureStage, recording: VoiceRecordingState) -> String {
        switch stage {
        case .disclosure: return "Before you start"
        case .processing: return "Polishing note"
        case .draft: return "Draft ready"
        case .error: return "Try again"
        case .recording:
            switch recording {
            case .finishing: return "Wrapping up"
            case .speaking: return "Listening"
            case .listening: return "Ready when you are"
            }
        }
    }

    /// Shown beside the state label while a guest's note never reached the
    /// server. RN's `status={usedLocalGuestFallback ? 'Local draft' : null}`.
    public static let localDraftStatus = "Local draft"

    // MARK: Recording and processing

    public static func title(stage: VoiceCaptureStage) -> String {
        switch stage {
        case .disclosure: return disclosureTitle
        case .error: return "We could not finish that recording"
        case .processing: return "Turning that recording into a clean note"
        case .recording, .draft: return "Speak like you normally would"
        }
    }

    /// M6 ported only the batch line, with the realtime branch left as a
    /// promise a pipeline that could not keep it. M7 delivers it:
    /// `isLiveTranscribing` is true only once this capture actually
    /// connected, so the line never promises a live transcript a fallback
    /// silently swapped in behind the scenes.
    public static func recordingSubtitle(isLiveTranscribing: Bool) -> String {
        isLiveTranscribing
            ? "You will see the transcript build while you talk."
            : "Pause when you are done and we will pull out the note for you."
    }

    public static let processingBody =
        "We are transcribing the audio, drafting one memory, and keeping the best key things."

    /// The escalating note under the header while processing runs long. RN's
    /// `getProcessingStatusLabel`, keyed off the shared clock's slow marks.
    public static func processingStatus(slowMarkSeconds: Int) -> String {
        slowMarkSeconds >= 30 ? "Taking longer than usual..." : "Still polishing that note..."
    }

    // MARK: Live transcript (M7)

    /// Shown before anything has been said yet — the same three-line
    /// placeholder RN's `LiveTranscriptPreview` shows while `phase ===
    /// 'placeholder'`, replaced by the transcript itself once one arrives.
    public static let liveTranscriptPlaceholderLine1 = "Tell it naturally."
    public static let liveTranscriptPlaceholderLine2 = "Names, plans, details."
    public static let liveTranscriptPlaceholderLine3 = "We will sort it after."

    // MARK: Errors

    /// What the error card says under the failure message.
    ///
    /// Three cases because three different things can be done next, and
    /// offering a Retry to someone whose recording never existed is worse
    /// than offering nothing.
    public static func errorBody(isAuthFailure: Bool, hasRetryableAudio: Bool) -> String {
        if isAuthFailure {
            return "Your recording is still here. Sign in to pick up where you left off."
        }
        return hasRetryableAudio
            ? "Retry this recording, start a fresh one, or discard the capture."
            : "Nothing was captured. Try recording again, or close and come back to it."
    }

    // MARK: Confirmations

    public static let discardTitle = "Discard this capture?"
    public static let discardMessage = "This will close the voice note and lose the current draft."
    public static let discardKeep = "Keep editing"
    public static let discardConfirm = "Discard"

    public static let durationLimitTitle = "Recording limit reached"
    public static let durationLimitSeePlans = "See plans"
    public static let durationLimitContinue = "Continue"

    // MARK: Review

    public static let reviewTitle = "One clean note, ready to save"
    public static let reviewSubtitle = "Check the person, tighten the note, and save it in one step."
    public static let contactPrompt = "Choose person"
    public static let contactPromptHelp = "Save stays locked until this note points to the right contact."
    public static let guestNoticeTitle = "Saved on this device"
    public static let guestNoticeBody =
        "Transcription needs an account, so write the note yourself. It stays on this device until you create one."
    public static let memorySectionTitle = "Note"
    public static let keyThingsSectionTitle = "Key things"
    public static let keyThingsEmpty = "No key things pulled out of this note."
    public static let reminderCardTitle = "Reminder suggestion"
    public static let recordAgain = "Record again"
    /// The review footer's discard, distinct from `discardConfirm`, which is
    /// the destructive button inside the confirmation this one raises.
    public static let discardAction = "Discard"

    /// Shown in the empty memory field. This is the guest's whole writing
    /// surface — with no transcript, the placeholder is the only instruction
    /// they get — so it says what to write, not "Tap to edit".
    public static let memoryPlaceholder = "Write what you want to remember from this recording."
    /// RN's generic `promptText`, used for a key thing whose text was cleared.
    public static let keyThingPlaceholder = "Tap to write this in."

    public static func keepLabel(kind: VoiceReviewItemKind) -> String {
        kind == .memory ? "Keep this note" : "Keep this key thing"
    }

    public static let reminderKeepLabel = "Keep this reminder"
    public static let reminderDateLabel = "Remind me"

    // MARK: Audio replay (M7)

    /// Ports `AudioReplayButton`'s section in `VoiceCaptureReviewSection.tsx`.
    public static let audioReplayTitle = "Replay the recording"
    public static let audioReplayBody = "Listen back before saving if you want to verify the summary."

    /// The transcript sits behind a disclosure, closed by default. It is the
    /// raw material, not the note — someone checking the draft against what
    /// they said wants it, and everyone else wants it out of the way.
    public static let transcriptDisclosure = "View transcript"

    /// The save button, and the label VoiceOver reads for it — which stays
    /// "Save note" while the visible text says "Saving...", so the control
    /// does not rename itself mid-action.
    public static let saveAction = "Save note"
    public static let savingAction = "Saving..."

    public static let savedToast = "Saved to contact"
    /// RN's guard when Save is somehow reached with no contact chosen.
    public static let contactRequiredTitle = "Pick the right contact"
    public static let contactRequiredMessage = "Choose the person this note belongs to before saving."

    // MARK: Contact picker

    /// The picker's title and subtitle depend on how sure the matcher was.
    /// Ports `getTitle` / `getSubtitle` in `VoiceContactPickerSheet.tsx`,
    /// keyed off the same status rather than a re-derived confidence.
    public static func pickerTitle(status: MatchingStatus) -> String {
        switch status {
        case .matched: return "Confirm the person"
        case .noMatches: return "Pick or create a contact"
        case .idle, .needsReview: return "Choose the right contact"
        }
    }

    public static func pickerSubtitle(status: MatchingStatus) -> String {
        switch status {
        case .matched:
            return "You can keep the suggested match or switch it before saving."
        case .noMatches:
            return "No strong match yet. Search for the person below, or create a new contact."
        case .idle, .needsReview:
            return "Save stays disabled until the note points at the right person."
        }
    }

    public static let pickerSearchPlaceholder = "Search your contacts"
    public static let pickerEmpty = "No contact matches that name. Create a new one below."
    public static let pickerCreateNew = "Create new contact"
    public static let pickerNewNameLabel = "Name"
    public static let pickerUseNew = "Use this new contact"
    public static let pickerConfirm = "Use this contact"
    public static let pickerIncompleteTitle = "Contact required"
    public static let pickerIncompleteMessage = "Pick the right contact or enter a name for a new one."

}

// MARK: - Elapsed time

/// The recording timer.
public enum VoiceElapsedFormat {
    /// `m:ss`, with the cap alongside it — "0:12 of 1:00". A bare count of
    /// seconds does not tell someone on a one-minute plan how much room is
    /// left, which is the only reason the timer is on screen.
    public static func label(elapsed: Duration, cap: Duration) -> String {
        "\(clock(elapsed)) of \(clock(cap))"
    }

    /// The same thing said in words, for VoiceOver — "12 seconds of 1 minute"
    /// rather than a colon a screen reader spells out.
    public static func accessibilityLabel(elapsed: Duration, cap: Duration) -> String {
        "\(spoken(elapsed)) recorded of \(spoken(cap))"
    }

    public static func clock(_ duration: Duration) -> String {
        let total = seconds(duration)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func spoken(_ duration: Duration) -> String {
        let total = seconds(duration)
        let minutes = total / 60
        let remainder = total % 60
        var parts: [String] = []
        if minutes > 0 {
            parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")")
        }
        if remainder > 0 || minutes == 0 {
            parts.append("\(remainder) second\(remainder == 1 ? "" : "s")")
        }
        return parts.joined(separator: " ")
    }

    private static func seconds(_ duration: Duration) -> Int {
        max(0, Int(duration.components.seconds))
    }
}
