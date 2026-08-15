import Foundation
import os

private let apiLogger = Logger(subsystem: "com.akhilkonduru.roam", category: "APIClient")

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int, message: String?)
    case decodingError(Error)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API URL configuration."
        case .invalidResponse:
            return "Unexpected server response."
        case .httpError(let code, let message):
            if let message, !message.isEmpty {
                return "Server error (\(code)): \(message)"
            }
            return "Server error (\(code))."
        case .decodingError:
            return "Could not read route data from the server."
        case .networkError(let error):
            return error.localizedDescription
        }
    }
}

struct APIClient {
    enum Host {
        case route
        case data
    }

    /// The whole attempt, across every candidate host, is bounded by this.
    /// It used to apply per candidate, so a weak connection could spend a full
    /// minute per host with no way to cancel.
    static let totalRequestBudget: TimeInterval = 45
    /// Below this much remaining budget, starting another candidate would only
    /// produce a second timeout, so the attempt ends instead.
    static let minimumCandidateTimeout: TimeInterval = 8
    /// The longest a single candidate may hold the budget, so a first host
    /// that never answers still leaves room for the next one.
    static let maximumCandidateTimeout: TimeInterval = 25

    struct HTTPResponseData {
        let data: Data
        let response: HTTPURLResponse
    }

    /// Route analysis and authenticated data calls each keep their own ordered
    /// candidates. Failover never crosses from one backend's host set to the
    /// other.
    private let routeCandidateBaseURLs: [URL]
    private let dataCandidateBaseURLs: [URL]
    private let session: URLSession

    init(
        candidateBaseURLs: [URL] = AppConfiguration.candidateBaseURLs,
        dataCandidateBaseURLs: [URL] = AppConfiguration.dataCandidateBaseURLs,
        session: URLSession = .shared
    ) {
        self.routeCandidateBaseURLs = candidateBaseURLs
        self.dataCandidateBaseURLs = dataCandidateBaseURLs
        self.session = session
    }

    /// The backend uses ISO-8601 strings with fractional seconds for all
    /// persisted dates. Keep one encoder/decoder pair for every service that
    /// sends or receives those values.
    static func makeDateEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    static func makeDateDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) {
                return date
            }

            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            guard let date = standard.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid server date"
                )
            }
            return date
        }
        return decoder
    }

    /// Shared raw transport for services that need their own typed error
    /// envelope. It deliberately uses the same candidate ordering and one
    /// total budget as route analysis.
    func requestData(
        path: String,
        method: String,
        body: Data? = nil,
        headers: [String: String] = [:],
        host: Host = .data
    ) async throws -> HTTPResponseData {
        let candidates = candidateBaseURLs(for: host)
        guard !candidates.isEmpty else { throw APIError.invalidURL }

        var lastNetworkError: Error = URLError(.cannotConnectToHost)
        let deadline = Date().addingTimeInterval(Self.totalRequestBudget)

        for baseURL in candidates {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining >= Self.minimumCandidateTimeout else { break }

            do {
                return try await requestData(
                    to: baseURL,
                    path: path,
                    method: method,
                    body: body,
                    headers: headers,
                    timeout: min(remaining, Self.maximumCandidateTimeout)
                )
            } catch APIError.networkError(let error) {
                lastNetworkError = error
                guard Self.shouldTryNextCandidate(after: error) else {
                    throw APIError.networkError(error)
                }
            }
        }

        throw APIError.networkError(lastNetworkError)
    }

    /// `accessToken` is required: route analysis proxies metered upstream APIs
    /// and the backend rejects anonymous callers.
    func analyzeRoute(
        origin: String,
        destination: String,
        departureTime: Date,
        accessToken: String,
        includeAlternates: Bool = true,
        continuousDriveMinutes: Double? = nil
    ) async throws -> RouteDifficultyResponse {
        try await analyzeRoute(
            origin: .address(origin.trimmingCharacters(in: .whitespacesAndNewlines)),
            destination: .address(destination.trimmingCharacters(in: .whitespacesAndNewlines)),
            departureTime: departureTime,
            accessToken: accessToken,
            includeAlternates: includeAlternates,
            continuousDriveMinutes: continuousDriveMinutes
        )
    }

    /// Uses the measured endpoints of a completed local drive. The server
    /// receives coordinates as native route waypoints, never as display text.
    ///
    /// `departureTime` defaults to `nil`, meaning "analyze current
    /// conditions" rather than a specific moment: this call analyzes a drive
    /// that already happened, so there is no real departure to schedule
    /// against, and sending "now" as a timestamp risks it reading as past by
    /// the time it reaches Google's Routes API.
    func analyzeRoute(
        origin: RouteCoordinateEndpoint,
        destination: RouteCoordinateEndpoint,
        accessToken: String,
        departureTime: Date? = nil,
        includeAlternates: Bool = false,
        continuousDriveMinutes: Double? = nil
    ) async throws -> RouteDifficultyResponse {
        try await analyzeRoute(
            origin: .coordinate(origin),
            destination: .coordinate(destination),
            departureTime: departureTime,
            accessToken: accessToken,
            includeAlternates: includeAlternates,
            continuousDriveMinutes: continuousDriveMinutes
        )
    }

    private func analyzeRoute(
        origin: RouteRequestEndpoint,
        destination: RouteRequestEndpoint,
        departureTime: Date?,
        accessToken: String,
        includeAlternates: Bool,
        continuousDriveMinutes: Double?
    ) async throws -> RouteDifficultyResponse {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let localTime = Calendar.autoupdatingCurrent.dateComponents(
            [.hour, .minute],
            from: departureTime ?? Date()
        )
        let departureLocalMinutes = (localTime.hour ?? 0) * 60 + (localTime.minute ?? 0)

        let body = RouteDifficultyRequest(
            origin: origin,
            destination: destination,
            departureTime: departureTime.map(formatter.string(from:)),
            departureLocalMinutes: departureLocalMinutes,
            includeAlternates: includeAlternates,
            continuousDriveMinutes: continuousDriveMinutes
        )

        let requestBody = try JSONEncoder().encode(body)

        return try await sendWithFallback(
            path: "api/route/difficulty",
            body: requestBody,
            responseType: RouteDifficultyResponse.self,
            host: .route,
            accessToken: accessToken
        )
    }

    /// Compares only route conditions for a small set of departure windows.
    /// The local readiness profile is intentionally not sent to the backend.
    func compareDepartureTimes(
        origin: String,
        destination: String,
        selectedDeparture: Date,
        accessToken: String,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) async throws -> DepartureComparisonResponse {
        let candidates = DepartureComparisonWindowBuilder.makeCandidates(
            selectedDeparture: selectedDeparture,
            now: now,
            calendar: calendar
        )
        return try await compareDepartureTimes(
            origin: origin,
            destination: destination,
            candidates: candidates,
            accessToken: accessToken
        )
    }

    func compareDepartureTimes(
        origin: String,
        destination: String,
        candidates: [DepartureComparisonCandidate],
        accessToken: String
    ) async throws -> DepartureComparisonResponse {
        let body = DepartureComparisonRequest(
            origin: origin.trimmingCharacters(in: .whitespacesAndNewlines),
            destination: destination.trimmingCharacters(in: .whitespacesAndNewlines),
            candidates: candidates
        )
        let requestBody = try JSONEncoder().encode(body)

        return try await sendWithFallback(
            path: "api/route/departure-comparison",
            body: requestBody,
            responseType: DepartureComparisonResponse.self,
            host: .route,
            accessToken: accessToken
        )
    }

    /// Tries each candidate base URL in order, only moving to the next one on
    /// a network failure (an HTTP error or bad response means that host is
    /// reachable, so it's the final answer, not a reason to try another).
    /// The candidates share one time budget: a host that consumed it does not
    /// get to hand a second full wait to the host after it.
    private func sendWithFallback<Response: Decodable>(
        path: String,
        body: Data,
        responseType: Response.Type,
        host: Host,
        accessToken: String? = nil
    ) async throws -> Response {
        let candidates = candidateBaseURLs(for: host)
        guard !candidates.isEmpty else { throw APIError.invalidURL }

        var lastNetworkError: Error = URLError(.cannotConnectToHost)
        let deadline = Date().addingTimeInterval(Self.totalRequestBudget)

        for baseURL in candidates {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining >= Self.minimumCandidateTimeout else { break }

            do {
                return try await sendRequest(
                    to: baseURL,
                    path: path,
                    body: body,
                    timeout: min(remaining, Self.maximumCandidateTimeout),
                    responseType: responseType,
                    accessToken: accessToken
                )
            } catch APIError.networkError(let error) {
                lastNetworkError = error
                guard Self.shouldTryNextCandidate(after: error) else {
                    throw APIError.networkError(error)
                }
            }
        }

        throw APIError.networkError(lastNetworkError)
    }

    private func candidateBaseURLs(for host: Host) -> [URL] {
        switch host {
        case .route:
            routeCandidateBaseURLs
        case .data:
            dataCandidateBaseURLs
        }
    }

    /// A timeout already spent the shared budget, and a cancellation is a
    /// deliberate stop (`deleteDrive()` cancels in-flight route analysis).
    /// Neither is a reason to send another request to another host.
    static func shouldTryNextCandidate(after error: Error) -> Bool {
        if error is CancellationError { return false }
        guard let urlError = error as? URLError else { return true }
        switch urlError.code {
        case .timedOut, .cancelled:
            return false
        default:
            return true
        }
    }

    private func sendRequest<Response: Decodable>(
        to baseURL: URL,
        path: String,
        body: Data,
        timeout: TimeInterval,
        responseType: Response.Type,
        accessToken: String? = nil
    ) async throws -> Response {
        let endpoint = Self.endpoint(baseURL: baseURL, path: path)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = timeout
        request.httpBody = body

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = Self.userFacingErrorMessage(from: data)
            if message == nil, !data.isEmpty {
                // A proxy's HTML error page is useful to a developer and
                // meaningless in a banner, so it is logged and not shown.
                apiLogger.error(
                    "Unreadable \(httpResponse.statusCode, privacy: .public) body from \(endpoint.absoluteString, privacy: .public): \(String(decoding: data.prefix(Self.maximumLoggedErrorBodyBytes), as: UTF8.self), privacy: .private)"
                )
            }
            throw APIError.httpError(statusCode: httpResponse.statusCode, message: message)
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    private func requestData(
        to baseURL: URL,
        path: String,
        method: String,
        body: Data?,
        headers: [String: String],
        timeout: TimeInterval
    ) async throws -> HTTPResponseData {
        let endpoint = Self.endpoint(baseURL: baseURL, path: path)
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.httpBody = body
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        return HTTPResponseData(data: data, response: httpResponse)
    }

    /// Only the backend's own JSON error text is ever shown. Anything else —
    /// a proxy's HTML page, a truncated body, an essay — returns nil, so the
    /// banner falls back to "Server error (502)." rather than pasting a page
    /// into the UI.
    static func userFacingErrorMessage(from data: Data) -> String? {
        struct ErrorBody: Decodable {
            let error: String?
            let message: String?
        }
        guard let body = try? JSONDecoder().decode(ErrorBody.self, from: data),
              let raw = body.error ?? body.message else {
            return nil
        }
        let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty,
              message.count <= maximumErrorMessageLength,
              !message.contains(where: { $0.isNewline }),
              !message.contains("<") else {
            return nil
        }
        return message
    }

    /// Long enough for a real backend message, short enough that nothing
    /// page-sized reaches a banner.
    private static let maximumErrorMessageLength = 200
    private static let maximumLoggedErrorBodyBytes = 2_048

    private static func endpoint(baseURL: URL, path: String) -> URL {
        guard let queryStart = path.firstIndex(of: "?") else {
            return baseURL.appendingPathComponent(path)
        }

        let pathPart = String(path[..<queryStart])
        let queryPart = String(path[path.index(after: queryStart)...])
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(pathPart),
            resolvingAgainstBaseURL: false
        ) else {
            return baseURL.appendingPathComponent(path)
        }
        components.percentEncodedQuery = queryPart
        return components.url ?? baseURL.appendingPathComponent(path)
    }
}

enum AppConfiguration {
    private static let localhostBaseURL = URL(string: "http://localhost:3000")!
    private static let dataLocalhostBaseURL = URL(string: "http://localhost:3001")!

    /// The deployed backend (if configured), then localhost, then a
    /// developer's Mac on the LAN (if configured) — in that order, with
    /// duplicates removed. A fresh checkout with no local config still works
    /// against a locally running backend; a physical iPhone with the
    /// deployed URL configured never needs the Mac to be reachable at all.
    ///
    /// Localhost exists only in a debug build. On a shipped app nothing is
    /// listening on the phone itself, so keeping it would only spend a
    /// driver's time failing to reach a host that cannot be there.
    static var candidateBaseURLs: [URL] {
        #if DEBUG
        let ordered = [configuredAPIBaseURL, localhostBaseURL, configuredFallbackBaseURL]
        #else
        let ordered = [configuredAPIBaseURL, configuredFallbackBaseURL]
        #endif

        var candidates: [URL] = []
        for url in ordered {
            guard let url, !candidates.contains(url) else { continue }
            candidates.append(url)
        }
        return candidates
    }

    /// The deployed data API (if configured), then its separate local
    /// development port. The route API keeps port 3000, while the data API can
    /// run with `PORT=3001` so both services can be started together.
    static var dataCandidateBaseURLs: [URL] {
        #if DEBUG
        let ordered = [configuredDataAPIBaseURL, dataLocalhostBaseURL]
        #else
        let ordered = [configuredDataAPIBaseURL]
        #endif

        var candidates: [URL] = []
        for url in ordered {
            guard let url, !candidates.contains(url) else { continue }
            candidates.append(url)
        }
        return candidates
    }

    private static var configuredAPIBaseURL: URL? {
        configuredURL(forInfoDictionaryKey: "API_BASE_URL")
    }

    private static var configuredDataAPIBaseURL: URL? {
        configuredURL(forInfoDictionaryKey: "DATA_API_BASE_URL")
    }

    private static var configuredFallbackBaseURL: URL? {
        configuredURL(forInfoDictionaryKey: "API_FALLBACK_BASE_URL")
    }

    private static func configuredURL(forInfoDictionaryKey key: String) -> URL? {
        guard let urlString = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("$"),
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return nil
        }
        return url
    }
}
