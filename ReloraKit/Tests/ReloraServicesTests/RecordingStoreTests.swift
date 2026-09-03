import Foundation
import Testing
@testable import ReloraServices

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

@Test("moves the file and returns its name")
func movesTheFileAndReturnsItsName() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let source = root.appendingPathComponent("relora-recording-\(UUID().uuidString).m4a")
    try writeFakeAudioFile(at: source)

    let store = RecordingStore(directory: root.appendingPathComponent("Recordings"))
    let name = try store.store(temporaryURL: source)

    #expect(name == source.lastPathComponent)
    #expect(!FileManager.default.fileExists(atPath: source.path))

    let destination = root.appendingPathComponent("Recordings").appendingPathComponent(name)
    let bytes = try Data(contentsOf: destination)
    #expect(bytes == Data("fake-audio-bytes".utf8))
}

@Test("creates the directory when it is missing")
func createsTheDirectoryWhenItIsMissing() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let source = root.appendingPathComponent("source.m4a")
    try writeFakeAudioFile(at: source)

    let recordings = root.appendingPathComponent("Recordings")
    #expect(!FileManager.default.fileExists(atPath: recordings.path))

    let store = RecordingStore(directory: recordings)
    _ = try store.store(temporaryURL: source)

    #expect(FileManager.default.fileExists(atPath: recordings.path))
}

@Test("a retried store returns the same name instead of throwing")
func aRetriedStoreReturnsTheSameNameInsteadOfThrowing() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let source = root.appendingPathComponent("source.m4a")
    try writeFakeAudioFile(at: source)

    let store = RecordingStore(directory: root.appendingPathComponent("Recordings"))
    let firstName = try store.store(temporaryURL: source)
    let secondName = try store.store(temporaryURL: source)

    #expect(firstName == secondName)
}

@Test("overwrites a stale destination when the source is still there")
func overwritesAStaleDestinationWhenTheSourceIsStillThere() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let recordings = root.appendingPathComponent("Recordings")
    let source = root.appendingPathComponent("source.m4a")
    try writeFakeAudioFile(at: source)

    let staleDestination = recordings.appendingPathComponent("source.m4a")
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    try Data("stale-bytes".utf8).write(to: staleDestination)

    let store = RecordingStore(directory: recordings)
    let name = try store.store(temporaryURL: source)

    let bytes = try Data(contentsOf: recordings.appendingPathComponent(name))
    #expect(bytes == Data("fake-audio-bytes".utf8))
}

@Test("resolves a stored name to an existing file")
func resolvesAStoredNameToAnExistingFile() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let recordings = root.appendingPathComponent("Recordings")
    let source = root.appendingPathComponent("source.m4a")
    try writeFakeAudioFile(at: source)

    let store = RecordingStore(directory: recordings)
    let name = try store.store(temporaryURL: source)

    let resolved = store.existingURL(for: name)
    #expect(resolved != nil)
    #expect(resolved?.standardizedFileURL == recordings.appendingPathComponent(name).standardizedFileURL)
}

@Test("a stored name with no file resolves to nil")
func aStoredNameWithNoFileResolvesToNil() {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = RecordingStore(directory: root.appendingPathComponent("Recordings"))
    #expect(store.existingURL(for: "gone.m4a") == nil)
}

@Test("accepts a legacy absolute file URL string")
func acceptsALegacyAbsoluteFileURLString() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let elsewhere = root.appendingPathComponent("Elsewhere").appendingPathComponent("legacy.m4a")
    try writeFakeAudioFile(at: elsewhere)

    let store = RecordingStore(directory: root.appendingPathComponent("Recordings"))
    let resolved = store.existingURL(for: elsewhere.absoluteString)

    #expect(resolved?.standardizedFileURL.path == elsewhere.standardizedFileURL.path)
}

@Test("a legacy absolute file URL string with no file resolves to nil")
func aLegacyAbsoluteFileURLStringWithNoFileResolvesToNil() {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = RecordingStore(directory: root.appendingPathComponent("Recordings"))
    #expect(store.existingURL(for: "file:///nope/gone.m4a") == nil)
}

@Test("an empty or blank value resolves to nil")
func anEmptyOrBlankValueResolvesToNil() {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = RecordingStore(directory: root.appendingPathComponent("Recordings"))
    #expect(store.url(for: "") == nil)
    #expect(store.url(for: "   ") == nil)
}

@Test("rejects a non file URL string")
func rejectsANonFileURLString() {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    // Doesn't start with "file://", so it falls into the plain-name branch:
    // treated as a literal file name under `directory` rather than as the
    // URL it looks like. No such file exists, so it resolves to nil.
    let store = RecordingStore(directory: root.appendingPathComponent("Recordings"))
    #expect(store.existingURL(for: "https://example.com/a.m4a") == nil)
}

@Test("storedFileNames is empty when the directory does not exist")
func storedFileNamesIsEmptyWhenTheDirectoryDoesNotExist() {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = RecordingStore(directory: root.appendingPathComponent("Recordings"))
    #expect(store.storedFileNames().isEmpty)
}

@Test("storedFileNames lists regular files and skips subdirectories")
func storedFileNamesListsRegularFilesOnly() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let recordings = root.appendingPathComponent("Recordings")
    try writeFakeAudioFile(at: recordings.appendingPathComponent("one.m4a"))
    try writeFakeAudioFile(at: recordings.appendingPathComponent("two.m4a"))
    try FileManager.default.createDirectory(
        at: recordings.appendingPathComponent("nested", isDirectory: true),
        withIntermediateDirectories: true
    )

    let store = RecordingStore(directory: recordings)
    #expect(Set(store.storedFileNames()) == Set(["one.m4a", "two.m4a"]))
}

@Test("remove deletes one recording and reports whether a file went")
func removeDeletesOneRecording() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let recordings = root.appendingPathComponent("Recordings")
    try writeFakeAudioFile(at: recordings.appendingPathComponent("one.m4a"))
    try writeFakeAudioFile(at: recordings.appendingPathComponent("two.m4a"))

    let store = RecordingStore(directory: recordings)
    #expect(store.remove(name: "one.m4a"))
    #expect(!store.remove(name: "one.m4a"))
    #expect(store.storedFileNames() == ["two.m4a"])
}

@Test("removeAll empties the store and returns how many went")
func removeAllEmptiesTheStore() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let recordings = root.appendingPathComponent("Recordings")
    try writeFakeAudioFile(at: recordings.appendingPathComponent("one.m4a"))
    try writeFakeAudioFile(at: recordings.appendingPathComponent("two.m4a"))
    try writeFakeAudioFile(at: recordings.appendingPathComponent("three.m4a"))

    let store = RecordingStore(directory: recordings)
    #expect(store.removeAll() == 3)
    #expect(store.storedFileNames().isEmpty)
    #expect(store.removeAll() == 0)
}

@Test("usage counts the stored files and sums their bytes")
func usageCountsTheStoredFilesAndSumsTheirBytes() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let recordings = root.appendingPathComponent("Recordings")
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 1_000).write(to: recordings.appendingPathComponent("one.m4a"))
    try Data(repeating: 0x42, count: 2_500).write(to: recordings.appendingPathComponent("two.m4a"))

    let store = RecordingStore(directory: recordings)
    #expect(store.usage() == RecordingStore.Usage(count: 2, bytes: 3_500))
}

@Test("usage is zero when the directory does not exist")
func usageIsZeroWhenTheDirectoryDoesNotExist() {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = RecordingStore(directory: root.appendingPathComponent("Recordings"))
    #expect(store.usage() == RecordingStore.Usage(count: 0, bytes: 0))
}
