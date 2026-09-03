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

    /// What the store directory holds, for the Settings row.
    ///
    /// `bytes` is the sum of logical file sizes, not allocated size:
    /// block rounding varies by filesystem and a test cannot predict it.
    /// The number therefore reads a little under what deleting the files
    /// would give back.
    public struct Usage: Sendable, Equatable {
        public let count: Int
        public let bytes: Int64

        public init(count: Int, bytes: Int64) {
            self.count = count
            self.bytes = bytes
        }
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

    /// The names of the regular files in the store directory.
    ///
    /// The one place directory enumeration lives, so `RecordingSweep` can
    /// decide what to delete without ever holding the directory URL.
    ///
    /// Empty for a directory that is not there. `contentsOfDirectory`
    /// throws on a missing directory, and on a fresh install a missing
    /// directory means the store is empty, not broken.
    public func storedFileNames() -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true ? url.lastPathComponent : nil
        }
    }

    /// Deletes one stored recording. `true` when a file was there and went.
    ///
    /// A name, never a path. A value with a separator in it would reach
    /// outside the store directory, and nothing outside that directory
    /// belongs to this type.
    @discardableResult
    public func remove(name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return false }
        do {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name, isDirectory: false))
            return true
        } catch {
            return false
        }
    }

    /// Deletes every stored recording and returns how many went.
    ///
    /// The store directory only, never the temporary directory: this runs
    /// on Delete Account, and a temporary file is an in-flight capture
    /// that belongs to the recorder rather than to any account.
    ///
    /// Non-throwing, because its caller is tearing an account down and
    /// could do nothing with the error but discard it.
    @discardableResult
    public func removeAll() -> Int {
        storedFileNames().reduce(into: 0) { total, name in
            if remove(name: name) { total += 1 }
        }
    }

    /// How many recordings the phone keeps and what they weigh.
    ///
    /// Zeros on any error, a missing directory included. The store
    /// directory only: the Settings row answers "what stays on this
    /// iPhone", and a temporary file is by definition not kept.
    public func usage() -> Usage {
        let names = storedFileNames()
        let bytes = names.reduce(into: Int64(0)) { total, name in
            let values = try? directory
                .appendingPathComponent(name, isDirectory: false)
                .resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return Usage(count: names.count, bytes: bytes)
    }
}
