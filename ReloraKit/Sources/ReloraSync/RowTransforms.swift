import Foundation
import GRDB
import ReloraCore
import ReloraData

/// The four syncable tables, in the exact order `syncEngine.ts`'s `TABLES`
/// constant processes them for both push and pull. Order is load-bearing:
/// `contacts` is the parent row `key_things`/`memories`/`reminders`
/// foreign-key onto, so it is always pushed and pulled first. `CaseIterable`
/// synthesizes `allCases` in this declaration order — do not reorder the
/// cases without re-checking every caller that relies on `allCases`.
///
/// `voice_note_usage_events` is deliberately absent: syncEngine.ts's `TABLES`
/// constant never includes it — that table is written directly by the
/// transcription edge function's usage ledger, not by the dirty-row sync
/// loop (see `.claude/rules/data-model.md`).
public enum SyncTable: String, CaseIterable, Sendable {
    case contacts
    case keyThings = "key_things"
    case memories
    case reminders
}

/// Pure row transforms between the local GRDB representation and the
/// PostgREST wire representation. Ported from two places in
/// apps/mobile/src/sync/syncEngine.ts: `transformRowForSupabase` (push) and
/// the column handling inline in `syncAll`'s write-phase upsert (pull).
public enum RowTransforms {
    /// Columns that exist only in the local SQLite schema and have no
    /// server-side counterpart at all (see the server table definitions in
    /// apps/api/supabase/migrations/20260306_000001_relora_baseline.sql).
    /// Stripped unconditionally before push, mirroring
    /// `transformRowForSupabase`'s four `delete out.*` calls, which run
    /// against every table regardless of whether that table actually has
    /// the column (`notification_id` only exists on `reminders`,
    /// `audio_local_uri` only on `memories` — deleting an absent key is a
    /// harmless no-op in both the RN object-delete and this Swift
    /// `removeValue` port).
    ///
    /// These same names are why the pull direction needs no explicit
    /// preservation logic: a server row's JSON keys are exactly the
    /// server's own columns, so a pulled row can never contain
    /// `is_dirty`/`dirty_at`/`notification_id`/`audio_local_uri` in the
    /// first place. The generated column list for the pull upsert (built
    /// from the pulled row's own keys in `SyncEngine`) can therefore never
    /// name these columns, so an existing local `notification_id` or
    /// `audio_local_uri` on a row already present locally is left
    /// untouched by construction — there is no local-only column to
    /// "preserve" on the pull side because nothing ever names it in the
    /// SET list.
    static let localOnlyColumns: Set<String> = [
        "is_dirty", "dirty_at", "notification_id", "audio_local_uri"
    ]

    /// The one TEXT-JSON-encoded `[String]` column per table that needs a
    /// real JSON array on the wire. `key_things` and `reminders` have no
    /// such column (see `ReloraCore.KeyThing`'s doc note that, unlike
    /// `Memory`, it carries no `labels`).
    static let arrayColumns: [SyncTable: String] = [
        .contacts: "descriptors",
        .memories: "labels"
    ]

    // MARK: - Push: local row -> PostgREST row

    /// Transforms one row as read from GRDB (`Row.asJSONObject()`) into the
    /// payload `SyncTransport.upsert` sends to the server: local-only
    /// columns stripped, the table's TEXT-JSON array column decoded into a
    /// real JSON array, every other column carried through verbatim.
    public static func rowForPush(table: SyncTable, localRow: JSONObject) -> JSONObject {
        var out = localRow
        for column in localOnlyColumns {
            out.removeValue(forKey: column)
        }
        if let arrayColumn = arrayColumns[table] {
            out[arrayColumn] = .array(decodedArrayColumn(out[arrayColumn]))
        }
        return out
    }

    /// Mirrors the `try { JSON.parse(...) } catch { = [] }` fallback in
    /// `transformRowForSupabase` — a local array column that fails to
    /// decode (corrupt TEXT-JSON) pushes as an empty array rather than
    /// failing the whole batch.
    private static func decodedArrayColumn(_ value: JSONValue?) -> [JSONValue] {
        guard case .string(let text)? = value else { return [] }
        guard let strings = try? TextJSONArray.decode(text) else { return [] }
        return strings.map { .string($0) }
    }

    // MARK: - Pull: PostgREST row -> local column values

    /// Local column assignments for one pulled server row: the table's
    /// array column (a real JSON array on the wire) re-encoded to this
    /// schema's TEXT-JSON representation, every other server column carried
    /// through verbatim. The result's key set is exactly the server row's
    /// key set — see `localOnlyColumns`'s doc for why that is what keeps a
    /// pull from ever clobbering a local-only column.
    public static func localColumns(table: SyncTable, serverRow: JSONObject) -> JSONObject {
        var out = serverRow
        if let arrayColumn = arrayColumns[table], let value = out[arrayColumn] {
            out[arrayColumn] = .string(TextJSONArray.encode(stringArray(from: value)))
        }
        return out
    }

    private static func stringArray(from value: JSONValue) -> [String] {
        guard case .array(let items) = value else { return [] }
        return items.compactMap { item in
            if case .string(let string) = item { return string }
            return nil
        }
    }
}

// MARK: - GRDB <-> JSONObject glue

extension Row {
    /// Reads every column of a fetched row into `JSONObject`. SQLite's
    /// storage classes map the same way `toSQLiteBindValue`'s *reverse*
    /// direction does in the RN client: TEXT -> `.string`, INTEGER/REAL ->
    /// `.number`, NULL -> `.null`. None of the four synced tables declare a
    /// BLOB column, so BLOB maps to `.null` defensively rather than
    /// silently losing data through a case this schema never produces.
    public func asJSONObject() -> JSONObject {
        var out: JSONObject = [:]
        for (columnName, dbValue) in self {
            out[columnName] = dbValue.asJSONValue()
        }
        return out
    }
}

extension DatabaseValue {
    fileprivate func asJSONValue() -> JSONValue {
        switch storage {
        case .null: return .null
        case .int64(let value): return .number(Double(value))
        case .double(let value): return .number(value)
        case .string(let value): return .string(value)
        case .blob: return .null
        }
    }
}

extension JSONValue {
    /// Converts a post-`RowTransforms.localColumns` value into a GRDB bind
    /// value for the pull-applied `INSERT ... ON CONFLICT` statement.
    /// `.array`/`.object` are not expected here — `localColumns` always
    /// re-encodes the one array column to `.string` before this is called —
    /// so they map to `nil` rather than being force-unwrapped or crashing.
    public func asSQLiteBindValue() -> DatabaseValueConvertible? {
        switch self {
        case .null: return nil
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value ? 1 : 0
        case .array, .object: return nil
        }
    }
}
