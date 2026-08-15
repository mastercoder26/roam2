import Foundation

@main
struct APIClientChecks {
    static func main() async {
        backendJSONErrorsReachTheUser()
        rawResponseBodiesDoNotReachTheUser()
        aTimeoutOrCancellationEndsTheAttempt()
        theTimeBudgetIsSharedAcrossCandidates()
        await routeAndDataCallsUseSeparateHostSets()

        print("API client checks passed")
    }

    private static func backendJSONErrorsReachTheUser() {
        expect(
            APIClient.userFacingErrorMessage(from: json(#"{"error":"Origin and destination must differ."}"#))
                == "Origin and destination must differ.",
            "the backend's own error text should still be shown"
        )
        expect(
            APIClient.userFacingErrorMessage(from: json(#"{"message":"That address could not be found."}"#))
                == "That address could not be found.",
            "a message field should be accepted like an error field"
        )
        expect(
            APIError.httpError(statusCode: 400, message: "Origin and destination must differ.").errorDescription
                == "Server error (400): Origin and destination must differ.",
            "a real backend message should keep its place in the banner"
        )
    }

    private static func rawResponseBodiesDoNotReachTheUser() {
        let proxyPage = Data(
            "<html><head><title>502 Bad Gateway</title></head><body><h1>502 Bad Gateway</h1></body></html>".utf8
        )
        expect(
            APIClient.userFacingErrorMessage(from: proxyPage) == nil,
            "a proxy's HTML error page must never be rendered as the banner text"
        )
        expect(
            APIError.httpError(statusCode: 502, message: nil).errorDescription == "Server error (502).",
            "an unreadable body should fall back to a generic, honest message"
        )

        expect(
            APIClient.userFacingErrorMessage(from: Data()) == nil,
            "an empty body carries no message"
        )
        expect(
            APIClient.userFacingErrorMessage(from: Data("Service Unavailable".utf8)) == nil,
            "a plain-text body is not a structured backend error"
        )
        expect(
            APIClient.userFacingErrorMessage(from: json(#"{"error":"  "}"#)) == nil,
            "a blank message should not produce an empty banner"
        )
        expect(
            APIClient.userFacingErrorMessage(from: json(#"{"error":"<h1>Gateway Timeout</h1>"}"#)) == nil,
            "markup smuggled through a JSON field is still markup"
        )

        let essay = String(repeating: "detail ", count: 200)
        expect(
            APIClient.userFacingErrorMessage(from: json(#"{"error":"\#(essay)"}"#)) == nil,
            "a page-sized message must not be pasted into a banner"
        )
    }

    private static func aTimeoutOrCancellationEndsTheAttempt() {
        expect(
            !APIClient.shouldTryNextCandidate(after: URLError(.timedOut)),
            "a timeout already spent the shared budget, so the next host must not get a fresh one"
        )
        expect(
            !APIClient.shouldTryNextCandidate(after: URLError(.cancelled)),
            "a cancelled analysis must not fire a second request at another host"
        )
        expect(
            !APIClient.shouldTryNextCandidate(after: CancellationError()),
            "a structured cancellation means stop"
        )
        expect(
            APIClient.shouldTryNextCandidate(after: URLError(.cannotConnectToHost)),
            "an unreachable host is still a reason to try the next one"
        )
        expect(
            APIClient.shouldTryNextCandidate(after: URLError(.notConnectedToInternet)),
            "a non-timeout network failure should not stop the fallback"
        )
    }

    private static func theTimeBudgetIsSharedAcrossCandidates() {
        expect(
            APIClient.maximumCandidateTimeout < APIClient.totalRequestBudget,
            "one candidate must not be able to consume the whole budget"
        )
        expect(
            APIClient.minimumCandidateTimeout > 0
                && APIClient.minimumCandidateTimeout < APIClient.maximumCandidateTimeout,
            "the leftover-budget floor must be a real, smaller bound"
        )
        expect(
            APIClient.totalRequestBudget <= 60,
            "the whole attempt should finish inside the old per-candidate timeout, not multiply it"
        )
    }

    private static func routeAndDataCallsUseSeparateHostSets() async {
        let routePrimary = URL(string: "https://route-primary.example")!
        let routeFallback = URL(string: "https://route-fallback.example")!
        let dataPrimary = URL(string: "https://data-primary.example")!
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [APIClientChecksURLProtocol.self]

        APIClientChecksURLProtocol.reset(responses: [
            routePrimary: .failure(URLError(.cannotConnectToHost)),
            routeFallback: .success(Data("not a route response".utf8)),
            dataPrimary: .success(Data())
        ])

        let client = APIClient(
            candidateBaseURLs: [routePrimary, routeFallback],
            dataCandidateBaseURLs: [dataPrimary],
            session: URLSession(configuration: sessionConfiguration)
        )

        _ = try? await client.analyzeRoute(
            origin: "Origin",
            destination: "Destination",
            departureTime: Date(),
            accessToken: "test-token"
        )
        _ = try? await client.requestData(
            path: "api/drives",
            method: "GET",
            host: .data
        )

        let requests = APIClientChecksURLProtocol.requests
        expect(
            requests.map { $0.url?.host } == [
                "route-primary.example",
                "route-fallback.example",
                "data-primary.example"
            ],
            "route failover must stay within its host set before a data call uses the data host"
        )
        expect(
            requests[0].url?.path == "/api/route/difficulty"
                && requests[1].url?.path == "/api/route/difficulty"
                && requests[2].url?.path == "/api/drives",
            "difficulty and data endpoints must resolve against their respective host sets"
        )
    }

    private static func json(_ value: String) -> Data {
        Data(value.utf8)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fatalError("API client check failed: \(message)")
    }
}

private final class APIClientChecksURLProtocol: URLProtocol {
    enum Response {
        case success(Data)
        case failure(Error)
    }

    private static var responseByHost: [String: Response] = [:]
    private(set) static var requests: [URLRequest] = []

    static func reset(responses: [URL: Response]) {
        responseByHost = Dictionary(uniqueKeysWithValues: responses.map { ($0.key.host!, $0.value) })
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let response = Self.responseByHost[host] else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.requests.append(request)

        switch response {
        case let .success(data):
            let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
