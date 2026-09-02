import Foundation
import SwiftUI
import UIKit
import GRDB
import ReloraCore

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

    public static func export(userID: String, database: AppDatabase, now: Date = Date()) throws -> URL {
        let json = try buildJSON(userID: userID, database: database)
        // `Date.now()` in the RN filename is a millisecond epoch integer —
        // matched here rather than an ISO string so a file from either
        // build sorts and names the same way.
        let fileName = "relora-export-\(Int((now.timeIntervalSince1970 * 1000).rounded())).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw ExportError.writeFailed
        }
        return url
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
        UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
