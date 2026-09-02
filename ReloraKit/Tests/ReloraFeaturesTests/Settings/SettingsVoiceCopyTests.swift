import Foundation
import Testing
@testable import ReloraFeatures

/// Pins `SettingsVoiceCopy.recordingsValue`'s three shapes.
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
}
