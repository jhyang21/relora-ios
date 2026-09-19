import Foundation
import ReloraCore
import ReloraServices

/// What a failed capture says to the person who recorded it.
///
/// A line-by-line port of `mapTranscriptionError` in
/// apps/mobile/src/features/voice/voiceCaptureErrorMapping.ts. The copy is
/// reproduced word for word: each string names what failed and what to do
/// next, and none of them blames the user or mentions a status code.
///
/// Codes come from `BackendError`'s catalog rather than string literals —
/// `RECORD_PERMISSION_DENIED` was added there by M6 for exactly this switch
/// (see docs/milestone-notes.md, "Error-code catalog reconciliation").
public enum VoiceErrorCopy {
    /// The session is gone; the audio is not. Both codes mean "sign in and
    /// try again", which is why the error card offers a Sign in button
    /// instead of a Retry that would fail the same way.
    public static func isAuthFailure(_ code: String) -> Bool {
        code == BackendError.authRequired || code == BackendError.authFailed
    }

    public static func message(for code: String) -> String {
        if isAuthFailure(code) {
            return "Your session expired. Sign in again and retry the recording."
        }

        switch code {
        case BackendError.transcribeTimeout, BackendError.realtimeTranscriptTimeout:
            return "Could not finish transcribing that recording."
        case BackendError.extractTimeout, BackendError.extractFailed:
            return "Could not finish processing that recording."
        case BackendError.localAudioReadFailed:
            return "Could not read that recording from local storage."
        case BackendError.localAudioEmpty:
            return recordingTooShortMessage
        case BackendError.transcribeEmpty:
            return nothingHeardMessage
        case BackendError.transcribeUploadFailed:
            return "Could not upload that recording. Check your connection and try again."
        case BackendError.unsupportedMime:
            return "This recording format is not supported for transcription."
        case BackendError.payloadTooLarge:
            return "That recording is too large. Keep voice notes under 25 MB."
        case BackendError.audioTooLong:
            return "That recording is too long. Keep voice notes under five minutes."
        case BackendError.idempotencyConflict:
            return "That recording conflicted with an existing request. Try once more."
        case BackendError.recordPermissionDenied:
            return "Microphone permission is required to record."
        default:
            break
        }

        // The `REALTIME_` prefix test is deliberately a prefix and not a list:
        // M7 adds realtime codes, and every one of them means the same thing
        // to the user. Kept below the exact cases so
        // `REALTIME_TRANSCRIPT_TIMEOUT` still gets its own line.
        if code.hasPrefix("REALTIME_") || code == BackendError.realtimeSessionFailed {
            return "Live transcription failed for that recording."
        }

        return "Could not transcribe that."
    }

    /// What a recorder that would not start says. Ports `mapVoiceStartError`
    /// (`voiceCaptureController.ts`), which keeps its own two-line switch
    /// rather than falling through to the transcription copy above — the
    /// generic "could not transcribe that" would be a lie about a recording
    /// that never happened.
    public static func startFailureMessage(_ error: Error) -> String {
        if let recordingError = error as? RecordingControllerError,
           recordingError == .permissionDenied {
            return message(for: BackendError.recordPermissionDenied)
        }
        return noRecordingMessage
    }

    /// Said when the recorder produced nothing at all — a start that
    /// failed, and a Stop that arrived before there was anything to stop.
    /// One string for both because they are the same event to the person
    /// holding the phone: the recording did not happen, try it again.
    public static let noRecordingMessage = "Could not start recording. Please try again."

    /// Said when a recording ended before the encoder wrote its first
    /// packet. Names the fix rather than the cause: "local storage" would
    /// be true of the file and useless to the reader, who only has to hold
    /// the recording open a moment longer.
    public static let recordingTooShortMessage =
        "That recording was too short. Try again and speak for a moment before you stop."

    /// Said when the recording reached the server and came back with no
    /// words. A reviewer who taps the mic and Stop without speaking lands
    /// here; "could not transcribe" would tell them the app is broken when
    /// nothing was said.
    public static let nothingHeardMessage = "We did not hear anything. Try again."

    /// The code to remember alongside the message, so the error card can ask
    /// "is this an auth failure?" later. Recorder failures carry
    /// `RECORD_PERMISSION_DENIED` or nothing — RN clears the code on a start
    /// failure precisely so a stale `AUTH_REQUIRED` cannot make a denied
    /// microphone look like a sign-in problem.
    public static func startFailureCode(_ error: Error) -> String? {
        if let recordingError = error as? RecordingControllerError,
           recordingError == .permissionDenied {
            return BackendError.recordPermissionDenied
        }
        return nil
    }
}
