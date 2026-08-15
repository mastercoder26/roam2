import Foundation

struct AuthUser: Codable, Equatable, Sendable {
    let id: String
    let email: String
    let displayName: String?
}

enum AuthErrorCode: String, Codable, Equatable, Sendable {
    case validationError = "VALIDATION_ERROR"
    case unauthorized = "UNAUTHORIZED"
    case rateLimited = "RATE_LIMITED"
    case serviceUnavailable = "SERVICE_UNAVAILABLE"
    case internalError = "INTERNAL_ERROR"
}

enum AuthError: LocalizedError, Equatable, Sendable {
    case backend(code: AuthErrorCode, message: String, requestID: String?, retryAfter: Int?)
    case validation(message: String)
    case unauthorized(message: String)
    case rateLimited(message: String, retryAfter: Int?)
    case serviceUnavailable(message: String)
    case internalError(message: String)
    case offline
    case serverUnavailable
    case invalidResponse
    case decodingError

    var code: AuthErrorCode? {
        switch self {
        case let .backend(code, _, _, _): code
        case .validation: .validationError
        case .unauthorized: .unauthorized
        case .rateLimited: .rateLimited
        case .serviceUnavailable: .serviceUnavailable
        case .internalError: .internalError
        case .offline, .serverUnavailable, .invalidResponse, .decodingError: nil
        }
    }

    var errorDescription: String? {
        switch self {
        case let .backend(code, message, _, retryAfter):
            if code == .rateLimited, let retryAfter {
                return retryMessage(retryAfter: retryAfter)
            }
            return message
        case let .validation(message), let .unauthorized(message), let .serviceUnavailable(message), let .internalError(message):
            return message
        case let .rateLimited(message, retryAfter):
            return retryAfter.map { retryMessage(retryAfter: $0) } ?? message
        case .offline:
            return "Working offline. Check your connection and try again when you are back online."
        case .serverUnavailable:
            return "Roam is having trouble right now. Try again soon."
        case .invalidResponse, .decodingError:
            return "Roam could not read the server response. Try again soon."
        }
    }

    var isTransient: Bool {
        switch self {
        case let .backend(code, _, _, _): [.rateLimited, .serviceUnavailable].contains(code)
        case .offline, .serverUnavailable, .serviceUnavailable, .rateLimited: true
        default: false
        }
    }

    static func from(statusCode: Int, data: Data, retryAfter: Int? = nil) -> AuthError {
        struct ErrorEnvelope: Decodable {
            let error: String?
            let code: AuthErrorCode?
            let requestId: String?
        }

        let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        let message = envelope?.error?.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeMessage = message.flatMap { $0.isEmpty ? nil : $0 }
        let code = envelope?.code ?? fallbackCode(for: statusCode)
        return .backend(
            code: code,
            message: safeMessage ?? defaultMessage(for: code),
            requestID: envelope?.requestId,
            retryAfter: retryAfter
        )
    }

    private static func fallbackCode(for statusCode: Int) -> AuthErrorCode {
        switch statusCode {
        case 400: .validationError
        case 401: .unauthorized
        case 429: .rateLimited
        case 503: .serviceUnavailable
        default: .internalError
        }
    }

    private static func defaultMessage(for code: AuthErrorCode) -> String {
        switch code {
        case .validationError: "Check the details and try again."
        case .unauthorized: "Your Clerk session is not authorized for Roam."
        case .rateLimited: "Too many attempts. Try again soon."
        case .serviceUnavailable: "Roam is unavailable right now. Try again soon."
        case .internalError: "Something went wrong on Roam's side. Try again soon."
        }
    }

    private func retryMessage(retryAfter: Int) -> String {
        let minutes = max(1, Int(ceil(Double(retryAfter) / 60)))
        return "Too many attempts. Try again in about \(minutes) \(minutes == 1 ? "minute" : "minutes")."
    }
}

enum HealthStatus: String, Codable, Equatable, Sendable {
    case ok
    case degraded
}

enum DatabaseStatus: String, Codable, Equatable, Sendable {
    case up
    case down
    case unconfigured
}

struct HealthResponse: Codable, Equatable, Sendable {
    let status: HealthStatus
    let database: DatabaseStatus
    let version: String
}

enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct RemoteProfile: Codable, Equatable, Sendable {
    let displayName: String
    let stage: DriverProfile.Stage
    let payload: [String: JSONValue]
    let updatedAt: Date

    init(displayName: String, stage: DriverProfile.Stage, payload: [String: JSONValue], updatedAt: Date) {
        self.displayName = displayName
        self.stage = stage
        self.payload = payload
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case displayName, stage, payload, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        // Profiles created before the driver chooses a stage are returned by
        // the data API with a null stage. The local profile model has always
        // treated a new driver as being at the permit stage, so preserve that
        // default instead of turning an otherwise valid profile response into
        // a decoding failure.
        stage = try container.decodeIfPresent(DriverProfile.Stage.self, forKey: .stage) ?? .permit
        payload = try container.decodeIfPresent([String: JSONValue].self, forKey: .payload) ?? [:]
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

struct ClerkBackendClient: Sendable {
    private let apiClient: APIClient

    init(
        candidateBaseURLs: [URL] = AppConfiguration.candidateBaseURLs,
        dataCandidateBaseURLs: [URL] = AppConfiguration.dataCandidateBaseURLs,
        session: URLSession = .shared
    ) {
        apiClient = APIClient(
            candidateBaseURLs: candidateBaseURLs,
            dataCandidateBaseURLs: dataCandidateBaseURLs,
            session: session
        )
    }

    func currentUser(accessToken: String) async throws -> AuthUser {
        let response: MeResponse = try await request(path: "api/auth/me", method: "GET", accessToken: accessToken)
        return response.user
    }

    func profile(accessToken: String) async throws -> RemoteProfile {
        let response: ProfileResponse = try await request(path: "api/profile", method: "GET", accessToken: accessToken)
        return response.profile
    }

    func updateProfile(accessToken: String, displayName: String?, stage: DriverProfile.Stage?, payload: [String: JSONValue]?) async throws -> RemoteProfile {
        let body = ProfileUpdateRequest(displayName: displayName, stage: stage, payload: payload)
        let response: ProfileResponse = try await request(path: "api/profile", method: "PUT", body: body, accessToken: accessToken)
        return response.profile
    }

    func deleteAccount(accessToken: String) async throws {
        try await requestNoContent(path: "api/account", method: "DELETE", body: Optional<EmptyBody>.none, accessToken: accessToken)
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body? = nil,
        accessToken: String? = nil
    ) async throws -> Response {
        let encodedBody = try body.map { try APIClient.makeDateEncoder().encode($0) }
        let response = try await send(path: path, method: method, body: encodedBody, accessToken: accessToken)
        guard (200...299).contains(response.response.statusCode) else {
            throw Self.authError(from: response)
        }
        do {
            return try APIClient.makeDateDecoder().decode(Response.self, from: response.data)
        } catch {
            throw AuthError.decodingError
        }
    }

    private func request<Response: Decodable>(path: String, method: String, accessToken: String? = nil) async throws -> Response {
        try await request(path: path, method: method, body: Optional<EmptyBody>.none, accessToken: accessToken)
    }

    private func requestNoContent<Body: Encodable>(path: String, method: String, body: Body? = nil, accessToken: String? = nil) async throws {
        let encodedBody = try body.map { try APIClient.makeDateEncoder().encode($0) }
        let response = try await send(path: path, method: method, body: encodedBody, accessToken: accessToken)
        guard (200...299).contains(response.response.statusCode) else {
            throw Self.authError(from: response)
        }
    }

    private func send(path: String, method: String, body: Data?, accessToken: String?) async throws -> APIClient.HTTPResponseData {
        var headers = ["Content-Type": "application/json"]
        if let accessToken {
            headers["Authorization"] = "Bearer " + accessToken
        }
        do {
            return try await apiClient.requestData(
                path: path,
                method: method,
                body: body,
                headers: headers,
                host: .data
            )
        } catch APIError.networkError {
            throw AuthError.offline
        } catch APIError.invalidResponse, APIError.invalidURL {
            throw AuthError.serverUnavailable
        } catch {
            throw AuthError.serverUnavailable
        }
    }

    private static func authError(from response: APIClient.HTTPResponseData) -> AuthError {
        let retryAfter = response.response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
        return AuthError.from(statusCode: response.response.statusCode, data: response.data, retryAfter: retryAfter)
    }
}

private struct ProfileUpdateRequest: Encodable {
    let displayName: String?
    let stage: DriverProfile.Stage?
    let payload: [String: JSONValue]?

    private enum CodingKeys: String, CodingKey { case displayName, stage, payload }
}

private struct EmptyBody: Encodable {}
private struct MeResponse: Decodable { let user: AuthUser }
private struct ProfileResponse: Decodable { let profile: RemoteProfile }
