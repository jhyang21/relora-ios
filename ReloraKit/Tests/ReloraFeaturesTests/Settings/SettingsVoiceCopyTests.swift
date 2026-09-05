import Foundation
import Testing
@testable import ReloraFeatures

/// Pins the Voice section's copy: `recordingsValue`'s three shapes, the
/// Delete All Recordings dialog, and the count in its toast.
///
/// The size argument is a literal `"34 MB"` throughout, never a computed
/// one — the function takes it pre-formatted precisely because byte
/// formatting is locale- and OS-dependent, and a test that formatted its
/// own bytes would assert against a value that changes with the machine
/// running it rather than against the copy this function actually owns.
struct SettingsVoiceCopyTests {
    @Test func zeroRecordingsShowsNone() {
        #expect(SettingsVoiceCopy.recordingsValue(count: 0, formattedSize: "34 MB") == "None")
    }

    @Test func oneRecordingIsSingular() {
        #expect(SettingsVoiceCopy.recordingsValue(count: 1, formattedSize: "34 MB") == "1 recording \u{00B7} 34 MB")
    }

    @Test func manyRecordingsArePlural() {
        #expect(SettingsVoiceCopy.recordingsValue(count: 12, formattedSize: "34 MB") == "12 recordings \u{00B7} 34 MB")
    }

    @Test func theDeleteDialogSaysWhatItDeletes() {
        #expect(SettingsConfirmation.deleteAllRecordings.title == "Delete All Recordings?")
        #expect(
            SettingsConfirmation.deleteAllRecordings.message
                == "Replay stops for every voice note on this iPhone. Your notes and transcripts stay exactly as they are."
        )
        #expect(SettingsConfirmation.deleteAllRecordings.confirmLabel == "Delete")
    }

    /// The row sits above Delete Account and shares its confirm label. The
    /// message is the only thing separating the two, so it must not borrow
    /// any of the other row's consequences.
    @Test func theDeleteDialogPromisesNothingItDoesNotDo() {
        let message = SettingsConfirmation.deleteAllRecordings.message.lowercased()
        #expect(!message.contains("account"))
        #expect(!message.contains("transcript loss"))
        #expect(!message.contains("permanently"))
        #expect(message.contains("notes and transcripts stay"))
    }

    @Test func theDeletionToastCountsWhatWent() {
        #expect(SettingsVoiceCopy.recordingsDeletedMessage(count: 0) == "No recordings to delete.")
        #expect(SettingsVoiceCopy.recordingsDeletedMessage(count: 1) == "1 recording deleted.")
        #expect(SettingsVoiceCopy.recordingsDeletedMessage(count: 12) == "12 recordings deleted.")
    }
}
