import Foundation

/// Deletes the recordings no live memory points at.
///
/// Runs once per launch, off the main actor. Never throws: a file it
/// cannot read it skips, and the next launch tries again.
///
/// Compares FILE NAMES, never paths. On iOS `/var` and `/private/var`
/// name the same directory, so a path comparison keeps or deletes the
/// wrong file depending on which of the two forms each side happens to
/// hold. Every name comes from a fresh UUID, so a name identifies a
/// recording as precisely as a path does. Do not turn this back into a
/// path comparison.
///
/// What the two rules protect:
///
/// (a) A name a live memory still holds is never a candidate, whatever
///     its age. That protects every saved recording.
/// (b) The grace window applies to unreferenced files only. It covers
///     the save-in-flight window, where the file has moved into the
///     store but `VoiceSaveTransaction` has not written its row yet. It
///     is not a "saved recently" signal: `moveItem` keeps the
///     modification date, so that date is when the audio was recorded.
/// (c) Orphans come from two places. A move that fails leaves the note
///     saved without its audio and the temporary file behind, and a
///     transaction that throws after a successful move leaves the file
///     in the store with no row.
/// (d) A tombstoned memory loses its recording at the next launch. Undo
///     is a four-second in-process toast and cannot race a launch-time
///     sweep. A row un-tombstoned on another device and pulled back
///     later degrades to a note with no replay pill, because
///     `existingURL` finds nothing. The stale `audio_local_uri` stays as
///     it is: nulling it would dirty the row and push a local storage
///     concern up to the server.
///
/// An empty `referencedValues` is legal input, from a user with no voice
/// notes or with nothing but orphans, and still sweeps. Telling that
/// apart from a failed database read is the caller's job.
public struct RecordingSweep: Sendable {
    public struct Result: Sendable, Equatable {
        public let removed: Int
        public let kept: Int

        public init(removed: Int, kept: Int) {
            self.removed = removed
            self.kept = kept
        }
    }

    private static let temporaryNamePrefix = "relora-recording-"
    private static let recordingExtension = "m4a"

    private let store: RecordingStore
    private let temporaryDirectory: URL
    private let grace: TimeInterval

    public init(
        store: RecordingStore,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        grace: TimeInterval = 3600
    ) {
        self.store = store
        self.temporaryDirectory = temporaryDirectory
        self.grace = grace
    }

    public func run(referencedValues: Set<String>, now: Date = Date()) -> Result {
        // `store.url(for:)` reads both shapes the column holds — the bare
        // file name written since 2.2.0 and the legacy absolute `file://`
        // string older rows still carry — so that rule lives in one place.
        let referenced = Set(referencedValues.compactMap { store.url(for: $0)?.lastPathComponent })
        let cutoff = now.addingTimeInterval(-grace)

        var removed = 0
        var kept = 0

        for name in store.storedFileNames() {
            // `store.url(for:)` rather than a directory URL of our own:
            // the store owns where its files are, and a name from
            // `storedFileNames()` is always a plain component.
            guard
                !referenced.contains(name),
                let url = store.url(for: name),
                let modified = Self.modificationDate(of: url),
                modified < cutoff,
                store.remove(name: name)
            else {
                kept += 1
                continue
            }
            removed += 1
        }

        for url in temporaryCandidates() {
            guard
                !referenced.contains(url.lastPathComponent),
                let modified = Self.modificationDate(of: url),
                modified < cutoff
            else {
                kept += 1
                continue
            }
            do {
                try FileManager.default.removeItem(at: url)
                removed += 1
            } catch {
                kept += 1
            }
        }

        return Result(removed: removed, kept: kept)
    }

    /// The temporary files the recorder wrote, and nothing else.
    ///
    /// Prefix, extension and regular-file all have to match. The store's
    /// own fallback directory can sit under the temporary directory when
    /// Application Support is unavailable, and `DataExport` writes
    /// `relora-export-*.json` there, so a looser filter would delete
    /// files this sweep does not own.
    private func temporaryCandidates() -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.filter { url in
            guard
                url.lastPathComponent.hasPrefix(Self.temporaryNamePrefix),
                url.pathExtension == Self.recordingExtension,
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true
            else {
                return false
            }
            return true
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }
}
