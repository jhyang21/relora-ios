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

@Test("round trips through store and back")
func roundTripsThroughStoreAndBack() throws {
    let root = makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let source = root.appendingPathComponent("source.m4a")
    try writeFakeAudioFile(at: source)

    let store = RecordingStore(directory: root.appendingPathComponent("Recordings"))
    let name = try store.store(temporaryURL: source)

    let resolved = try #require(store.existingURL(for: name))
    let bytes = try Data(contentsOf: resolved)
    #expect(bytes == Data("fake-audio-bytes".utf8))
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

    // Doesn't start with "file://" or "/", so it falls into the plain-name
    // branch: treated as a literal file name under `directory` rather than
    // as the URL it looks like. No such file exists, so it resolves to nil.
    let store = RecordingStore(directory: root.appendingPathComponent("Recordings"))
    #expect(store.existingURL(for: "https://example.com/a.m4a") == nil)
}
