import Testing
@testable import ReloraCore

@Suite("AudioFormats")
struct AudioFormatsTests {
    @Test("extension wins over a conflicting declared mime type")
    func extensionWinsOverMime() {
        let result = AudioFormats.resolveSupportedUpload(fileName: "note.m4a", mimeType: "audio/webm")
        #expect(result == AudioFormats.SupportedUpload(fileType: .m4a, mimeType: "audio/m4a", fileName: "note.m4a"))
    }

    @Test("a mime alias maps to its canonical mime type")
    func mimeAliasMapsToCanonical() {
        let m4a = AudioFormats.resolveSupportedUpload(fileName: nil, mimeType: "audio/x-m4a")
        #expect(m4a == AudioFormats.SupportedUpload(fileType: .m4a, mimeType: "audio/m4a", fileName: "voice-note.m4a"))

        let wav = AudioFormats.resolveSupportedUpload(fileName: nil, mimeType: "audio/x-wav")
        #expect(wav == AudioFormats.SupportedUpload(fileType: .wav, mimeType: "audio/wav", fileName: "voice-note.wav"))
    }

    @Test("codec parameters are stripped before matching the mime type")
    func codecParametersStripped() {
        let result = AudioFormats.resolveSupportedUpload(fileName: nil, mimeType: "audio/webm;codecs=opus")
        #expect(result == AudioFormats.SupportedUpload(fileType: .webm, mimeType: "audio/webm", fileName: "voice-note.webm"))
    }

    @Test("mime matching is case-insensitive and trims whitespace")
    func mimeMatchingCaseInsensitiveAndTrimmed() {
        let result = AudioFormats.resolveSupportedUpload(fileName: nil, mimeType: "  AUDIO/MP3  ")
        #expect(result == AudioFormats.SupportedUpload(fileType: .mp3, mimeType: "audio/mp3", fileName: "voice-note.mp3"))
    }

    @Test("extension matching is case-insensitive; the canonical name keeps the original base")
    func extensionMatchingCaseInsensitive() {
        let result = AudioFormats.resolveSupportedUpload(fileName: "Recording.MP3", mimeType: nil)
        #expect(result == AudioFormats.SupportedUpload(fileType: .mp3, mimeType: "audio/mp3", fileName: "Recording.mp3"))
    }

    @Test("URLs are reduced to their basename with the query string dropped")
    func urlsReducedToBasename() {
        let result = AudioFormats.resolveSupportedUpload(
            fileName: "https://cdn.example.com/a/b/take.m4a?token=1",
            mimeType: nil
        )
        #expect(result == AudioFormats.SupportedUpload(fileType: .m4a, mimeType: "audio/m4a", fileName: "take.m4a"))
    }

    @Test("path traversal segments do not survive into the canonical name")
    func pathTraversalStripped() {
        let result = AudioFormats.resolveSupportedUpload(fileName: "../../etc/passwd.mp3", mimeType: nil)
        #expect(result == AudioFormats.SupportedUpload(fileType: .mp3, mimeType: "audio/mp3", fileName: "passwd.mp3"))
    }

    @Test("an unsupported extension falls back to the mime type")
    func unsupportedExtensionFallsBackToMime() {
        let result = AudioFormats.resolveSupportedUpload(fileName: "note.ogg", mimeType: "audio/mpeg")
        #expect(result == AudioFormats.SupportedUpload(fileType: .mpeg, mimeType: "audio/mpeg", fileName: "note.mpeg"))
    }

    @Test("returns nil when nothing usable is present")
    func returnsNilForNothingUsable() {
        #expect(AudioFormats.resolveSupportedUpload(fileName: nil, mimeType: nil) == nil)
        #expect(AudioFormats.resolveSupportedUpload(fileName: "", mimeType: "") == nil)
    }

    @Test("returns nil for entirely unsupported file names and mime types")
    func returnsNilForUnsupportedEverything() {
        #expect(AudioFormats.resolveSupportedUpload(fileName: "notes.txt", mimeType: "text/plain") == nil)
        #expect(AudioFormats.resolveSupportedUpload(fileName: "archive.zip", mimeType: "application/zip") == nil)
    }

    @Test("a trailing dot yields no extension, and there is no mime to fall back to")
    func trailingDotYieldsNoExtension() {
        #expect(AudioFormats.resolveSupportedUpload(fileName: "recording.", mimeType: nil) == nil)
    }

    @Test("an extension-only string is not accepted as a mime type")
    func extensionOnlyStringNotAMimeType() {
        #expect(AudioFormats.resolveSupportedUpload(fileName: nil, mimeType: "m4a") == nil)
    }

    @Test("falls back to a canonical name when the basename is empty")
    func fallsBackToCanonicalNameForEmptyBasename() {
        let result = AudioFormats.resolveSupportedUpload(fileName: ".m4a", mimeType: nil)
        // '.m4a' has no basename before the dot, so the canonical fallback applies.
        #expect(result == AudioFormats.SupportedUpload(fileType: .m4a, mimeType: "audio/m4a", fileName: "voice-note.m4a"))
    }

    @Test("renames the file to the resolved type when only the mime is supported")
    func renamesFileWhenOnlyMimeSupported() {
        let result = AudioFormats.resolveSupportedUpload(fileName: "capture.tmp", mimeType: "audio/wav")
        #expect(result == AudioFormats.SupportedUpload(fileType: .wav, mimeType: "audio/wav", fileName: "capture.wav"))
    }

    @Test("exposes the upload and duration limits used by both mobile and API")
    func exposesLimits() {
        #expect(AudioFormats.maxAudioUploadBytes == 25 * 1024 * 1024)
        #expect(AudioFormats.maxRecordingDurationMs == 5 * 60 * 1000)
    }

    @Test("lists every canonical mime and alias exactly once")
    func listsEveryMimeOnce() {
        let mimeTypes = AudioFormats.supportedMimeTypes
        #expect(Set(mimeTypes).count == mimeTypes.count)
        #expect(mimeTypes.contains("audio/x-m4a"))
        #expect(mimeTypes.contains("audio/x-wav"))
    }
}
