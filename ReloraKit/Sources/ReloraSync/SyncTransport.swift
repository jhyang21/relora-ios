import Foundation
import ReloraCore

/// Abstracts the network calls `SyncEngine` needs, so it can be driven by an
/// in-memory stub in tests instead of `PostgRESTLite`/`URLSession`. Mirrors
/// the two Supabase client calls syncEngine.ts makes: `.from(table).upsert(rows,
/// { onConflict })` and a paginated `.from(table).select('*').eq('user_id',
/// userId).order(...).order(...).range(from, to)` (optionally `.gt('updated_at',
/// cursor)`).
public protocol SyncTransport: Sendable {
    /// Upserts `rows` into `table` on conflict of `onConflict` (always `"id"`
    /// in this engine). An empty `rows` array must be a no-op that sends no
    /// request, matching `PostgRESTLite.upsert`.
    func upsert(table: SyncTable, rows: [JSONObject], onConflict: String) async throws

    /// Fetches one page of `table`'s rows for `userID`, ordered
    /// `updated_at asc, id asc` (the tie-break RN adds via a second chained
    /// `.order('id', { ascending: true })`, needed because the sync cursor
    /// is a single `updated_at` value — without a stable secondary sort, two
    /// rows sharing an `updated_at` could paginate in different relative
    /// orders across requests and one could be skipped). `updatedAfter` nil
    /// means no lower bound (a fresh cursor); otherwise only rows with
    /// `updated_at > updatedAfter` are returned. `range` is `(from, to)`,
    /// both 0-based and inclusive, matching `PostgRESTLite.select`.
    func pull(
        table: SyncTable,
        userID: String,
        updatedAfter: String?,
        range: (from: Int, to: Int)
    ) async throws -> [JSONObject]
}

/// Production `SyncTransport`, backed by `PostgRESTLite`. Scopes every pull
/// to one user's rows via an `eq.` filter, mirroring syncEngine.ts's
/// `.eq('user_id', userId)` (push relies on the row's own `user_id` column
/// plus RLS, exactly as the RN client does — it never adds a user filter to
/// the upsert call).
public struct PostgRESTSyncTransport: SyncTransport {
    private let client: PostgRESTLite

    public init(client: PostgRESTLite) {
        self.client = client
    }

    public func upsert(table: SyncTable, rows: [JSONObject], onConflict: String) async throws {
        try await client.upsert(table: table.rawValue, rows: rows, onConflict: onConflict)
    }

    public func pull(
        table: SyncTable,
        userID: String,
        updatedAfter: String?,
        range: (from: Int, to: Int)
    ) async throws -> [JSONObject] {
        var filters = [URLQueryItem(name: "user_id", value: "eq.\(userID)")]
        if let updatedAfter {
            filters.append(URLQueryItem(name: "updated_at", value: "gt.\(updatedAfter)"))
        }
        return try await client.select(
            table: table.rawValue,
            filters: filters,
            order: "updated_at.asc,id.asc",
            range: range
        )
    }
}
