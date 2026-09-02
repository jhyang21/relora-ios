import Foundation
import ReloraCore

/// Server-side voice-note usage counts for a signed-in identity. Ports the
/// two `supabase.from('voice_note_usage_events').select('*', { count:
/// 'exact', head: true })` calls in `getServerUsageSummary`
/// (apps/mobile/src/features/billing/storage.ts) — a lifetime count and a
/// current-calendar-month count, run in parallel.
///
/// Deliberately its own tiny client rather than a `PostgRESTLite` addition:
/// `PostgRESTLite` (ReloraSync) only ever issues `GET`/`POST` requests that
/// decode a JSON body, and postgrest-js's `count: 'exact', head: true`
/// combination is a `HEAD` request with no body at all — the count comes
/// back in the `Content-Range` response header instead. `PostgRESTLite` is
/// also owned by ReloraSync, not this module.
public protocol ServerUsageQuerying: Sendable {
    /// Throws on any failure (no session, network, a non-2xx response, or a
    /// missing/unparseable `Content-Range`) so the caller —
    /// `RevenueCatVoiceAccess`, ReloraFeatures/Billing — can fall back to
    /// the local ledger, matching `getUsageSummary`'s try/catch.
    func usageSummary(userID: String, monthStart: Date, monthEnd: Date) async throws -> QuotaPolicy.UsageSummary
}

/// The production `ServerUsageQuerying`, built directly on `URLSession`
/// rather than any RevenueCat or Supabase SDK type.
public struct PostgRESTUsageQuery: ServerUsageQuerying {
    private let config: BackendConfig
    private let tokenProvider: any AccessTokenProvider
    private let session: URLSession

    public init(config: BackendConfig, tokenProvider: any AccessTokenProvider, session: URLSession = .shared) {
        self.config = config
        self.tokenProvider = tokenProvider
        self.session = session
    }

    public func usageSummary(userID: String, monthStart: Date, monthEnd: Date) async throws -> QuotaPolicy.UsageSummary {
        async let totalTask = count(filters: [
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
        ])
        async let monthTask = count(filters: [
            URLQueryItem(name: "user_id", value: "eq.\(userID)"),
            URLQueryItem(name: "processed_at", value: "gte.\(ReloraTimestamp.from(monthStart))"),
            URLQueryItem(name: "processed_at", value: "lt.\(ReloraTimestamp.from(monthEnd))"),
        ])
        let (total, month) = try await (totalTask, monthTask)
        return QuotaPolicy.UsageSummary(totalProcessedNotes: total, processedNotesThisMonth: month)
    }

    /// One `HEAD .../voice_note_usage_events?select=*&<filters>` request,
    /// reading the total row count back out of `Content-Range: */N`.
    /// Mirrors postgrest-js's `{ count: 'exact', head: true }`: `exact`
    /// asks PostgREST to compute a precise count rather than an estimate,
    /// `head` asks for no response body, just the header.
    private func count(filters: [URLQueryItem]) async throws -> Int {
        guard let token = try await tokenProvider.accessToken() else {
            throw BackendError(code: BackendError.authRequired, message: "No active session.", httpStatus: 401)
        }
        guard var components = URLComponents(
            url: config.supabaseURL.appendingPathComponent("rest/v1/voice_note_usage_events"),
            resolvingAgainstBaseURL: false
        ) else {
            throw BackendError(code: BackendError.invalidResponse, message: "Could not build the usage-query URL.", httpStatus: 0)
        }
        components.setStrictlyEncodedQueryItems([URLQueryItem(name: "select", value: "*")] + filters)
        guard let url = components.url else {
            throw BackendError(code: BackendError.invalidResponse, message: "Could not build the usage-query URL.", httpStatus: 0)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("count=exact", forHTTPHeaderField: "Prefer")

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw BackendError(code: BackendError.networkError, message: String(describing: error), httpStatus: 0)
        }

        guard let http = response as? HTTPURLResponse else {
            throw BackendError(code: BackendError.invalidResponse, message: "Non-HTTP response from the usage query.", httpStatus: 0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BackendError(
                code: "HTTP_\(http.statusCode)",
                message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                httpStatus: http.statusCode
            )
        }
        guard
            let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
            let totalString = contentRange.split(separator: "/").last,
            let total = Int(totalString)
        else {
            throw BackendError(
                code: BackendError.invalidResponse,
                message: "Missing or unparseable Content-Range header on a usage-count response.",
                httpStatus: http.statusCode
            )
        }
        return total
    }
}
