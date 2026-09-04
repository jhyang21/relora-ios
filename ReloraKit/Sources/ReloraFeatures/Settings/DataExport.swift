import Foundation
import SwiftUI
import UIKit
import GRDB
import ReloraCore
import ReloraData

/// Ports `exportDataToJson` (dataControls.ts): the four owned tables' raw
/// rows for one user, as `{ contacts, keyThings, memories, reminders }`,
/// written to `relora-export-{timestamp}.json` for the share sheet.
///
/// Exports the tables' actual SQLite rows — snake_case column names and
/// all — rather than re-serializing the app's camelCase domain structs.
/// RN's export reads the same raw rows (`db.getAllAsync('SELECT * FROM ...')`)
/// against the same mirrored schema, and matching that column-for-column is
/// the whole point of a data export: someone moving their data out should
/// see the shape their local database actually stores, not a shape this
/// port invented.
public enum DataExport {
    public enum ExportError: Error, Sendable {
        case writeFailed
    }

    /// `sweepStaleFiles` matches on these two, so they are stated once
    /// rather than spelled into the file name and the filter separately.
    static let fileNamePrefix = "relora-export-"
    static let fileExtension = "json"

    public static func export(userID: String, database: AppDatabase, now: Date = Date()) throws -> URL {
        let json = try buildJSON(userID: userID, database: database)
        // `Date.now()` in the RN filename is a millisecond epoch integer —
        // matched here rather than an ISO string so a file from either
        // build sorts and names the same way.
        let fileName = "\(fileNamePrefix)\(Int((now.timeIntervalSince1970 * 1000).rounded())).\(fileExtension)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
            // This file holds every note the user has, in clear text, and
            // it lives only while the share sheet is open. `.complete` is
            // safe here for exactly that reason: nothing reads it while
            // the device is locked.
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
        } catch {
            throw ExportError.writeFailed
        }
        return url
    }

    /// Deletes export files an earlier run left behind. Called at launch.
    ///
    /// `ExportShareSheet` removes its own file when the sheet closes, so
    /// this only catches what a crash or a kill left there.
    ///
    /// Never throws, and takes no grace window — an export is consumed by
    /// the share sheet that opened it, so a file still on disk at the next
    /// launch is by definition finished with.
    public static func sweepStaleFiles(
        in directory: URL = FileManager.default.temporaryDirectory
    ) -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var removed = 0
        for url in entries where url.lastPathComponent.hasPrefix(fileNamePrefix) && url.pathExtension == fileExtension {
            do {
                try FileManager.default.removeItem(at: url)
                removed += 1
            } catch {
                continue
            }
        }
        return removed
    }

    static func buildJSON(userID: String, database: AppDatabase) throws -> String {
        let payload: [String: Any] = try database.read { db in
            [
                "contacts": try rows(db, table: "contacts", userID: userID),
                "keyThings": try rows(db, table: "key_things", userID: userID),
                "memories": try rows(db, table: "memories", userID: userID),
                "reminders": try rows(db, table: "reminders", userID: userID),
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func rows(_ db: Database, table: String, userID: String) throws -> [[String: Any]] {
        // `table` is always one of the four constants above — never
        // user-supplied — so interpolating it into the SQL string is safe;
        // GRDB has no parameter binding for identifiers.
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table) WHERE user_id = ?", arguments: [userID])
        return rows.map(jsonObject)
    }

    private static func jsonObject(_ row: Row) -> [String: Any] {
        var object: [String: Any] = [:]
        for columnName in row.columnNames {
            let value: DatabaseValue = row[columnName]
            object[columnName] = jsonValue(value)
        }
        return object
    }

    private static func jsonValue(_ value: DatabaseValue) -> Any {
        switch value.storage {
        case .null: return NSNull()
        case .int64(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .blob(let data): return data.base64EncodedString()
        }
    }
}

/// The OS share sheet, opened the moment export produces a file — mirrors
/// `Sharing.shareAsync(exportFile.uri)` running right after the write, with
/// no separate "now tap to share" step. SwiftUI's `ShareLink` cannot be
/// triggered programmatically (it presents only from a tap on its own
/// label), so this wraps `UIActivityViewController` directly.
struct ExportShareSheet: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        // The file has served its purpose the moment the sheet closes,
        // whether the user shared it or backed out. Leaving a clear-text
        // copy of every note in the temporary directory until iOS feels
        // like purging it is the one thing this sheet must not do.
        controller.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: fileURL)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
