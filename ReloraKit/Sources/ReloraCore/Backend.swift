import Foundation

/// Supabase project connection details shared by every network client in
/// ReloraKit. Mirrors `supabaseUrl` / `supabasePublishableKey` in
/// apps/mobile/src/supabase/client.ts.
public struct BackendConfig: Sendable {
    public var supabaseURL: URL
    public var anonKey: String

    public init(supabaseURL: URL, anonKey: String) {
        self.supabaseURL = supabaseURL
        self.anonKey = anonKey
    }
}

/// Supplies the current session's access token for authenticated requests.
/// `nil` means no active session, mirroring the `session?.access_token`
/// check in apps/mobile/src/features/voice/voiceFunctionClient.ts
/// (`getAuthenticatedVoiceFunctionHeaders`), which throws `AUTH_REQUIRED`
/// when there is no session rather than falling back to an anon-only call.
public protocol AccessTokenProvider: Sendable {
    func accessToken() async throws -> String?
}

/// A backend failure. Callers built on `PostgRESTLite` or `EdgeFunctions`
/// only ever see this type, whether the failure came from a decoded
/// `{ error, code }` response, a decoded PostgREST error body, an HTTP
/// status with no decodable body, or was synthesized client-side (no
/// session, transport failure, timeout).
public struct BackendError: Error, Sendable, Equatable {
    public var code: String
    public var message: String
    public var httpStatus: Int

    public init(code: String, message: String, httpStatus: Int) {
        self.code = code
        self.message = message
        self.httpStatus = httpStatus
    }
}

// MARK: - Well-known codes

/// Stable error codes this backend is known to return, gathered from the
/// server-side sources so callers can switch on them without hardcoding
/// string literals. Grouped by the source module each was lifted from.
extension BackendError {
    // apps/api/supabase/functions/_shared/auth.ts (`authenticateRequest`).
    // Every edge function endpoint can return these.
    public static let authRequired = "AUTH_REQUIRED"
    public static let authFailed = "AUTH_FAILED"
    public static let missingEnv = "MISSING_ENV"

    // apps/api/src/transcription/transcriptionErrors.ts
    // (`StableTranscriptionFunctionErrorCode`) — transcribeAudio.
    public static let audioTooLong = "AUDIO_TOO_LONG"
    public static let billingVerificationUnavailable = "BILLING_VERIFICATION_UNAVAILABLE"
    public static let freeLimitReached = "FREE_LIMIT_REACHED"
    public static let idempotencyConflict = "IDEMPOTENCY_CONFLICT"
    public static let invalidInput = "INVALID_INPUT"
    public static let missingAudioFile = "MISSING_AUDIO_FILE"
    public static let missingIdempotencyKey = "MISSING_IDEMPOTENCY_KEY"
    public static let plusQuotaReached = "PLUS_QUOTA_REACHED"
    public static let payloadTooLarge = "PAYLOAD_TOO_LARGE"
    public static let transcribeEmpty = "TRANSCRIBE_EMPTY"
    public static let transcribeFailed = "TRANSCRIBE_FAILED"
    public static let transcribeInProgress = "TRANSCRIBE_IN_PROGRESS"
    public static let transcribeProviderAuth = "TRANSCRIBE_PROVIDER_AUTH"
    public static let transcribeRateLimited = "TRANSCRIBE_RATE_LIMITED"
    public static let transcribeTimeout = "TRANSCRIBE_TIMEOUT"
    public static let transcribeUpstreamUnavailable = "TRANSCRIBE_UPSTREAM_UNAVAILABLE"
    public static let unsupportedMime = "UNSUPPORTED_MIME"

    // apps/api/src/extraction/extractionErrors.ts
    // (`StableExtractionFunctionErrorCode`) — extractFromTranscript.
    // `invalidInput` above is shared verbatim with transcription.
    public static let extractEmpty = "EXTRACT_EMPTY"
    public static let extractFailed = "EXTRACT_FAILED"
    public static let extractProviderAuth = "EXTRACT_PROVIDER_AUTH"
    public static let extractRateLimited = "EXTRACT_RATE_LIMITED"
    public static let extractTimeout = "EXTRACT_TIMEOUT"
    public static let extractUpstreamUnavailable = "EXTRACT_UPSTREAM_UNAVAILABLE"
    public static let transcriptionRequestNotFound = "TRANSCRIPTION_REQUEST_NOT_FOUND"
    public static let transcriptionRequestNotReady = "TRANSCRIPTION_REQUEST_NOT_READY"

    // create_realtime_transcription_session/index.ts
    public static let realtimeSessionFailed = "OPENAI_REALTIME_SESSION_FAILED"
    /// 429 from the mint endpoint: too many realtime sessions in too
    /// short a window. Unlike the quota codes above this one clears on
    /// its own, so the copy says to wait rather than to upgrade.
    public static let realtimeRateLimited = "REALTIME_RATE_LIMITED"

    // delete_account_data/index.ts
    public static let deleteAccountFailed = "DELETE_ACCOUNT_FAILED"

    // Client-only: apps/mobile/src/features/voice/extractionService.ts and
    // realtime/realtimeTranscriptionClient.ts raise these locally, before
    // (or instead of) any HTTP response — a bad local file, or the fetch
    // itself throwing. Kept distinct per call site to match RN's mapping.
    public static let localAudioReadFailed = "LOCAL_AUDIO_READ_FAILED"
    public static let transcribeUploadFailed = "TRANSCRIBE_UPLOAD_FAILED"
    public static let realtimeSessionMintFailed = "REALTIME_SESSION_MINT_FAILED"

    // Client-only, second group: raised by the capture layer rather than by
    // a transcription call. Both are named in RN's
    // `voiceCaptureErrorMapping.ts` switch but had no constant here, so M6
    // added them rather than writing the literals inline at the one place
    // that needs them — see docs/milestone-notes.md, "Error-code catalog
    // reconciliation". `recordPermissionDenied` is what M6 maps
    // `RecordingControllerError.permissionDenied` onto;
    // `realtimeTranscriptTimeout` is M7's (the realtime session ending with
    // no usable transcript) and is carried here now so M7 finds a constant
    // instead of forking a string.
    public static let recordPermissionDenied = "RECORD_PERMISSION_DENIED"
    public static let realtimeTranscriptTimeout = "REALTIME_TRANSCRIPT_TIMEOUT"
    // M7: `RealtimeTranscriber.handleReceiveFailure` carried this as an
    // inline literal — moved here per docs/milestone-notes.md, "Error-code
    // catalog reconciliation (M7)". One catalog, no string forks.
    public static let realtimeConnectionFailed = "REALTIME_CONNECTION_FAILED"

    // ReloraKit-only: no RN counterpart, synthesized by PostgRESTLite /
    // EdgeFunctions for failures the RN client never needed a code for.
    public static let networkError = "NETWORK_ERROR"
    public static let invalidResponse = "INVALID_RESPONSE"
    public static let disallowedTable = "DISALLOWED_TABLE"
}

// MARK: - Envelope decoding

extension BackendError {
    /// Decodes a non-2xx edge-function response body into `BackendError`.
    ///
    /// Every function under apps/api/supabase/functions returns the same
    /// flat shape on failure — `{ error: string, code: string }` — built
    /// by `jsonResponse(payload, status)` in `_shared/response.ts` and
    /// populated from each function's own error module (e.g.
    /// `transcribe_audio/index.ts`'s `jsonResponse({ error: '...', code:
    /// errorCode }, status)`). There is no nested `{ error: { code,
    /// message } }` form anywhere in the API — only this flat one.
    ///
    /// Falls back to a status-only error when the body is empty or does
    /// not match (a 5xx from something other than the function runtime,
    /// e.g. an infrastructure-level error page).
    public static func fromEdgeFunctionBody(_ data: Data, httpStatus: Int) -> BackendError {
        struct Envelope: Decodable {
            let error: String
            let code: String
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            return BackendError(code: envelope.code, message: envelope.error, httpStatus: httpStatus)
        }
        return BackendError(
            code: "HTTP_\(httpStatus)",
            message: HTTPURLResponse.localizedString(forStatusCode: httpStatus),
            httpStatus: httpStatus
        )
    }
}
