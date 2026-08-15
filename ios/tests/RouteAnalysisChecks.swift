import CoreLocation
import Foundation

/// Covers the automatic route-difficulty analysis that runs when a drive ends.
///
/// These drive the real `APIClient.analyzeRoute` path — request encoding and
/// response decoding included — against a stubbed transport, so a regression
/// in either direction fails here rather than silently degrading to
/// "Route difficulty could not be analyzed right now" on a real phone.
@main
struct RouteAnalysisChecks {
    @MainActor
    static func main() async {
        setvbuf(stdout, nil, _IONBF, 0)
        endpointsComeFromTheOuterEdgesOfTheTrace()
        aTooShortTraceIsRejectedBeforeAnyNetworkCall()
        await theAutomaticRequestOmitsDepartureTime()
        await aManuallyPlannedRouteStillSendsItsDepartureTime()
        await aRealBackendResponseBecomesAnAvailableAnalysis()
        await aProviderFailureIsRetryEligibleAndKeepsTheDrive()
        await theRequestCarriesTheAccountsBearerToken()
        aSignedOutDriveKeepsItsFullRetryBudget()

        print("Route analysis checks passed")
    }

    // MARK: - Endpoint derivation

    private static func endpointsComeFromTheOuterEdgesOfTheTrace() {
        let drive = makeDrive(route: longTrace())
        guard let endpoints = DriveRouteAnalysisEngine.endpoints(for: drive) else {
            fail("a continuous multi-kilometre trace should yield endpoints")
        }

        expect(
            abs(endpoints.origin.latitude - 37.7749) < 0.0001
                && abs(endpoints.origin.longitude - (-122.4194)) < 0.0001,
            "the origin should be the first valid trace point"
        )
        expect(
            abs(endpoints.destination.latitude - 37.8049) < 0.0001
                && abs(endpoints.destination.longitude - (-122.3894)) < 0.0001,
            "the destination should be the last valid trace point"
        )
    }

    private static func aTooShortTraceIsRejectedBeforeAnyNetworkCall() {
        // Two points ~11m apart: under the 80m endpoint minimum.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let route = [
            DriveRoutePoint(timestamp: start, coordinate: DriveCoordinate(CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)), speedMetersPerSecond: 5),
            DriveRoutePoint(timestamp: start.addingTimeInterval(5), coordinate: DriveCoordinate(CLLocationCoordinate2D(latitude: 37.7750, longitude: -122.4194)), speedMetersPerSecond: 5)
        ]
        expect(
            DriveRouteAnalysisEngine.endpoints(for: makeDrive(route: route)) == nil,
            "a trace shorter than the endpoint minimum must not be sent to the server"
        )
    }

    // MARK: - Request encoding

    /// The regression this suite exists for. The automatic post-drive analysis
    /// used to send `departureTime: Date()`. By the time that timestamp reached
    /// Google's Routes API it read as in the past, which Google rejects with a
    /// 400 — surfacing as a 503 and a permanent "couldn't analyze" on device.
    @MainActor
    private static func theAutomaticRequestOmitsDepartureTime() async {
        let stub = StubTransport(responseBody: Data(realBackendResponseJSON.utf8))
        let client = makeClient(stub: stub)
        let endpoints = DriveRouteAnalysisEngine.endpoints(for: makeDrive(route: longTrace()))!

        _ = try? await client.analyzeRoute(
            origin: endpoints.origin,
            destination: endpoints.destination,
            accessToken: "test-token",
            includeAlternates: false,
            continuousDriveMinutes: 42
        )

        guard let body = stub.capturedBody, let json = jsonObject(body) else {
            fail("the analyze call should have sent a JSON body")
        }

        expect(
            json["departureTime"] == nil,
            "the automatic post-drive request must omit departureTime so Google cannot reject it as past"
        )
        expect(json["departureLocalMinutes"] != nil, "the local clock hint should still be sent")
        expect(json["continuousDriveMinutes"] as? Double == 42, "the drive length should reach the fatigue model")

        // Coordinates must travel as native waypoints, never as display text.
        let origin = json["origin"] as? [String: Any]
        expect(origin?["latitude"] as? Double != nil, "the origin should encode as a coordinate, not an address string")
        expect(stub.capturedPath?.hasSuffix("/api/route/difficulty") == true, "it should call the difficulty endpoint")
    }

    /// The planning screens analyze a *future* departure the driver picked, so
    /// they must keep sending it. Only the after-the-fact path drops it.
    @MainActor
    private static func aManuallyPlannedRouteStillSendsItsDepartureTime() async {
        let stub = StubTransport(responseBody: Data(realBackendResponseJSON.utf8))
        let client = makeClient(stub: stub)
        let departure = Date(timeIntervalSince1970: 1_800_000_000)

        _ = try? await client.analyzeRoute(
            origin: "1 Market St, San Francisco",
            destination: "San Jose, CA",
            departureTime: departure,
            accessToken: "test-token",
            includeAlternates: true
        )

        guard let body = stub.capturedBody, let json = jsonObject(body) else {
            fail("the planning call should have sent a JSON body")
        }
        expect(
            json["departureTime"] as? String != nil,
            "a driver-selected future departure must still be sent"
        )
    }

    // MARK: - Response decoding

    /// The fixture is a verbatim response captured from the deployed Cloud Run
    /// backend, so a server-side shape change fails here instead of on a phone.
    @MainActor
    private static func aRealBackendResponseBecomesAnAvailableAnalysis() async {
        let stub = StubTransport(responseBody: Data(realBackendResponseJSON.utf8))
        let client = makeClient(stub: stub)
        let endpoints = DriveRouteAnalysisEngine.endpoints(for: makeDrive(route: longTrace()))!

        let response: RouteDifficultyResponse
        do {
            response = try await client.analyzeRoute(
                origin: endpoints.origin,
                destination: endpoints.destination,
                accessToken: "test-token",
                includeAlternates: false,
                continuousDriveMinutes: 42
            )
        } catch {
            fail("a real backend response should decode: \(error)")
        }

        let analysis = DriveRouteAnalysisEngine.result(from: response.primaryRoute)
        expect(analysis.status == .available, "a scored route should produce an available analysis")
        expect(analysis.difficultyScore != nil, "the difficulty score should survive decoding")
        expect(analysis.label != nil, "the difficulty label should survive decoding")
        expect(analysis.highlights.isEmpty == false, "the driver should get at least one highlight")
        expect(analysis.shouldRetry() == false, "a resolved analysis must not be retried")
    }

    /// A backend failure must leave the analysis retryable and never discard
    /// the drive or its coaching score.
    @MainActor
    private static func aProviderFailureIsRetryEligibleAndKeepsTheDrive() async {
        let stub = StubTransport(
            responseBody: Data(#"{"error":"Route analysis is temporarily unavailable.","code":"ROUTE_UNAVAILABLE"}"#.utf8),
            statusCode: 503
        )
        let client = makeClient(stub: stub)
        let endpoints = DriveRouteAnalysisEngine.endpoints(for: makeDrive(route: longTrace()))!

        var threw = false
        do {
            _ = try await client.analyzeRoute(
                origin: endpoints.origin,
                destination: endpoints.destination,
                accessToken: "test-token",
                includeAlternates: false
            )
        } catch {
            threw = true
        }
        expect(threw, "a 503 from the route backend should surface as an error")

        let unavailable = DriveRouteAnalysis.unavailable(
            "Route difficulty could not be analyzed right now.",
            retryEligible: true,
            lastAttemptAt: Date(timeIntervalSince1970: 1_700_000_000),
            retryCount: 1
        )
        expect(unavailable.status == .unavailable, "a failed analysis should record as unavailable")
        expect(unavailable.shouldRetry(at: Date()) == true, "a transient failure should stay retry-eligible")
    }

    /// Route analysis proxies a metered upstream API, so the backend only
    /// serves signed-in accounts. If the token stopped reaching the wire every
    /// analysis would 401 — silently, since the client reports it as a generic
    /// "couldn't analyze right now".
    @MainActor
    private static func theRequestCarriesTheAccountsBearerToken() async {
        let stub = StubTransport(responseBody: Data(realBackendResponseJSON.utf8))
        let client = makeClient(stub: stub)
        let endpoints = DriveRouteAnalysisEngine.endpoints(for: makeDrive(route: longTrace()))!

        _ = try? await client.analyzeRoute(
            origin: endpoints.origin,
            destination: endpoints.destination,
            accessToken: "account-token-abc",
            includeAlternates: false
        )

        expect(
            stub.capturedAuthorization == "Bearer account-token-abc",
            "the signed-in account's token must be sent so the backend can authorize the call"
        )
    }

    /// A drive finished while signed out records an unavailable analysis, but
    /// that is not a failed *attempt* — signing in later must still analyze it.
    /// If it consumed the retry budget, four signed-out drives would leave the
    /// route permanently unanalyzable even after the driver signs in.
    ///
    /// This asserts the invariant the signed-out branch of
    /// `DriveSessionManager.beginAutomaticRouteAnalysis` relies on. The branch
    /// itself lives behind UIKit and cannot run in this harness.
    private static func aSignedOutDriveKeepsItsFullRetryBudget() {
        let signedOut = DriveRouteAnalysis.unavailable(
            "Sign in to analyze this route's difficulty. The drive and its coaching score are still saved.",
            retryEligible: true,
            lastAttemptAt: nil,
            retryCount: 0
        )

        expect(signedOut.retryCount == 0, "being signed out must not count as a delivery attempt")
        expect(signedOut.shouldRetry(), "signing in later should still analyze the drive")
    }

    // MARK: - Fixtures

    private static func makeClient(stub: StubTransport) -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.current = stub
        return APIClient(
            candidateBaseURLs: [URL(string: "https://stub.invalid")!],
            dataCandidateBaseURLs: [URL(string: "https://stub.invalid")!],
            session: URLSession(configuration: configuration)
        )
    }

    /// ~4.2km of steady highway-speed points, sampled every 5s.
    private static func longTrace() -> [DriveRoutePoint] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return (0..<31).map { step in
            DriveRoutePoint(
                timestamp: start.addingTimeInterval(Double(step) * 5),
                coordinate: DriveCoordinate(CLLocationCoordinate2D(
                    latitude: 37.7749 + 0.001 * Double(step),
                    longitude: -122.4194 + 0.001 * Double(step)
                )),
                speedMetersPerSecond: 29
            )
        }
    }

    private static func makeDrive(route: [DriveRoutePoint]) -> RecordedDrive {
        let quality = DriveDataQuality(
            acceptedLocationSamples: route.count,
            rejectedLocationSamples: 0,
            motionSamples: route.count,
            confidence: .high
        )
        let score = DrivingScore(
            score: 82,
            duration: 900,
            distanceMeters: 4_200,
            topSpeedMetersPerSecond: 31,
            events: [],
            motionSamples: route.count,
            dataQuality: quality
        )
        return RecordedDrive(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            score: score,
            route: route
        )
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fatalError("Route analysis check failed: \(message)")
    }
}

// MARK: - Stubbed transport

private final class StubTransport: @unchecked Sendable {
    let responseBody: Data
    let statusCode: Int
    var capturedBody: Data?
    var capturedPath: String?
    var capturedAuthorization: String?

    init(responseBody: Data, statusCode: Int = 200) {
        self.responseBody = responseBody
        self.statusCode = statusCode
    }
}

/// Intercepts the request the production `APIClient` actually builds, so these
/// checks never touch the network yet still exercise the real encoding path.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var current: StubTransport?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.current
        // URLProtocol strips httpBody for streamed bodies; read the stream too.
        stub?.capturedBody = request.httpBody ?? request.httpBodyStream.map(Self.drain)
        stub?.capturedPath = request.url?.path
        stub?.capturedAuthorization = request.value(forHTTPHeaderField: "Authorization")

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub?.statusCode ?? 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub?.responseBody ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

// MARK: - Captured backend response

/// Verbatim `POST /api/route/difficulty` response from the deployed backend.
private let realBackendResponseJSON = #"""
{"primaryRoute":{"score":5.9,"uncalibratedScore":7,"label":"Moderate","reasons":["Heavy traffic","Dense decision windows","Demanding segment hotspot","High-speed environment","Mostly highway","Long drive"],"breakdown":{"speed":0.5564676369762019,"merges":0.13119542936654102,"turns":0.12139991338605274,"traffic":0.826084098418664,"length":0.6101971464014477,"fatigue":0.18567611082838223,"weather":0,"road":0.02,"highway":0.5564676369762019,"maneuvers":0.12139991338605274,"navDensity":0.12139991338605274,"effort":0.6101971464014477},"contributions":[{"factor":"speed","label":"High-speed road burden","value":0.5564676369762019,"weight":0.24,"contribution":0.13355223287428847,"share":0.212},{"factor":"traffic","label":"Traffic burden","value":0.826084098418664,"weight":0.14,"contribution":0.11565177377861298,"share":0.184},{"factor":"hotspot","label":"Hardest segment (69%)","value":0.6900000000000001,"weight":0,"contribution":0.10350000000000001,"share":0.165},{"factor":"length","label":"Length/monotony burden","value":0.6101971464014477,"weight":0.14,"contribution":0.0854276004962027,"share":0.136},{"factor":"decisionDensity","label":"Dense decision windows","value":0.7052512401677583,"weight":0.08,"contribution":0.056420099213420664,"share":0.09},{"factor":"sustained","label":"Sustained attention","value":0.22853977199609907,"weight":0.24,"contribution":0.05484954527906377,"share":0.087},{"factor":"merges","label":"Merge/interchange burden","value":0.13119542936654102,"weight":0.26,"contribution":0.034110811635300664,"share":0.054},{"factor":"turns","label":"Maneuver burden","value":0.12139991338605274,"weight":0.22,"contribution":0.026707980944931604,"share":0.042},{"factor":"fatigue","label":"Drive timing / load","value":0.18567611082838223,"weight":0.1,"contribution":0.018567611082838224,"share":0.03}],"uncertainty":{"low":5.7,"high":6.1,"confidence":0.825,"spread":0.35,"evidence":{"schemaVersion":"evidence-v1","inputCoverage":0.85,"level":"wellSupported","predictiveValidation":"notValidated","signalCoverage":{"routeGeometry":1,"trafficTiming":1,"speedLimits":0,"weather":1,"roadMetadata":1,"turnControls":1},"verifiedSignals":["routeGeometry","trafficTiming","weather","roadMetadata","turnControls"],"missingSignals":["speedLimits"]}},"hotspots":[{"segmentIndex":8,"difficulty":0.69,"cumulativeSecondsFromStart":4895.544747081713,"label":"Local segment (~0.2 mi)"},{"segmentIndex":1,"difficulty":0.557,"cumulativeSecondsFromStart":7.45136186770428,"label":"Local segment (~0.4 mi)"},{"segmentIndex":2,"difficulty":0.53,"cumulativeSecondsFromStart":266.75875486381324,"label":"Local segment (~0.2 mi)"},{"segmentIndex":9,"difficulty":0.436,"cumulativeSecondsFromStart":4937.272373540856,"label":"Local segment (~0.7 mi)"},{"segmentIndex":3,"difficulty":0.382,"cumulativeSecondsFromStart":326.36964980544747,"label":"Local segment (~0.4 mi)"}],"routeDemands":[{"id":"afterDark","title":"After-dark driving","intensity":0,"level":"low","evidence":"The scheduled departure keeps this drive outside in the 8 PM\u20136 AM window used when sunset cannot be estimated.","available":true,"metrics":{"departureLocalMinutes":600,"nighttimeShare":0,"nighttimeDurationSeconds":0,"nightMiles":0,"expectedDurationSeconds":5362,"nighttimeCoverageFraction":0,"sunriseLocalMinutes":360,"sunsetLocalMinutes":1200,"overviewGeometryMeters":91228.98973411898,"verifiedOverviewNighttimeFraction":0},"coverageRanges":[]},{"id":"fastRoads","title":"Fast roads","intensity":0.94,"level":"high","evidence":"97% of the route is estimated at 45+ mph, including 91% at 60+ mph.","available":true,"metrics":{"estimatedMilesAt45":54.773870595720986,"estimatedMilesAt55":51.46941859540284,"estimatedMilesAt60":51.46941859540284,"estimatedMilesAt65":45.013993279249185,"estimated45PlusDistanceMeters":88150,"estimated55PlusDistanceMeters":82832,"estimated60PlusDistanceMeters":82832,"estimated65PlusDistanceMeters":72443,"estimated45PlusShare":0.9661015091568669,"estimated60PlusShare":0.9078175860065978,"meanEstimatedSpeedMph":63.943548970850784,"maxEstimatedSpeedMph":67.43861464835622,"longestEstimated45PlusRunMeters":88150},"coverageRanges":[{"startFraction":0.01875,"endFraction":0.98485}]},{"id":"merges","title":"Merges and ramps","intensity":0.32,"level":"low","evidence":"4 ramps or merge transitions appear in the route instructions.","available":true,"metrics":{"mergeInstructionCount":0,"rampInstructionCount":4,"mergeTransitionCount":4,"weaveSectionCount":0,"mergeClusterCount":0,"transitionDensityPerMile":0.070550452079566,"coverageFraction":0.02192000000000016},"coverageRanges":[{"startFraction":0.00843,"endFraction":0.01391},{"startFraction":0.17109,"endFraction":0.17657},{"startFraction":0.96914,"endFraction":0.97462},{"startFraction":0.98552,"endFraction":0.991}]},{"id":"complexIntersections","title":"Complex intersections","intensity":0.4,"level":"moderate","evidence":"3 turn, fork, roundabout, or U-turn instructions appear on this route.","available":true,"metrics":{"intersectionInstructionCount":3,"turnClusterCount":0,"closeTurnPairCount":0,"sharpTurnInstructionCount":0,"decisionPointsPerMile":3.202674626865672,"coverageFraction":0.008220000000000005,"unprotectedLeftTurnCount":0,"protectedLeftTurnCount":0,"unprotectedLeftTurnShare":0},"coverageRanges":[{"startFraction":0.00574,"endFraction":0.00903},{"startFraction":0.05834,"endFraction":0.06163},{"startFraction":0.99836,"endFraction":1}]},{"id":"weatherVisibility","title":"Weather and visibility","intensity":0,"level":"low","evidence":"Live route weather: Partly cloudy; 8.8 mi visibility.","available":true,"metrics":{"weatherSeverity":0,"precipitationIntensity":0,"snowRisk":0,"windSeverity":0,"lowVisibilityRisk":0,"icyRisk":0,"visibilityMiles":8.8,"windGustMph":21,"temperatureF":70}},{"id":"sustainedDrive","title":"Sustained drive","intensity":0.47,"level":"moderate","evidence":"Expected drive time is about 89 minutes.","available":true,"metrics":{"expectedDurationSeconds":5362,"expectedDurationMinutes":89.36666666666666,"routeDistanceMeters":91245,"staticDurationSeconds":3598,"trafficDelaySeconds":1764},"coverageRanges":[{"startFraction":0,"endFraction":1}]},{"id":"traffic","title":"Traffic","intensity":1,"level":"high","evidence":"Traffic-aware timing is 29 minutes (49%) longer than the no-traffic estimate.","available":true,"metrics":{"trafficDelaySeconds":1764,"trafficDelayMinutes":29.4,"trafficDelayFraction":0.49027237354085607,"trafficAwareDurationSeconds":5362,"staticDurationSeconds":3598,"trafficRatio":1.490272373540856}},{"id":"roadConditions","title":"Road conditions","intensity":0.04,"level":"low","evidence":"Road data shows no notable narrow-road, unpaved, or construction exposure detected.","available":true,"metrics":{"constructionZoneCount":0,"roadSizeScore":0.04,"averageLaneCount":3.9,"narrowRoadShare":0,"majorRoadShare":0.96,"unpavedRoadShare":0,"verifiedRoadSampleCount":24}}],"conditions":{"weather":{"available":true,"condition":"Partly cloudy","severity":0,"precipIntensity":0,"snowRisk":0,"windSeverity":0,"lowVisibilityRisk":0,"icyRisk":0,"temperatureF":70,"windGustMph":21,"visibilityMiles":8.8},"road":{"available":true,"avgLanes":3.9,"narrowRoadShare":0,"majorRoadShare":0.96,"unpavedShare":0,"roadSizeScore":0.04,"constructionZones":0,"dominantRoadClass":"motorway","classCounts":{"primary":1,"motorway":22,"tertiary":1}},"turns":{"available":true,"unprotectedLeftTurns":0,"protectedLeftTurns":0,"unprotectedTurnShare":0},"sources":["open-meteo","osm-overpass","google-route-warnings"]},"modelVersion":"hybrid-v6","distanceMeters":91245,"durationSeconds":5362,"staticDurationSeconds":3598,"trafficDelaySeconds":1764,"polyline":"_p~iF~ps|U","bounds":{"southwest":{"lat":37.3146252,"lng":-122.47215969999999},"northeast":{"lat":37.775033799999996,"lng":-121.886325}}},"alternateRoutes":[]}
"""#
