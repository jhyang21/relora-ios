import Foundation

/// Where a saved voice note's recording lives after the capture is over.
///
/// `RecordingController` writes into `temporaryDirectory`, which iOS may
/// purge at any time. A memory row, by contrast, points at its recording
/// for months — so on save the file moves into `Application
/// Support/Relora/Recordings/` and the row stores the FILE NAME, not a
/// path. A name, not a path: an absolute sandbox path embeds the
/// container UUID, which iOS changes on reinstall, so the URL is rebuilt
/// against the live container at read time instead of being persisted
/// directly.
///
/// Not excluded from backup on purpose: recordings are user content the
/// user cannot re-create. A restore lands the file in the new
/// container's Recordings directory and the stored name still resolves.
public struct RecordingStore: Sendable {
    public enum StoreError: Error, Sendable, Equatable {
        case moveFailed(String)
    }

    public static let shared = RecordingStore()

    private let directory: URL

    /// `nil` uses `Application Support/Relora/Recordings`. Tests pass
    /// their own directory.
    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base: URL
            do {
                base = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
            } catch {
                base = FileManager.default.temporaryDirectory
            }
            self.directory = base
                .appendingPathComponent("Relora", isDirectory: true)
                .appendingPathComponent("Recordings", isDirectory: true)
        }
    }

    /// Moves a finished recording in and returns the value to store in
    /// `Memory.audioLocalURI` (the file name).
    ///
    /// Idempotent for a retried save: if the destination already exists
    /// and the source is gone, the earlier move already succeeded, so
    /// this returns the name without touching the file. If `temporaryURL`
    /// is already the destination, it also just returns the name.
    public func store(temporaryURL: URL) throws -> String {
        let name = temporaryURL.lastPathComponent
        let destination = directory.appendingPathComponent(name, isDirectory: false)

        if destination.standardizedFileURL == temporaryURL.standardizedFileURL {
            return name
        }

        let sourceExists = FileManager.default.fileExists(atPath: temporaryURL.path)
        let destinationExists = FileManager.default.fileExists(atPath: destination.path)

        if !sourceExists {
            if destinationExists {
                return name
            }
            throw StoreError.moveFailed("source missing")
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StoreError.moveFailed(String(describing: error))
        }

        if destinationExists {
            try? FileManager.default.removeItem(at: destination)
        }

        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
        } catch {
            do {
                try FileManager.default.copyItem(at: temporaryURL, to: destination)
                try? FileManager.default.removeItem(at: temporaryURL)
            } catch {
                throw StoreError.moveFailed(String(describing: error))
            }
        }

        return name
    }

    /// The URL a stored value names, whether or not a file is there at
    /// it. Split from `existingURL` so a test can assert the join
    /// without touching disk.
    ///
    /// IMPORTANT: the prefix check runs before `URL(string:)` — a bare
    /// file name parses as a (relative) URL just fine, so checking the
    /// scheme first is what tells a legacy absolute `file://` string
    /// apart from a plain name.
    public func url(for storedValue: String) -> URL? {
        let value = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.hasPrefix("file://") {
            guard let url = URL(string: value), url.isFileURL else { return nil }
            return url
        }

        return directory.appendingPathComponent(value, isDirectory: false)
    }

    /// `url(for:)`, resolved only if a file actually exists there.
    public func existingURL(for storedValue: String) -> URL? {
        guard let url = url(for: storedValue) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
