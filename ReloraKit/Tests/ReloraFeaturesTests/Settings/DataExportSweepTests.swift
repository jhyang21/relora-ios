import Foundation
import Testing
@testable import ReloraFeatures

@Suite("DataExport.sweepStaleFiles")
struct DataExportSweepTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("{}".utf8).write(to: url)
        return url
    }

    @Test("Removes every export file, however recent")
    func removesExports() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try write("relora-export-1.json", in: directory)
        let second = try write("relora-export-999999999.json", in: directory)

        #expect(DataExport.sweepStaleFiles(in: directory) == 2)
        #expect(FileManager.default.fileExists(atPath: first.path) == false)
        #expect(FileManager.default.fileExists(atPath: second.path) == false)
    }

    /// The recording sweep owns `relora-recording-*.m4a`. Neither sweep
    /// may reach into the other's files.
    @Test("Leaves recordings and anything else alone")
    func leavesOtherFilesAlone() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let recording = try write("relora-recording-abc.m4a", in: directory)
        let unrelated = try write("notes.json", in: directory)
        let wrongExtension = try write("relora-export-1.txt", in: directory)

        #expect(DataExport.sweepStaleFiles(in: directory) == 0)
        #expect(FileManager.default.fileExists(atPath: recording.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: wrongExtension.path))
    }

    @Test("A missing directory sweeps nothing rather than throwing")
    func missingDirectoryIsSafe() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        #expect(DataExport.sweepStaleFiles(in: missing) == 0)
    }
}
