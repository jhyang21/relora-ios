import Foundation
import Testing
@testable import ReloraServices

// Copies of the store tests' helpers: those are file-private, and a
// per-test UUID root is what keeps these tests from sharing state.
private func makeRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
}

private func writeFakeAudioFile(at url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("fake-audio-bytes".utf8).write(to: url)
}

/// Backdates a file so it falls outside the sweep's grace window.
private func age(_ url: URL, byHours hours: Double) throws {
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-hours * 3600)],
        ofItemAtPath: url.path
    )
}

private func makeTemporaryDirectory(under root: URL) throws -> URL {
    let directory = root.appendingPathComponent("Tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test("keeps a stored recording a live memory still references")
func keepsAReferencedRecording() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let recordings = root.appendingPathComponent("Recordings")
    let temporary = try makeTemporaryDirectory(under: root)

    let referenced = recordings.appendingPathComponent("kept.m4a")
    try writeFakeAudioFile(at: referenced)
    try age(referenced, byHours: 48)

    let sweep = RecordingSweep(store: RecordingStore(directory: recordings), temporaryDirectory: temporary)
    let result = sweep.run(referencedValues: ["kept.m4a"])

    #expect(result == RecordingSweep.Result(removed: 0, kept: 1))
    #expect(FileManager.default.fileExists(atPath: referenced.path))
}

@Test("removes an old orphan and keeps one still inside the grace window")
func removesOldOrphansOnly() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let recordings = root.appendingPathComponent("Recordings")
    let temporary = try makeTemporaryDirectory(under: root)

    let old = recordings.appendingPathComponent("old.m4a")
    try writeFakeAudioFile(at: old)
    try age(old, byHours: 48)

    let recent = recordings.appendingPathComponent("recent.m4a")
    try writeFakeAudioFile(at: recent)

    let sweep = RecordingSweep(store: RecordingStore(directory: recordings), temporaryDirectory: temporary)
    let result = sweep.run(referencedValues: [])

    #expect(result == RecordingSweep.Result(removed: 1, kept: 1))
    #expect(!FileManager.default.fileExists(atPath: old.path))
    #expect(FileManager.default.fileExists(atPath: recent.path))
}

@Test("a bare name and a legacy file URL both protect their file")
func readsBothStoredValueShapes() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let recordings = root.appendingPathComponent("Recordings")
    let temporary = try makeTemporaryDirectory(under: root)

    let bare = recordings.appendingPathComponent("bare.m4a")
    try writeFakeAudioFile(at: bare)
    try age(bare, byHours: 48)

    let legacy = recordings.appendingPathComponent("legacy.m4a")
    try writeFakeAudioFile(at: legacy)
    try age(legacy, byHours: 48)

    let sweep = RecordingSweep(store: RecordingStore(directory: recordings), temporaryDirectory: temporary)
    let result = sweep.run(referencedValues: ["bare.m4a", legacy.absoluteString])

    #expect(result == RecordingSweep.Result(removed: 0, kept: 2))
    #expect(FileManager.default.fileExists(atPath: bare.path))
    #expect(FileManager.default.fileExists(atPath: legacy.path))
}

@Test("sweeps the temporary directory for recorder files and nothing else")
func sweepsRecorderTemporaryFilesOnly() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let recordings = root.appendingPathComponent("Recordings")
    let temporary = try makeTemporaryDirectory(under: root)

    let orphan = temporary.appendingPathComponent("relora-recording-\(UUID().uuidString).m4a")
    try writeFakeAudioFile(at: orphan)
    try age(orphan, byHours: 48)

    let export = temporary.appendingPathComponent("relora-export-1.json")
    try writeFakeAudioFile(at: export)
    try age(export, byHours: 48)

    // Named exactly like a recording, but a directory. The sweep's
    // regular-file check is the only thing that saves it.
    let nested = temporary.appendingPathComponent("relora-recording-nested.m4a", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

    let sweep = RecordingSweep(store: RecordingStore(directory: recordings), temporaryDirectory: temporary)
    let result = sweep.run(referencedValues: [])

    #expect(result == RecordingSweep.Result(removed: 1, kept: 0))
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
    #expect(FileManager.default.fileExists(atPath: export.path))
    #expect(FileManager.default.fileExists(atPath: nested.path))
}

@Test("keeps a temporary recording still inside the grace window")
func keepsARecentTemporaryRecording() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let recordings = root.appendingPathComponent("Recordings")
    let temporary = try makeTemporaryDirectory(under: root)

    let inFlight = temporary.appendingPathComponent("relora-recording-\(UUID().uuidString).m4a")
    try writeFakeAudioFile(at: inFlight)

    let sweep = RecordingSweep(store: RecordingStore(directory: recordings), temporaryDirectory: temporary)
    let result = sweep.run(referencedValues: [])

    #expect(result == RecordingSweep.Result(removed: 0, kept: 1))
    #expect(FileManager.default.fileExists(atPath: inFlight.path))
}

@Test("counts what it removed and what it kept across both directories")
func countsRemovedAndKeptAcrossBothDirectories() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let recordings = root.appendingPathComponent("Recordings")
    let temporary = try makeTemporaryDirectory(under: root)

    let referenced = recordings.appendingPathComponent("referenced.m4a")
    try writeFakeAudioFile(at: referenced)
    try age(referenced, byHours: 48)

    let storedOrphan = recordings.appendingPathComponent("stored-orphan.m4a")
    try writeFakeAudioFile(at: storedOrphan)
    try age(storedOrphan, byHours: 48)

    let temporaryOrphan = temporary.appendingPathComponent("relora-recording-old.m4a")
    try writeFakeAudioFile(at: temporaryOrphan)
    try age(temporaryOrphan, byHours: 48)

    let temporaryRecent = temporary.appendingPathComponent("relora-recording-new.m4a")
    try writeFakeAudioFile(at: temporaryRecent)

    let sweep = RecordingSweep(store: RecordingStore(directory: recordings), temporaryDirectory: temporary)
    let result = sweep.run(referencedValues: ["referenced.m4a"])

    #expect(result == RecordingSweep.Result(removed: 2, kept: 2))
    #expect(FileManager.default.fileExists(atPath: referenced.path))
    #expect(!FileManager.default.fileExists(atPath: storedOrphan.path))
    #expect(!FileManager.default.fileExists(atPath: temporaryOrphan.path))
    #expect(FileManager.default.fileExists(atPath: temporaryRecent.path))
}
