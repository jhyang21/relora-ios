import Foundation

/// Audio upload normalization shared by capture, upload, and transcription.
/// Ports packages/shared/src/audio/audioFormats.ts.
public enum AudioFormats {
    // RN: MAX_AUDIO_UPLOAD_BYTES (25 * 1024 * 1024)
    public static let maxAudioUploadBytes = 26_214_400
    // RN: MAX_RECORDING_DURATION_MS (5 * 60 * 1000)
    public static let maxRecordingDurationMs = 300_000

    /// Mirrors `SupportedAudioFileType`.
    public enum FileType: String, Equatable, Sendable, CaseIterable {
        case mp3, mp4, mpeg, mpga, m4a, wav, webm
    }

    /// A resolved upload: the canonical file type and mime type to submit,
    /// plus a file name renamed to match the resolved type. Mirrors
    /// `SupportedAudioUpload`.
    public struct SupportedUpload: Equatable, Sendable {
        public var fileType: FileType
        public var mimeType: String
        public var fileName: String

        public init(fileType: FileType, mimeType: String, fileName: String) {
            self.fileType = fileType
            self.mimeType = mimeType
            self.fileName = fileName
        }
    }

    private struct FormatDescriptor {
        let fileType: FileType
        let mimeType: String
        let mimeAliases: [String]
    }

    // RN: AUDIO_FORMATS
    private static let formats: [FormatDescriptor] = [
        FormatDescriptor(fileType: .mp3, mimeType: "audio/mp3", mimeAliases: []),
        FormatDescriptor(fileType: .mp4, mimeType: "audio/mp4", mimeAliases: []),
        FormatDescriptor(fileType: .mpeg, mimeType: "audio/mpeg", mimeAliases: []),
        FormatDescriptor(fileType: .mpga, mimeType: "audio/mpga", mimeAliases: []),
        FormatDescriptor(fileType: .m4a, mimeType: "audio/m4a", mimeAliases: ["audio/x-m4a"]),
        FormatDescriptor(fileType: .wav, mimeType: "audio/wav", mimeAliases: ["audio/x-wav"]),
        FormatDescriptor(fileType: .webm, mimeType: "audio/webm", mimeAliases: []),
    ]

    // RN: AUDIO_FORMAT_BY_FILE_TYPE
    private static let formatByFileType: [FileType: FormatDescriptor] = Dictionary(
        uniqueKeysWithValues: formats.map { ($0.fileType, $0) }
    )

    // RN: AUDIO_FORMAT_BY_MIME_TYPE
    private static let formatByMimeType: [String: FormatDescriptor] = {
        var map: [String: FormatDescriptor] = [:]
        for descriptor in formats {
            map[descriptor.mimeType] = descriptor
            for alias in descriptor.mimeAliases {
                map[alias] = descriptor
            }
        }
        return map
    }()

    /// Every canonical mime type and alias. Mirrors
    /// `SUPPORTED_AUDIO_MIME_TYPES`.
    public static let supportedMimeTypes: [String] = formats.flatMap { [$0.mimeType] + $0.mimeAliases }

    private static func sanitizeMimeType(_ mimeType: String?) -> String? {
        guard let mimeType = mimeType else {
            return nil
        }
        let trimmedLowercased = mimeType.trimmingCharacters(in: .whitespaces).lowercased()
        let beforeParameters = trimmedLowercased
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? trimmedLowercased
        return beforeParameters.isEmpty ? nil : beforeParameters
    }

    private static func basename(_ value: String) -> String {
        let afterSlash = value
            .split(separator: "/", omittingEmptySubsequences: false)
            .last
            .map(String.init) ?? value
        return afterSlash
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? afterSlash
    }

    private static func extractExtension(_ fileName: String?) -> String? {
        guard let fileName = fileName else {
            return nil
        }
        let cleanName = basename(fileName).trimmingCharacters(in: .whitespaces).lowercased()
        if cleanName.isEmpty {
            return nil
        }

        guard let lastDotIndex = cleanName.lastIndex(of: ".") else {
            return nil
        }
        if lastDotIndex == cleanName.index(before: cleanName.endIndex) {
            // Trailing dot with nothing after it, e.g. "recording.".
            return nil
        }

        return String(cleanName[cleanName.index(after: lastDotIndex)...])
    }

    private static func buildCanonicalFileName(_ originalFileName: String?, fileType: FileType) -> String {
        let cleanName = originalFileName.map(basename)?.trimmingCharacters(in: .whitespaces) ?? ""
        if cleanName.isEmpty {
            return "voice-note.\(fileType.rawValue)"
        }

        let baseName: String
        if let lastDotIndex = cleanName.lastIndex(of: ".") {
            // A leading-dot name like ".m4a" has an extension but no base
            // name; without this explicit empty case it would double into
            // ".m4a.m4a".
            baseName = lastDotIndex == cleanName.startIndex
                ? ""
                : String(cleanName[cleanName.startIndex..<lastDotIndex])
        } else {
            baseName = cleanName
        }

        return "\(baseName.isEmpty ? "voice-note" : baseName).\(fileType.rawValue)"
    }

    /// Resolves a supported audio upload from file-name and mime metadata.
    /// The file extension wins when it disagrees with the declared mime
    /// type; the mime type is used only when no supported extension is
    /// present. Mirrors `resolveSupportedAudioUpload`.
    public static func resolveSupportedUpload(fileName: String?, mimeType: String?) -> SupportedUpload? {
        if let extractedType = extractExtension(fileName),
           let fileType = FileType(rawValue: extractedType),
           let descriptor = formatByFileType[fileType] {
            return SupportedUpload(
                fileType: descriptor.fileType,
                mimeType: descriptor.mimeType,
                fileName: buildCanonicalFileName(fileName, fileType: descriptor.fileType)
            )
        }

        guard let sanitizedMimeType = sanitizeMimeType(mimeType),
              let descriptor = formatByMimeType[sanitizedMimeType] else {
            return nil
        }

        return SupportedUpload(
            fileType: descriptor.fileType,
            mimeType: descriptor.mimeType,
            fileName: buildCanonicalFileName(fileName, fileType: descriptor.fileType)
        )
    }
}
