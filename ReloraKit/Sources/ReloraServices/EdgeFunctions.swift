import Foundation
import ReloraCore

/// Result of `EdgeFunctionsClient.transcribeAudio`. Mirrors the success
/// body of `transcribe_audio/index.ts`'s `jsonResponse({ transcript,
/// request_id, provider_request_id, deduped })`.
public struct TranscribeResult: Sendable, Equatable {
    public var transcript: String
    public var requestID: String
    public var deduped: Bool

    public init(transcript: String, requestID: String, deduped: Bool) {
        self.transcript = transcript
        self.requestID = requestID
        self.deduped = deduped
    }
}

/// Result of `EdgeFunctionsClient.createRealtimeTranscriptionSession`.
/// Mirrors `create_realtime_transcription_session/index.ts`'s
/// `jsonResponse({ client_secret, mode, session_id })`.
public struct RealtimeSessionInfo: Sendable, Equatable {
    public var clientSecretValue: String
    /// `client_secret.expires_at` from OpenAI's realtime session API is a
    /// Unix epoch in seconds. Nothing reads it yet, and a server that
    /// sends a bare secret string sends no expiry, so it is optional.
    public var expiresAt: Date?
    public var mode: String
    /// The row the server opened for this session. `extract_from_transcript`
    /// takes it in place of an audio upload, which is what keeps a realtime
    /// capture from paying for a second, metered trip through
    /// `transcribe_audio`. `nil` from a server that predates it — the
    /// caller then falls back to that upload.
    public var sessionID: String?

    public init(clientSecretValue: String, expiresAt: Date?, mode: String, sessionID: String? = nil) {
        self.clientSecretValue = clientSecretValue
        self.expiresAt = expiresAt
        self.mode = mode
        self.sessionID = sessionID
    }
}

/// `client_secret` as either shape the server has sent it in: OpenAI's
/// own `{ value, expires_at }` object, and a bare secret string. Reading
/// both means this client can ship before or after the server does, which
/// matters because a mismatch takes realtime transcription out entirely.
private struct ClientSecret: Decodable {
    let value: String
    let expiresAt: Date?

    private struct Object: Decodable {
        let value: String
        let expires_at: Double?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flat = try? container.decode(String.self) {
            value = flat
            expiresAt = nil
            return
        }
        let object = try container.decode(Object.self)
        value = object.value
        expiresAt = object.expires_at.map(Date.init(timeIntervalSince1970:))
    }
}

/// One progress checkpoint a slow edge-function call reports through.
/// Mirrors the `setTimeout(..., 15_000)` / `setTimeout(..., 30_000)` pair
/// in apps/mobile/src/features/voice/voiceCaptureFlow.ts.
public struct EdgeFunctionsProgressMark: Sendable {
    public var after: Duration
    public var seconds: Int

    public init(after: Duration, seconds: Int) {
        self.after = after
        self.seconds = seconds
    }

    public static let fifteenSeconds = EdgeFunctionsProgressMark(after: .seconds(15), seconds: 15)
    public static let thirtySeconds = EdgeFunctionsProgressMark(after: .seconds(30), seconds: 30)
}

/// Client for the four Supabase Edge Functions under
/// `{supabaseURL}/functions/v1/`. Every call carries `apikey` and
/// `Authorization: Bearer <token>` — the same headers
/// `getAuthenticatedVoiceFunctionHeaders()` builds in
/// apps/mobile/src/features/voice/voiceFunctionClient.ts, including its
/// `AUTH_REQUIRED` throw when there is no session, before any request is
/// sent.
///
/// ## Timeout and progress scope
///
/// `voiceCaptureFlow.ts` enforces a single 60s budget shared across the
/// transcribe *and* extract calls together, firing one pair of 15s/30s
/// progress callbacks for the whole two-call flow, and picks
/// `TRANSCRIBE_TIMEOUT` vs. `EXTRACT_TIMEOUT` based on which stage was
/// in flight when the shared budget ran out. That orchestration is
/// `voiceCaptureFlow.ts` itself, not this client — porting it is the
/// later milestone this task explicitly excluded.
///
/// What this client provides instead is the reusable per-call primitive:
/// every method here enforces its own budget (default 60s, matching the
/// RN constant) and fires its own 15s/30s progress marks, timing out with
/// the code appropriate to *that* call (`transcribeAudio` →
/// `TRANSCRIBE_TIMEOUT`, `extractFromTranscript` → `EXTRACT_TIMEOUT`).
/// Composing one shared clock across two calls — e.g. by passing a
/// shorter `timeoutBudget` into the second call once the first has spent
/// part of the 60s — is left to whatever ports `voiceCaptureFlow.ts`.
public final class EdgeFunctionsClient: Sendable {
    private let config: BackendConfig
    private let tokenProvider: AccessTokenProvider
    private let session: URLSession
    private let timeoutBudget: Duration
    private let progressMarks: [EdgeFunctionsProgressMark]

    public init(
        config: BackendConfig,
        tokenProvider: AccessTokenProvider,
        session: URLSession = .shared,
        timeoutBudget: Duration = .seconds(60),
        progressMarks: [EdgeFunctionsProgressMark] = [.fifteenSeconds, .thirtySeconds]
    ) {
        self.config = config
        self.tokenProvider = tokenProvider
        self.session = session
        self.timeoutBudget = timeoutBudget
        self.progressMarks = progressMarks
    }

    // MARK: - transcribe_audio

    /// Uploads local audio as `multipart/form-data` and returns its
    /// transcript. Field names (`audio_file`, `idempotency_key`,
    /// `mime_type`, `duration_ms`) match
    /// apps/mobile/src/features/voice/extractionService.ts's
    /// `transcribeAudio`, including its pre-flight checks (unsupported
    /// mime, oversized payload, overlong recording) that run before any
    /// request is sent — ported here from `@relora/shared`'s
    /// `resolveSupportedAudioUpload` / `MAX_AUDIO_UPLOAD_BYTES` /
    /// `MAX_RECORDING_DURATION_MS` via `AudioFormats`.
    ///
    /// Reads the whole file into memory rather than streaming: the
    /// pre-flight size check caps it at `AudioFormats.maxAudioUploadBytes`
    /// (~25 MiB), small enough that streaming would add complexity for no
    /// real benefit.
    public func transcribeAudio(
        fileURL: URL,
        mimeType: String,
        durationMS: Int,
        idempotencyKey: String,
        onSlowProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> TranscribeResult {
        guard let fileData = try? Data(contentsOf: fileURL), !fileData.isEmpty else {
            throw BackendError(code: BackendError.localAudioReadFailed, message: "Could not read local audio file", httpStatus: 0)
        }
        guard let normalized = AudioFormats.resolveSupportedUpload(fileName: fileURL.lastPathComponent, mimeType: mimeType) else {
            throw BackendError(code: BackendError.unsupportedMime, message: "Unsupported audio mime type", httpStatus: 0)
        }
        guard fileData.count <= AudioFormats.maxAudioUploadBytes else {
            throw BackendError(code: BackendError.payloadTooLarge, message: "Audio file exceeds upload limit", httpStatus: 0)
        }
        guard durationMS <= AudioFormats.maxRecordingDurationMs else {
            throw BackendError(code: BackendError.audioTooLong, message: "Recording exceeds maximum duration", httpStatus: 0)
        }

        let boundary = "ReloraKit-\(UUID().uuidString)"
        let body = Self.buildTranscribeMultipartBody(
            boundary: boundary,
            fileData: fileData,
            fileName: normalized.fileName,
            mimeType: normalized.mimeType,
            idempotencyKey: idempotencyKey,
            durationMS: durationMS
        )

        return try await withTimeout(stageTimeoutCode: BackendError.transcribeTimeout, onSlowProgress: onSlowProgress) { [self] in
            var request = try await buildRequest(functionName: "transcribe_audio", method: "POST")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = body

            let (data, response) = try await Self.performRequest(
                session: session,
                request: request,
                timeoutCode: BackendError.transcribeTimeout,
                transportErrorCode: BackendError.transcribeUploadFailed
            )
            try Self.throwIfEdgeFunctionError(data: data, response: response)

            struct SuccessBody: Decodable {
                let transcript: String
                let request_id: String
                let deduped: Bool
            }
            guard let decoded = try? JSONDecoder().decode(SuccessBody.self, from: data) else {
                throw BackendError(
                    code: BackendError.invalidResponse,
                    message: "Could not decode transcribe_audio response",
                    httpStatus: (response as? HTTPURLResponse)?.statusCode ?? 0
                )
            }
            return TranscribeResult(transcript: decoded.transcript, requestID: decoded.request_id, deduped: decoded.deduped)
        }
    }

    private static func buildTranscribeMultipartBody(
        boundary: String,
        fileData: Data,
        fileName: String,
        mimeType: String,
        idempotencyKey: String,
        durationMS: Int
    ) -> Data {
        var body = Data()

        func appendString(_ string: String) {
            body.append(string.data(using: .utf8)!)
        }
        func appendField(name: String, value: String) {
            appendString("--\(boundary)\r\n")
            appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            appendString("\(value)\r\n")
        }

        // Field order mirrors extractionService.ts's FormData.append calls:
        // audio_file, idempotency_key, mime_type, duration_ms.
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"audio_file\"; filename=\"\(fileName)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        appendString("\r\n")

        appendField(name: "idempotency_key", value: idempotencyKey)
        appendField(name: "mime_type", value: mimeType)
        appendField(name: "duration_ms", value: String(durationMS))

        appendString("--\(boundary)--\r\n")
        return body
    }

    // MARK: - extract_from_transcript

    /// Sends transcript text to the extraction function. `timeZone` is
    /// omitted from the request body when `nil` or empty, matching `if
    /// (timeZone) body[EXTRACTION_TIME_ZONE_FIELD] = timeZone` in
    /// extractionService.ts — the server keeps its own clock; this only
    /// says which zone to read relative dates in.
    ///
    /// `realtimeSessionID` names the session a realtime capture already
    /// paid for, so the server can bill this transcript against that row
    /// instead of asking for the audio again. Omitted from the body when
    /// `nil`, same as `time_zone`. The server rejects an id that is not
    /// the caller's, or is over an hour old, with
    /// `TRANSCRIPTION_REQUEST_NOT_FOUND`.
    public func extractFromTranscript(
        transcript: String,
        timeZone: String?,
        realtimeSessionID: String? = nil,
        onSlowProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> ExtractionPayload {
        struct RequestBody: Encodable {
            let transcript: String
            let time_zone: String?
            let realtime_session_id: String?
        }
        let normalizedTimeZone = (timeZone?.isEmpty == false) ? timeZone : nil
        let normalizedSessionID = (realtimeSessionID?.isEmpty == false) ? realtimeSessionID : nil
        let payload = try JSONEncoder().encode(RequestBody(
            transcript: transcript,
            time_zone: normalizedTimeZone,
            realtime_session_id: normalizedSessionID
        ))

        return try await withTimeout(stageTimeoutCode: BackendError.extractTimeout, onSlowProgress: onSlowProgress) { [self] in
            var request = try await buildRequest(functionName: "extract_from_transcript", method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = payload

            let (data, response) = try await Self.performRequest(
                session: session,
                request: request,
                timeoutCode: BackendError.extractTimeout,
                transportErrorCode: BackendError.extractFailed
            )
            try Self.throwIfEdgeFunctionError(data: data, response: response)

            guard let decoded = try? JSONDecoder().decode(ExtractionPayload.self, from: data) else {
                throw BackendError(
                    code: BackendError.invalidResponse,
                    message: "Could not decode extract_from_transcript response",
                    httpStatus: (response as? HTTPURLResponse)?.statusCode ?? 0
                )
            }
            return decoded
        }
    }

    // MARK: - create_realtime_transcription_session

    /// Mints a short-lived OpenAI realtime client secret. RN's
    /// `mintRealtimeClientSecret` (realtimeTranscriptionClient.ts) has no
    /// distinct timeout path — every fetch failure, timeout included,
    /// becomes `REALTIME_SESSION_MINT_FAILED` — so this call does the
    /// same rather than inventing a `REALTIME_TIMEOUT` code with no RN or
    /// server counterpart.
    public func createRealtimeTranscriptionSession(
        onSlowProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> RealtimeSessionInfo {
        try await withTimeout(stageTimeoutCode: BackendError.realtimeSessionMintFailed, onSlowProgress: onSlowProgress) { [self] in
            var request = try await buildRequest(functionName: "create_realtime_transcription_session", method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode([String: String]())

            let (data, response) = try await Self.performRequest(
                session: session,
                request: request,
                timeoutCode: BackendError.realtimeSessionMintFailed,
                transportErrorCode: BackendError.realtimeSessionMintFailed
            )
            try Self.throwIfEdgeFunctionError(data: data, response: response)

            struct SuccessBody: Decodable {
                let client_secret: ClientSecret
                let mode: String
                /// Optional so a server that has not shipped the id yet
                /// still mints a usable session.
                let session_id: String?
            }
            guard let decoded = try? JSONDecoder().decode(SuccessBody.self, from: data) else {
                throw BackendError(
                    code: BackendError.invalidResponse,
                    message: "Could not decode create_realtime_transcription_session response",
                    httpStatus: (response as? HTTPURLResponse)?.statusCode ?? 0
                )
            }
            return RealtimeSessionInfo(
                clientSecretValue: decoded.client_secret.value,
                expiresAt: decoded.client_secret.expiresAt,
                mode: decoded.mode,
                sessionID: decoded.session_id
            )
        }
    }

    // MARK: - delete_account_data

    /// Deletes the authenticated user's account data. RN's caller
    /// (apps/mobile/src/features/settings/dataControls.ts) goes through
    /// `supabase.functions.invoke` and never inspects a stable error
    /// code, so there is no RN-parity code to mirror for a transport
    /// failure here — `BackendError.networkError` is used for both the
    /// timeout and transport-failure path.
    public func deleteAccountData(
        onSlowProgress: (@Sendable (Int) -> Void)? = nil
    ) async throws {
        try await withTimeout(stageTimeoutCode: BackendError.networkError, onSlowProgress: onSlowProgress) { [self] in
            var request = try await buildRequest(functionName: "delete_account_data", method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode([String: String]())

            let (data, response) = try await Self.performRequest(
                session: session,
                request: request,
                timeoutCode: BackendError.networkError,
                transportErrorCode: BackendError.networkError
            )
            try Self.throwIfEdgeFunctionError(data: data, response: response)
        }
    }

    // MARK: - Request plumbing

    private func buildRequest(functionName: String, method: String) async throws -> URLRequest {
        let url = config.supabaseURL.appendingPathComponent("functions/v1/\(functionName)")
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        guard let token = try await tokenProvider.accessToken() else {
            throw BackendError(code: BackendError.authRequired, message: "No active session", httpStatus: 401)
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func performRequest(
        session: URLSession,
        request: URLRequest,
        timeoutCode: String,
        transportErrorCode: String
    ) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw BackendError(code: timeoutCode, message: urlError.localizedDescription, httpStatus: 504)
        } catch let urlError as URLError {
            throw BackendError(code: transportErrorCode, message: urlError.localizedDescription, httpStatus: 0)
        }
    }

    private static func throwIfEdgeFunctionError(data: Data, response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendError(code: BackendError.networkError, message: "No HTTP response", httpStatus: 0)
        }
        guard !(200...299).contains(httpResponse.statusCode) else { return }
        throw BackendError.fromEdgeFunctionBody(data, httpStatus: httpResponse.statusCode)
    }

    /// Races `operation` against `timeoutBudget`, firing `onSlowProgress`
    /// at each configured mark along the way. Mirrors the shape of
    /// `withTimeout` / the progress `setTimeout` pair in
    /// voiceCaptureFlow.ts, scoped to a single call — see the type-level
    /// doc comment for why it stops there.
    private func withTimeout<T: Sendable>(
        stageTimeoutCode: String,
        onSlowProgress: (@Sendable (Int) -> Void)?,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask { [timeoutBudget] in
                try await Task.sleep(for: timeoutBudget)
                throw BackendError(code: stageTimeoutCode, message: "Request exceeded its time budget", httpStatus: 504)
            }
            if let onSlowProgress {
                for mark in progressMarks {
                    group.addTask {
                        try? await Task.sleep(for: mark.after)
                        if !Task.isCancelled {
                            onSlowProgress(mark.seconds)
                        }
                        return nil
                    }
                }
            }

            defer { group.cancelAll() }
            while let outcome = try await group.next() {
                if let value = outcome {
                    return value
                }
            }
            // Unreachable: the operation task always resolves to a value
            // (returned or thrown) before the group runs dry, since the
            // timeout task guarantees the group never drains on its own.
            throw BackendError(code: stageTimeoutCode, message: "Request did not complete", httpStatus: 504)
        }
    }
}
