import Foundation
import GRDB

/// Process-wide "is the FTS index usable" flag, ported from the module-level
/// `let searchIndexUsable` in apps/mobile/src/db/search.ts. It starts `true`
/// and latches to `false` the first time a rebuild/refresh/initialize call hits
/// an FTS error, after which every read goes through the LIKE fallback for the
/// rest of the process's lifetime — matching the RN behavior of never
/// re-probing FTS once it has misbehaved.
///
/// This is genuinely process-wide state, which is what the port asked for, but
/// it also means the flag leaks between tests unless each test resets it —
/// `resetForTesting()` exists for exactly that and must never be called from
/// production code.
public final class SearchIndexState: @unchecked Sendable {
    public static let shared = SearchIndexState()

    private let lock = NSLock()
    private var usable = true

    private init() {}

    public func isUsable() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return usable
    }

    func disable() {
        lock.lock()
        defer { lock.unlock() }
        usable = false
    }

    /// Test-only: restores the flag to enabled so one test's induced FTS
    /// failure does not silently degrade every later test to the LIKE path.
    public func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        usable = true
    }
}

/// Full-text search over contacts, ported from apps/mobile/src/db/search.ts.
/// Every function here takes a `Database` and is meant to be called either
/// from inside an already-open `AppDatabase.write`/`.read` block (so a write
/// path like `ContactRepository.upsert` can refresh the index in the same
/// transaction as its row write, exactly as `upsertContact` does) or through
/// the `AppDatabase`-scoped overloads below for standalone callers.
public enum ContactSearchIndex {
    static let rebuildFlagKey = "contact_search_needs_rebuild"
    private static let matchSnippetMaxLength = 80

    /// Builds a safe FTS5 MATCH expression from raw user input. Each
    /// whitespace token becomes a quoted prefix query (`"token"*`), which
    /// neutralizes FTS5 operators (AND/OR/NOT, -, :, *) and embedded quotes.
    /// Returns `nil` when the input has no searchable tokens.
    public static func buildMatchExpression(_ raw: String) -> String? {
        let tokens = raw
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "\"\"") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    /// Fills every column `contact_search` declares, for every live contact.
    /// The single-row refresh and full rebuild both start from this and add
    /// their own `WHERE`/`AND` clause — a column list that drifts from
    /// `CREATE VIRTUAL TABLE` is what breaks the index.
    private static let insertSQL = """
        INSERT INTO contact_search (contact_id, name, descriptors, phone_number, email, key_things, memories, transcripts)
        SELECT
          c.id,
          c.name,
          COALESCE(c.descriptors, '[]'),
          COALESCE(c.phone_number, ''),
          COALESCE(c.email, ''),
          COALESCE((SELECT group_concat(k.text, ' ') FROM key_things k WHERE k.contact_id = c.id AND k.deleted_at IS NULL), ''),
          COALESCE((SELECT group_concat(m.text, ' ') FROM memories m WHERE m.contact_id = c.id AND m.deleted_at IS NULL), ''),
          COALESCE((SELECT group_concat(m.transcript, ' ') FROM memories m WHERE m.contact_id = c.id AND m.deleted_at IS NULL AND m.transcript IS NOT NULL), '')
        FROM contacts c
        WHERE c.deleted_at IS NULL
        """

    // MARK: - Database-scoped primitives (call inline within an open transaction)

    /// Refreshes the FTS row for a single contact after a local write.
    /// Best-effort: any failure disables the index process-wide and falls
    /// through silently, exactly as `refreshContactSearchRow` does.
    public static func refreshRow(_ db: Database, contactID: String) {
        guard SearchIndexState.shared.isUsable() else { return }
        do {
            try maybeRebuild(db)
            try db.execute(sql: "DELETE FROM contact_search WHERE contact_id = ?", arguments: [contactID])
            try db.execute(sql: "\(insertSQL) AND c.id = ?", arguments: [contactID])
        } catch {
            SearchIndexState.shared.disable()
        }
    }

    /// Rebuilds the full contact search index from the current SQLite tables.
    /// Best-effort, same as `rebuildSearchIndex` in search.ts.
    public static func rebuild(_ db: Database) {
        guard SearchIndexState.shared.isUsable() else { return }
        do {
            try db.execute(sql: "DELETE FROM contact_search")
            try db.execute(sql: insertSQL)
            try markRebuildComplete(db)
        } catch {
            SearchIndexState.shared.disable()
        }
    }

    /// Runs any rebuild deferred by `search_index_meta.contact_search_needs_rebuild`.
    /// Best-effort, same as `initializeSearchIndex` in search.ts.
    public static func initialize(_ db: Database) {
        guard SearchIndexState.shared.isUsable() else { return }
        do {
            try maybeRebuild(db)
        } catch {
            SearchIndexState.shared.disable()
        }
    }

    /// Flags the index for a rebuild on the next search. Called after a sync
    /// pull writes rows, since pulled content (including tombstones from
    /// other devices) bypasses the per-write `refreshRow` path. Unlike the
    /// three functions above this one is not best-effort in the RN source
    /// (`markSearchIndexNeedsRebuild` has no internal try/catch), so it
    /// propagates.
    public static func markNeedsRebuild(_ db: Database) throws {
        try db.execute(
            sql: "INSERT INTO search_index_meta (key, value) VALUES (?, '1') ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [rebuildFlagKey]
        )
    }

    /// Searches contact ids through FTS, falling back to SQL LIKE when the
    /// index is unavailable or a MATCH query fails. A per-call MATCH failure
    /// does NOT disable the index (mirroring search.ts's comment: "not proof
    /// the index is structurally broken") — only `refreshRow`/`rebuild`/
    /// `initialize` latch the process-wide flag off.
    public static func searchContactIDs(_ db: Database, query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard SearchIndexState.shared.isUsable() else {
            return (try? searchContactIDsLike(db, query: trimmed)) ?? []
        }
        guard let matchExpression = buildMatchExpression(trimmed) else { return [] }

        do {
            try maybeRebuild(db)
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT contact_id FROM contact_search WHERE contact_search MATCH ? LIMIT 50",
                arguments: [matchExpression]
            )
            return rows.map { row -> String in row["contact_id"] }
        } catch {
            return (try? searchContactIDsLike(db, query: trimmed)) ?? []
        }
    }

    /// For each contact id, the text snippet explaining why the query matched
    /// when the match came from a key thing or memory rather than the
    /// name/descriptors/phone/email already visible in the row. Queries
    /// `key_things`/`memories` directly (not the FTS table), so it works
    /// whether `searchContactIDs` resolved through FTS or the LIKE fallback.
    /// Contacts with no result are omitted (name-level match, no snippet
    /// needed).
    public static func matchSnippets(_ db: Database, contactIDs: [String], query: String) throws -> [String: String] {
        var snippets: [String: String] = [:]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contactIDs.isEmpty, !trimmed.isEmpty else { return snippets }

        let wildcard = "%\(trimmed)%"
        let placeholders = contactIDs.map { _ in "?" }.joined(separator: ", ")
        var keyThingArguments: [DatabaseValueConvertible?] = contactIDs.map { $0 as DatabaseValueConvertible? }
        keyThingArguments.append(wildcard)

        let keyThingRows = try Row.fetchAll(
            db,
            sql: """
                SELECT contact_id, text FROM key_things
                WHERE contact_id IN (\(placeholders)) AND deleted_at IS NULL AND text LIKE ?
                ORDER BY updated_at DESC
                """,
            arguments: StatementArguments(keyThingArguments)
        )
        for row in keyThingRows {
            let contactID: String = row["contact_id"]
            if snippets[contactID] == nil {
                snippets[contactID] = extractMatchSnippet(text: row["text"], query: trimmed)
            }
        }

        let remainingIDs = contactIDs.filter { snippets[$0] == nil }
        if !remainingIDs.isEmpty {
            let memoryPlaceholders = remainingIDs.map { _ in "?" }.joined(separator: ", ")
            var memoryArguments: [DatabaseValueConvertible?] = remainingIDs.map { $0 as DatabaseValueConvertible? }
            memoryArguments.append(wildcard)
            memoryArguments.append(wildcard)

            let memoryRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT contact_id, text, transcript FROM memories
                    WHERE contact_id IN (\(memoryPlaceholders))
                      AND deleted_at IS NULL
                      AND (text LIKE ? OR transcript LIKE ?)
                    ORDER BY updated_at DESC
                    """,
                arguments: StatementArguments(memoryArguments)
            )
            let lowerQuery = trimmed.lowercased()
            for row in memoryRows {
                let contactID: String = row["contact_id"]
                if snippets[contactID] != nil { continue }
                let text: String = row["text"]
                let transcript: String? = row["transcript"]
                // Quote the transcript when that is where the words are, so the
                // result does not show a memory that plainly does not contain
                // the query.
                let matchedTranscript = !text.lowercased().contains(lowerQuery)
                    && (transcript?.lowercased().contains(lowerQuery) ?? false)
                let source = matchedTranscript ? (transcript ?? text) : text
                snippets[contactID] = extractMatchSnippet(text: source, query: trimmed)
            }
        }

        return snippets
    }

    // MARK: - AppDatabase-scoped convenience wrappers (standalone callers)

    public static func initialize(_ database: AppDatabase) throws {
        try database.write { db in initialize(db) }
    }

    public static func markNeedsRebuild(_ database: AppDatabase) throws {
        try database.write { db in try markNeedsRebuild(db) }
    }

    public static func searchContactIDs(_ database: AppDatabase, query: String) throws -> [String] {
        try database.read { db in searchContactIDs(db, query: query) }
    }

    public static func matchSnippets(_ database: AppDatabase, contactIDs: [String], query: String) throws -> [String: String] {
        try database.read { db in try matchSnippets(db, contactIDs: contactIDs, query: query) }
    }

    // MARK: - Internals

    private static func shouldRebuild(_ db: Database) throws -> Bool {
        let value = try String.fetchOne(db, sql: "SELECT value FROM search_index_meta WHERE key = ?", arguments: [rebuildFlagKey])
        return value == "1"
    }

    private static func markRebuildComplete(_ db: Database) throws {
        try db.execute(
            sql: "INSERT INTO search_index_meta (key, value) VALUES (?, '0') ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [rebuildFlagKey]
        )
    }

    private static func maybeRebuild(_ db: Database) throws {
        if try shouldRebuild(db) {
            rebuild(db)
        }
    }

    private static func searchContactIDsLike(_ db: Database, query: String) throws -> [String] {
        let wildcard = "%\(query)%"
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT c.id
                FROM contacts c
                WHERE c.deleted_at IS NULL
                  AND (
                    c.name LIKE ?
                    OR c.descriptors LIKE ?
                    OR c.phone_number LIKE ?
                    OR c.email LIKE ?
                    OR EXISTS (
                      SELECT 1 FROM key_things k
                      WHERE k.contact_id = c.id AND k.deleted_at IS NULL AND k.text LIKE ?
                    )
                    OR EXISTS (
                      SELECT 1 FROM memories m
                      WHERE m.contact_id = c.id AND m.deleted_at IS NULL AND (m.text LIKE ? OR m.transcript LIKE ?)
                    )
                  )
                ORDER BY c.updated_at DESC
                LIMIT 50
                """,
            arguments: [wildcard, wildcard, wildcard, wildcard, wildcard, wildcard, wildcard]
        )
        return rows.map { row -> String in row["id"] }
    }

    /// Trims free text down to a short window around the query match, for
    /// display. Ported from `extractMatchSnippet` in search.ts; uses Swift
    /// `Character` counts rather than JavaScript's UTF-16 code-unit lengths,
    /// which only differ for astral-plane characters (rare in this app's
    /// plain-text fields) — see the M2 report for the full note.
    private static func extractMatchSnippet(text: String, query: String) -> String {
        guard let range = text.range(of: query, options: .caseInsensitive) else {
            // Multi-token queries can match via FTS token union rather than one
            // contiguous run, so fall back to the start of the text.
            if text.count > matchSnippetMaxLength {
                let endIndex = text.index(text.startIndex, offsetBy: matchSnippetMaxLength)
                return "\(text[..<endIndex].trimmingCharacters(in: .whitespacesAndNewlines))…"
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let matchStartOffset = text.distance(from: text.startIndex, to: range.lowerBound)
        let matchLength = text.distance(from: range.lowerBound, to: range.upperBound)
        let startOffset = max(0, matchStartOffset - 20)
        let endOffset = min(text.count, matchStartOffset + matchLength + 40)
        let startIndex = text.index(text.startIndex, offsetBy: startOffset)
        let endIndex = text.index(text.startIndex, offsetBy: endOffset)
        let prefix = startOffset > 0 ? "…" : ""
        let suffix = endOffset < text.count ? "…" : ""
        return "\(prefix)\(text[startIndex..<endIndex].trimmingCharacters(in: .whitespacesAndNewlines))\(suffix)"
    }
}
