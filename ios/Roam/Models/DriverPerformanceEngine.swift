import Foundation

/// The saved state of an automatic route analysis. A failure never affects the
/// local drive record or its sensor-based coaching score.
enum DriveRouteAnalysisStatus: String, Codable, Hashable {
    case pending
    case available
    case unavailable
}

enum DriveRouteAnalysisSource: String, Codable, Hashable {
    /// Start/end coordinates were analyzed by the configured route service.
    case routeService
    /// A historical drive was estimated solely from its private, local trace.
    case recordedTrace
}

/// A compact, private snapshot of contextual difficulty for one completed
/// drive. Start/end coordinates are used only for the request, then discarded
/// from this model; the saved route trace remains on the device as before.
struct DriveRouteAnalysis: Codable, Hashable {
    let status: DriveRouteAnalysisStatus
    let difficultyScore: Double?
    let label: DifficultyLabel?
    let highlights: [String]
    let analyzedAt: Date?
    let modelVersion: String?
    let analyzedRouteDistanceMeters: Int?
    let analyzedRouteDurationSeconds: Int?
    let detail: String?
    /// Optional for forward-compatible decoding of the first saved snapshot.
    let source: DriveRouteAnalysisSource?
    /// Failed network requests can resume later; insufficient GPS never retries.
    let retryEligible: Bool?
    let lastAttemptAt: Date?
    let retryCount: Int?

    static let pending = DriveRouteAnalysis(
        status: .pending,
        difficultyScore: nil,
        label: nil,
        highlights: [],
        analyzedAt: nil,
        modelVersion: nil,
        analyzedRouteDistanceMeters: nil,
        analyzedRouteDurationSeconds: nil,
        detail: "Analyzing the recorded start and destination.",
        source: .routeService,
        retryEligible: true,
        lastAttemptAt: nil,
        retryCount: 0
    )

    static func available(
        difficultyScore: Double,
        label: DifficultyLabel,
        highlights: [String],
        analyzedAt: Date,
        modelVersion: String? = nil,
        analyzedRouteDistanceMeters: Int? = nil,
        analyzedRouteDurationSeconds: Int? = nil,
        source: DriveRouteAnalysisSource = .routeService
    ) -> DriveRouteAnalysis {
        DriveRouteAnalysis(
            status: .available,
            difficultyScore: min(max(difficultyScore, 0), 10),
            label: label,
            highlights: Array(highlights.prefix(3)),
            analyzedAt: analyzedAt,
            modelVersion: modelVersion,
            analyzedRouteDistanceMeters: analyzedRouteDistanceMeters,
            analyzedRouteDurationSeconds: analyzedRouteDurationSeconds,
            detail: source == .routeService
                ? "Route conditions were analyzed after this drive ended."
                : "Estimated privately from the recorded route trace; no historical endpoints were sent for analysis.",
            source: source,
            retryEligible: false,
            lastAttemptAt: nil,
            retryCount: 0
        )
    }

    static func unavailable(
        _ detail: String,
        retryEligible: Bool = false,
        lastAttemptAt: Date? = nil,
        retryCount: Int = 0
    ) -> DriveRouteAnalysis {
        DriveRouteAnalysis(
            status: .unavailable,
            difficultyScore: nil,
            label: nil,
            highlights: [],
            analyzedAt: nil,
            modelVersion: nil,
            analyzedRouteDistanceMeters: nil,
            analyzedRouteDurationSeconds: nil,
            detail: detail,
            source: nil,
            retryEligible: retryEligible,
            lastAttemptAt: lastAttemptAt,
            retryCount: retryCount
        )
    }

    var isUsableForPerformance: Bool {
        status == .available && difficultyScore != nil
    }

    /// Network retries are deliberately bounded and spaced so opening the app
    /// does not repeatedly submit the same saved endpoints during an outage.
    func shouldRetry(at date: Date = Date()) -> Bool {
        let attempts = retryCount ?? 0
        guard attempts < 4 else { return false }
        if status == .pending { return true }
        guard status == .unavailable, retryEligible == true else { return false }
        guard let lastAttemptAt else { return true }
        let exponent = Double(max(0, attempts - 1))
        let delay = min(6 * 60 * 60, 5 * 60 * pow(2, exponent))
        return date.timeIntervalSince(lastAttemptAt) >= delay
    }

    /// A `.pending` analysis is only honest while a request is actually in
    /// flight. Once the retry budget is spent — or the app was killed
    /// mid-request and no task survived — nothing will ever move it off
    /// `.pending`, so the UI would spin "Analyzing route" forever. Callers use
    /// this to resolve those drives instead of leaving them stalled.
    func isStalled(at date: Date = Date()) -> Bool {
        status == .pending && !shouldRetry(at: date)
    }

    func recordingAttempt(at date: Date = Date()) -> DriveRouteAnalysis {
        DriveRouteAnalysis(
            status: .pending,
            difficultyScore: nil,
            label: nil,
            highlights: [],
            analyzedAt: nil,
            modelVersion: nil,
            analyzedRouteDistanceMeters: nil,
            analyzedRouteDurationSeconds: nil,
            detail: "Analyzing the recorded start and destination.",
            source: .routeService,
            retryEligible: true,
            lastAttemptAt: date,
            retryCount: (retryCount ?? 0) + 1
        )
    }
}

/// The exact, temporary inputs for a post-drive route request. They are never
/// encoded with `RecordedDrive` or shown in driving history.
struct DriveRouteAnalysisEndpoints: Hashable {
    let origin: RouteCoordinateEndpoint
    let destination: RouteCoordinateEndpoint
}

enum DriveRouteAnalysisEngine {
    static let minimumEndpointDistanceMeters = 80.0

    /// Uses only the outer endpoints of valid, continuous GPS segments so a
    /// start or finish inside a recording gap is never sent for route analysis.
    static func endpoints(for drive: RecordedDrive) -> DriveRouteAnalysisEndpoints? {
        let segments = DriveExperienceEngine.validTraceSegments(for: drive.route)
        guard let first = segments.first, let last = segments.last else { return nil }

        let origin = first.start.coordinate
        let destination = last.end.coordinate
        guard DriveExperienceEngine.coordinateDistanceMeters(origin, destination) >= minimumEndpointDistanceMeters else {
            return nil
        }

        return DriveRouteAnalysisEndpoints(
            origin: RouteCoordinateEndpoint(latitude: origin.latitude, longitude: origin.longitude),
            destination: RouteCoordinateEndpoint(latitude: destination.latitude, longitude: destination.longitude)
        )
    }

    static func result(from route: ScoredRoute, analyzedAt: Date = Date()) -> DriveRouteAnalysis {
        let demandHighlights = (route.routeDemands ?? [])
            .filter(\.available)
            .sorted { $0.intensity > $1.intensity }
            .prefix(3)
            .map(\.title)
        let highlights = demandHighlights.isEmpty ? Array(route.reasons.prefix(3)) : demandHighlights

        return .available(
            difficultyScore: route.score,
            label: route.label,
            highlights: highlights,
            analyzedAt: analyzedAt,
            modelVersion: route.modelVersion,
            analyzedRouteDistanceMeters: route.distanceMeters,
            analyzedRouteDurationSeconds: route.durationSeconds
        )
    }

    /// A transparent local fallback for drives saved before automatic route
    /// analysis existed. It considers only continuous-trace exposure—not
    /// coaching events—so driver behavior never makes a route seem harder.
    static func estimated(
        from drive: RecordedDrive,
        calendar: Calendar = .current
    ) -> DriveRouteAnalysis? {
        let summary = DriveExperienceEngine.summary(for: drive, calendar: calendar)
        let miles = summary.measuredMiles
        guard miles > 0 else { return nil }

        let speedShare = min(1, summary.speedExposure.milesAt45Plus / miles)
        let afterDarkShare = min(1, summary.lightingExposure.afterDarkMiles / miles)
        let sustainedShare = min(1, summary.measuredMinutes / 60)
        let difficulty = min(10, 1.2 + speedShare * 4.0 + afterDarkShare * 2.4 + sustainedShare * 1.8)

        var highlights: [String] = []
        if speedShare >= 0.20 { highlights.append("Fast measured speeds") }
        if afterDarkShare >= 0.20 { highlights.append("After-dark driving") }
        if sustainedShare >= 0.25 { highlights.append("Sustained continuous drive") }
        if highlights.isEmpty { highlights.append("Recorded route conditions") }

        return .available(
            difficultyScore: difficulty,
            label: difficultyLabel(for: difficulty),
            highlights: highlights,
            analyzedAt: drive.startedAt,
            source: .recordedTrace
        )
    }

    private static func difficultyLabel(for score: Double) -> DifficultyLabel {
        switch score {
        case ..<2.5: .veryEasy
        case ..<4.5: .easy
        case ..<6.5: .moderate
        case ..<8.5: .hard
        default: .veryHard
        }
    }
}

enum DriverPerformanceEvidence: Hashable {
    case building
    case growing
    case established

    var title: String {
        switch self {
        case .building: "Building your score"
        case .growing: "Growing evidence"
        case .established: "Well-supported score"
        }
    }
}

/// An evidence-weighted coaching score across measured drives. It adjusts a
/// sensor score by the independently analyzed task demand of that drive, then
/// applies bounded distance, data-quality, and recency weights. It is not a
/// safety rating, driving permission, or prediction of future outcomes.
struct DriverPerformanceSummary: Hashable {
    let score: Int?
    let evidence: DriverPerformanceEvidence
    let includedDriveCount: Int
    let analyzedDriveCount: Int
    let pendingAnalysisCount: Int
    let measuredMiles: Double
    let averageDifficulty: Double?
    let detail: String

    var hasScore: Bool { score != nil }
}

enum DriverPerformanceEngine {
    static let recencyHalfLifeDays = 120.0

    static func makeSummary(
        from drives: [RecordedDrive],
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> DriverPerformanceSummary {
        let pendingAnalysisCount = drives.filter { $0.routeAnalysis?.status == .pending }.count
        let qualifying = drives.compactMap { drive -> WeightedDrive? in
            guard drive.startedAt <= referenceDate,
                  drive.score.dataQuality.confidence != .low else {
                return nil
            }
            let analysis = drive.routeAnalysis ?? DriveRouteAnalysisEngine.estimated(from: drive, calendar: calendar)
            guard analysis?.isUsableForPerformance == true,
                  let analysis,
                  let difficulty = analysis.difficultyScore else {
                return nil
            }

            let experience = DriveExperienceEngine.summary(for: drive, calendar: calendar)
            let measuredMiles = experience.measuredMiles
            guard measuredMiles > 0 else { return nil }

            let qualityWeight: Double = drive.score.dataQuality.confidence == .high ? 1 : 0.72
            // Square-root distance prevents one unusually long drive from
            // overwhelming a broad, consistent history while still rewarding
            // reliable evidence over a tiny sample.
            let distanceWeight = min(1.5, max(0.35, sqrt(measuredMiles / 2)))
            let ageDays = max(0, referenceDate.timeIntervalSince(drive.startedAt) / 86_400)
            let recencyWeight = pow(0.5, ageDays / recencyHalfLifeDays)
            // Difficulty changes the evidence weight modestly; route challenge
            // can inform context but can never overpower measured behavior.
            let contextStrength = analysis.source == .recordedTrace ? 0.65 : 1.0
            let difficultyWeight = 1 + ((difficulty / 10) - 0.5) * 0.30 * contextStrength
            let adjustedScore = min(max(
                Double(drive.score.score) + (difficulty - 5) * 1.5 * contextStrength,
                0
            ), 100)

            return WeightedDrive(
                adjustedScore: adjustedScore,
                weight: qualityWeight * distanceWeight * recencyWeight * difficultyWeight,
                measuredMiles: measuredMiles,
                difficulty: difficulty
            )
        }

        let totalWeight = qualifying.reduce(0) { $0 + $1.weight }
        // An empty qualifying set, or one whose weights all underflowed to
        // zero (e.g. a corrupt `startedAt` many centuries old collapses the
        // recency weight to 0 via `pow`), must fall back to the same
        // no-score result. Dividing by a zero or non-finite total below would
        // otherwise produce NaN and `Int(NaN.rounded())` traps at runtime.
        guard !qualifying.isEmpty, totalWeight.isFinite, totalWeight > 0 else {
            return DriverPerformanceSummary(
                score: nil,
                evidence: .building,
                includedDriveCount: 0,
                analyzedDriveCount: 0,
                pendingAnalysisCount: pendingAnalysisCount,
                measuredMiles: 0,
                averageDifficulty: nil,
                detail: pendingAnalysisCount > 0
                    ? "Route difficulty is still being analyzed for " + String(pendingAnalysisCount) + " saved " + (pendingAnalysisCount == 1 ? "drive." : "drives.")
                    : "A score appears after a usable drive has both sensor data and route difficulty analysis."
            )
        }

        let weightedScore = qualifying.reduce(0) { $0 + $1.adjustedScore * $1.weight } / totalWeight
        let totalMiles = qualifying.reduce(0) { $0 + $1.measuredMiles }
        let averageDifficulty = qualifying.reduce(0) { $0 + $1.difficulty * $1.weight } / totalWeight
        let evidence = evidenceLevel(for: qualifying.count, miles: totalMiles)

        return DriverPerformanceSummary(
            score: Int(weightedScore.rounded()),
            evidence: evidence,
            includedDriveCount: qualifying.count,
            analyzedDriveCount: qualifying.count,
            pendingAnalysisCount: pendingAnalysisCount,
            measuredMiles: totalMiles,
            averageDifficulty: averageDifficulty,
            detail: detail(
                evidence: evidence,
                driveCount: qualifying.count,
                pendingAnalysisCount: pendingAnalysisCount
            )
        )
    }

    private static func evidenceLevel(for driveCount: Int, miles: Double) -> DriverPerformanceEvidence {
        if driveCount >= 8 && miles >= 30 { return .established }
        if driveCount >= 3 && miles >= 10 { return .growing }
        return .building
    }

    private static func detail(
        evidence: DriverPerformanceEvidence,
        driveCount: Int,
        pendingAnalysisCount: Int
    ) -> String {
        let base: String
        switch evidence {
        case .building:
            base = "Based on " + String(driveCount) + " analyzed " + (driveCount == 1 ? "drive" : "drives") + "; more varied measured routes will make it steadier."
        case .growing:
            base = "Balances recent sensor scores with the difficulty of your analyzed start-to-destination routes."
        case .established:
            base = "A broad set of measured drives supports this route-adjusted coaching score."
        }
        guard pendingAnalysisCount > 0 else { return base }
        return "\(base) \(pendingAnalysisCount) route \(pendingAnalysisCount == 1 ? "analysis is" : "analyses are") still running."
    }

    private struct WeightedDrive {
        let adjustedScore: Double
        let weight: Double
        let measuredMiles: Double
        let difficulty: Double
    }
}
