import Foundation
import ReloraCore

/// A JSON value with no fixed shape, used for PostgREST row payloads whose
/// columns vary by table. Mirrors the `unknown` values `syncEngine.ts`
/// reads out of SQLite rows and Supabase responses.
public enum JSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
        } else if let numberValue = try? container.decode(Double.self) {
            self = .number(numberValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let arrayValue = try? container.decode([JSONValue].self) {
            self = .array(arrayValue)
        } else if let objectValue = try? container.decode([String: JSONValue].self) {
            self = .object(objectValue)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

/// A PostgREST row: table columns keyed by name, value shape decided per
/// row. Mirrors `Record<string, unknown>` in syncEngine.ts.
public typealias JSONObject = [String: JSONValue]

/// A thin, typed PostgREST client covering exactly what the sync engine
/// needs: table-scoped upsert and paginated select. Not a general
/// postgrest-js port — no filter DSL, no joins, no RPC.
///
/// Every request carries `apikey`, `Authorization: Bearer <token>`, and
/// (for bodies) `Content-Type: application/json`, matching how
/// `@supabase/supabase-js` attaches its client-level headers to every
/// PostgREST call the RN sync engine makes.
public final class PostgRESTLite: Sendable {
    /// Tables the sync engine is allowed to touch. Mirrors `TABLES` in
    /// apps/mobile/src/sync/syncEngine.ts, plus `voice_note_usage_events`
    /// (written directly by the transcription edge function's usage
    /// ledger, not by the sync engine's dirty-row loop, but read here for
    /// quota display). Anything else — e.g. a `tidynote_*` table reachable
    /// only from a different app target — is a programmer error.
    public static let allowedTables: Set<String> = [
        "contacts",
        "key_things",
        "memories",
        "reminders",
        "voice_note_usage_events",
    ]

    private let config: BackendConfig
    private let tokenProvider: AccessTokenProvider
    private let session: URLSession

    public init(config: BackendConfig, tokenProvider: AccessTokenProvider, session: URLSession = .shared) {
        self.config = config
        self.tokenProvider = tokenProvider
        self.session = session
    }

    /// Upserts `rows` into `table` via `POST /rest/v1/{table}`.
    ///
    /// Sends `Prefer: resolution=merge-duplicates` and, when `onConflict`
    /// is given, `on_conflict={columns}` — exactly what postgrest-js's
    /// `.upsert(rows, { onConflict })` sends (verified against
    /// `@supabase/postgrest-js` 2.95.3's `PostgrestQueryBuilder.upsert`,
    /// the version syncEngine.ts's `supabase.from(table).upsert(rows, {
    /// onConflict: 'id' })` call actually runs against). It also sets a
    /// `columns` query param listing the union of keys across `rows` —
    /// postgrest-js always adds this for array upserts; the sync engine
    /// never opts out, so this client always sends it too. No
    /// `Prefer: return=` is sent (the sync engine never chains
    /// `.select()`), so PostgREST replies with an empty body — this
    /// method has no return value.
    public func upsert(table: String, rows: [JSONObject], onConflict: String?) async throws {
        try Self.requireAllowedTable(table)
        guard !rows.isEmpty else { return }

        var components = URLComponents(url: restURL(table: table), resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = []
        if let onConflict {
            queryItems.append(URLQueryItem(name: "on_conflict", value: onConflict))
        }
        let columns = Self.unionOfKeys(rows)
        if !columns.isEmpty {
            let quoted = columns.map { "\"\($0)\"" }.joined(separator: ",")
            queryItems.append(URLQueryItem(name: "columns", value: quoted))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        try await applyCommonHeaders(to: &request, hasBody: true)
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode(rows)

        let (data, response) = try await performRequest(request)
        try Self.throwIfError(data: data, response: response)
    }

    /// Selects `*` from `table` via `GET /rest/v1/{table}`, applying
    /// `filters` as PostgREST operator query params (e.g. `updated_at =
    /// gt.<cursor>` should be built by the caller as
    /// `URLQueryItem(name: "updated_at", value: "gt.<cursor>")`, matching
    /// what `.gt('updated_at', cursor)` sends), `order` verbatim as the
    /// `order` param (e.g. `"updated_at.asc,id.asc"`, matching two
    /// chained `.order()` calls), and `range` as `offset`/`limit` query
    /// params.
    ///
    /// `range` is `(from, to)`, both 0-based and inclusive — the same
    /// contract as postgrest-js's `.range(from, to)`. That method does
    /// **not** send a `Range` header in the installed version
    /// (`@supabase/postgrest-js` 2.95.3): `PostgrestTransformBuilder.range`
    /// sets `offset={from}` and `limit={to - from + 1}` query params
    /// instead, so this client matches that, not the older Range-header
    /// convention.
    public func select(
        table: String,
        filters: [URLQueryItem],
        order: String,
        range: (from: Int, to: Int)
    ) async throws -> [JSONObject] {
        try Self.requireAllowedTable(table)

        var components = URLComponents(url: restURL(table: table), resolvingAgainstBaseURL: false)!
        var queryItems = [URLQueryItem(name: "select", value: "*")]
        queryItems.append(contentsOf: filters)
        if !order.isEmpty {
            queryItems.append(URLQueryItem(name: "order", value: order))
        }
        queryItems.append(URLQueryItem(name: "offset", value: String(range.from)))
        queryItems.append(URLQueryItem(name: "limit", value: String(range.to - range.from + 1)))
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        try await applyCommonHeaders(to: &request, hasBody: false)

        let (data, response) = try await performRequest(request)
        try Self.throwIfError(data: data, response: response)

        guard !data.isEmpty else { return [] }
        do {
            return try JSONDecoder().decode([JSONObject].self, from: data)
        } catch {
            throw BackendError(code: BackendError.invalidResponse, message: "Could not decode select response", httpStatus: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    // MARK: - Request plumbing

    private func restURL(table: String) -> URL {
        config.supabaseURL.appendingPathComponent("rest/v1/\(table)")
    }

    private func applyCommonHeaders(to request: inout URLRequest, hasBody: Bool) async throws {
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        guard let token = try await tokenProvider.accessToken() else {
            throw BackendError(code: BackendError.authRequired, message: "No active session", httpStatus: 401)
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if hasBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let urlError as URLError {
            throw BackendError(code: BackendError.networkError, message: urlError.localizedDescription, httpStatus: 0)
        }
    }

    private static func requireAllowedTable(_ table: String) throws {
        guard allowedTables.contains(table) else {
            throw BackendError(
                code: BackendError.disallowedTable,
                message: "Table '\(table)' is not in PostgRESTLite's allowlist",
                httpStatus: 0
            )
        }
    }

    private static func unionOfKeys(_ rows: [JSONObject]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for row in rows {
            for key in row.keys where !seen.contains(key) {
                seen.insert(key)
                ordered.append(key)
            }
        }
        return ordered
    }

    /// Decodes a non-2xx response into `BackendError`, trying each shape
    /// this backend is known to emit, in order of how much detail it
    /// carries:
    /// 1. The flat `{ error, code }` edge-function envelope (via
    ///    `BackendError.fromEdgeFunctionBody` — see that method's doc for
    ///    why it's flat, not nested). A PostgREST table endpoint never
    ///    emits this exact shape, but trying it first is free.
    /// 2. PostgREST's own error body — `{ message, details?, hint?,
    ///    code? }`, where `code` is a Postgres/PostgREST error code, not
    ///    one of this backend's stable string codes. This is the shape a
    ///    `/rest/v1/{table}` call actually fails with (RLS denial,
    ///    constraint violation, malformed filter, ...).
    /// 3. Status-only, when the body is empty or neither shape parses.
    private static func throwIfError(data: Data, response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendError(code: BackendError.networkError, message: "No HTTP response", httpStatus: 0)
        }
        guard !(200...299).contains(httpResponse.statusCode) else { return }

        struct EdgeFunctionEnvelope: Decodable { let error: String; let code: String }
        struct PostgRESTEnvelope: Decodable { let message: String; let code: String?; let details: String?; let hint: String? }

        if (try? JSONDecoder().decode(EdgeFunctionEnvelope.self, from: data)) != nil {
            throw BackendError.fromEdgeFunctionBody(data, httpStatus: httpResponse.statusCode)
        }
        if let envelope = try? JSONDecoder().decode(PostgRESTEnvelope.self, from: data) {
            throw BackendError(code: envelope.code ?? "POSTGREST_ERROR", message: envelope.message, httpStatus: httpResponse.statusCode)
        }
        throw BackendError(
            code: "HTTP_\(httpResponse.statusCode)",
            message: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
            httpStatus: httpResponse.statusCode
        )
    }
}
