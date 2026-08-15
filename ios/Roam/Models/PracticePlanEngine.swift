import Foundation

/// Persisted practice-plan categories. The values are stable local identifiers,
/// not route text or map detail.
enum PracticeGoalKind: String, Codable, Hashable {
    case buildRecordedHistory
    case routeDemand
    case routeFamiliarity
    case drivingQuality
}

enum PracticeGoalStatus: String, Codable, Hashable {
    case queued
    case measured
    case needsMorePractice
    case notMeasured

    var title: String {
        switch self {
        case .queued: "Ready to practice"
        case .measured: "Measured today"
        case .needsMorePractice: "Keep practicing"
        case .notMeasured: "Not measured today"
        }
    }
}

/// A private, typed practice target. Codable fields intentionally include only
/// stable goal IDs, optional demand IDs, and status. Display copy is computed
/// from those values, so saved data never contains an address, polyline, or
/// route-demand geometry.
struct PracticeGoal: Identifiable, Codable, Hashable {
    let id: String
    let kind: PracticeGoalKind
    let demandID: String?
    let status: PracticeGoalStatus

    init(
        id: String,
        kind: PracticeGoalKind,
        demandID: String? = nil,
        status: PracticeGoalStatus = .queued
    ) {
        self.id = id
        self.kind = kind
        self.demandID = demandID
        self.status = status
    }

    var title: String {
        switch kind {
        case .buildRecordedHistory:
            return "Build recorded experience"
        case .routeDemand:
            let demandTitle = demandID.flatMap(RouteDemandKind.init(rawValue:))?.defaultTitle ?? "this route demand"
            return "Practice \(demandTitle.lowercased())"
        case .routeFamiliarity:
            return "Practice the full route"
        case .drivingQuality:
            return "Practice calm driving"
        }
    }

    var coachingText: String {
        switch kind {
        case .buildRecordedHistory:
            return "Record manual drives with usable GPS and motion on different days. Practice with an adult until Roam has enough measured history to compare routes."
        case .routeDemand:
            return "Practice this route demand with an adult. Start and end a manual drive so Roam can measure the part of the route you covered."
        case .routeFamiliarity:
            return "Practice the route with an adult from start to finish. Roam only recognizes continuous, directionally aligned GPS coverage."
        case .drivingQuality:
            return "Use smooth braking, acceleration, and turns on a calm practice drive before adding more route demand."
        }
    }

    var requiresAdultSupervision: Bool {
        switch kind {
        case .buildRecordedHistory, .routeDemand, .routeFamiliarity:
            return true
        case .drivingQuality:
            return false
        }
    }
}

/// A privacy-safe plan that can be queued with a manually started drive.
/// It has no route geometry, address, or raw sensor samples.
struct PracticePlan: Identifiable, Codable, Hashable {
    /// A plan stays actionable only while it is short. This is the single
    /// source of truth for that cap, on both the build and the decode path.
    static let maximumGoalCount = 3

    let id: UUID
    let createdAt: Date
    let goals: [PracticeGoal]

    init(id: UUID = UUID(), createdAt: Date = Date(), goals: [PracticeGoal]) {
        self.id = id
        self.createdAt = createdAt
        self.goals = Array(goals.prefix(Self.maximumGoalCount))
    }

    /// Explicit decoding: the synthesized `Decodable` would assign `goals`
    /// directly and restore a plan with more goals than the cap allows.
    /// `Encodable` stays synthesized so persisted keys are unchanged.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            goals: try container.decode([PracticeGoal].self, forKey: .goals)
        )
    }

    var summary: String {
        guard !goals.isEmpty else {
            return "No specific practice target is needed from the recorded evidence available today."
        }
        if goals.count == 1 {
            return "One practice target is ready for this route."
        }
        return "\(goals.count) practice targets are ready for this route."
    }
}

/// Numeric, local-only route-coverage data derived while a planned route was
/// still in memory. It intentionally does not retain its source geometry.
struct PracticeDemandCoverage: Identifiable, Codable, Hashable {
    var id: String { demandID }
    let demandID: String
    let demandIntensity: Double
    let coveredShare: Double
    let routeShare: Double

    init(
        demandID: String,
        demandIntensity: Double,
        coveredShare: Double,
        routeShare: Double
    ) {
        self.demandID = demandID
        self.demandIntensity = UntrustedNumber.unitFraction(demandIntensity)
        self.coveredShare = UntrustedNumber.unitFraction(coveredShare)
        self.routeShare = UntrustedNumber.unitFraction(routeShare)
    }

    /// Explicit decoding so persisted coverage cannot restore an out-of-range
    /// share, which `DriverReadinessProfileBuilder`'s practice-evidence gate
    /// would otherwise accept as valid evidence.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            demandID: try container.decode(String.self, forKey: .demandID),
            demandIntensity: try container.decode(Double.self, forKey: .demandIntensity),
            coveredShare: try container.decode(Double.self, forKey: .coveredShare),
            routeShare: try container.decode(Double.self, forKey: .routeShare)
        )
    }

    init(_ exposure: VerifiedDemandExposure) {
        self.init(
            demandID: exposure.demandID,
            demandIntensity: exposure.demandIntensity,
            coveredShare: exposure.coveredShare,
            routeShare: exposure.routeShare
        )
    }
}

struct PracticeRouteCoverageSummary: Codable, Hashable {
    static let routeCoverageThreshold = 0.60
    static let continuousCoverageThreshold = 0.45
    static let endpointCoverageThreshold = 0.60
    static let demandCoverageThreshold = 0.70

    let recordedAt: Date
    let overallCoverage: Double
    let longestContinuousCoverage: Double
    let originCoverage: Double
    let destinationCoverage: Double
    let demandCoverage: [PracticeDemandCoverage]

    init(
        recordedAt: Date,
        overallCoverage: Double,
        longestContinuousCoverage: Double,
        originCoverage: Double,
        destinationCoverage: Double,
        demandCoverage: [PracticeDemandCoverage]
    ) {
        self.recordedAt = recordedAt
        self.overallCoverage = UntrustedNumber.unitFraction(overallCoverage)
        self.longestContinuousCoverage = UntrustedNumber.unitFraction(longestContinuousCoverage)
        self.originCoverage = UntrustedNumber.unitFraction(originCoverage)
        self.destinationCoverage = UntrustedNumber.unitFraction(destinationCoverage)
        self.demandCoverage = demandCoverage
    }

    /// Explicit decoding so persisted summaries are clamped exactly as freshly
    /// computed ones are. Every coverage figure is compared against a
    /// threshold, so an unclamped value silently passes every gate.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            recordedAt: try container.decode(Date.self, forKey: .recordedAt),
            overallCoverage: try container.decode(Double.self, forKey: .overallCoverage),
            longestContinuousCoverage: try container.decode(Double.self, forKey: .longestContinuousCoverage),
            originCoverage: try container.decode(Double.self, forKey: .originCoverage),
            destinationCoverage: try container.decode(Double.self, forKey: .destinationCoverage),
            demandCoverage: try container.decode([PracticeDemandCoverage].self, forKey: .demandCoverage)
        )
    }

    init(coverage: PracticeRouteCoverage, recordedAt: Date) {
        self.init(
            recordedAt: recordedAt,
            overallCoverage: coverage.overallCoverage,
            longestContinuousCoverage: coverage.longestContinuousCoverage,
            originCoverage: coverage.originCoverage,
            destinationCoverage: coverage.destinationCoverage,
            demandCoverage: coverage.demandExposures.map(PracticeDemandCoverage.init)
        )
    }

    var isVerifiedRoutePractice: Bool {
        overallCoverage >= Self.routeCoverageThreshold &&
            longestContinuousCoverage >= Self.continuousCoverageThreshold &&
            originCoverage >= Self.endpointCoverageThreshold &&
            destinationCoverage >= Self.endpointCoverageThreshold
    }

    var hasMeasuredRouteProgress: Bool {
        overallCoverage >= 0.05 || longestContinuousCoverage >= 0.05 || !demandCoverage.isEmpty
    }

    func coveredShare(for demandID: String) -> Double? {
        demandCoverage.first(where: { $0.demandID == demandID })?.coveredShare
    }

    func verifiedDemandExposures() -> [VerifiedDemandExposure] {
        demandCoverage.map {
            VerifiedDemandExposure(
                demandID: $0.demandID,
                demandIntensity: $0.demandIntensity,
                coveredShare: $0.coveredShare,
                routeShare: $0.routeShare,
                recordedAt: recordedAt
            )
        }
    }
}

enum PracticeDriveDebriefOutcome: String, Codable, Hashable {
    case verifiedRoutePractice
    case partialRouteCoverage
    case insufficientGPSCoverage
    case savedNotYetQualifying

    var headline: String {
        switch self {
        case .verifiedRoutePractice:
            return "Practice route verified"
        case .partialRouteCoverage:
            return "Part of the practice route was measured"
        case .insufficientGPSCoverage:
            return "Route coverage could not be measured"
        case .savedNotYetQualifying:
            return "Drive saved, but not yet readiness evidence"
        }
    }

    var summary: String {
        switch self {
        case .verifiedRoutePractice:
            return "This drive followed enough of the planned route for Roam to use its measured coverage as practice evidence."
        case .partialRouteCoverage:
            return "Roam measured part of the planned route. A more complete continuous pass can strengthen the practice record."
        case .insufficientGPSCoverage:
            return "Roam could not verify enough continuous GPS coverage of the planned route on this drive."
        case .savedNotYetQualifying:
            return "This drive is saved, but it did not have enough usable GPS and motion evidence to change route readiness."
        }
    }
}

struct PracticeGoalCompletion: Identifiable, Codable, Hashable {
    var id: String { goalID }
    let goalID: String
    let status: PracticeGoalStatus
    /// Allows the UI to distinguish a goal that was observed today from one
    /// that was not captured at all, even when more repetition is still useful.
    let wasMeasuredToday: Bool
    let recordedAt: Date
}

/// The persisted local result of a queued practice drive. It keeps only plan
/// identity, numeric coverage, goal status, and local timestamps.
struct PracticeDriveDebrief: Codable, Hashable {
    let planID: UUID
    let createdAt: Date
    let outcome: PracticeDriveDebriefOutcome
    let coverage: PracticeRouteCoverageSummary?
    let goalCompletions: [PracticeGoalCompletion]

    var headline: String { outcome.headline }
    var summary: String { outcome.summary }
    var measuredGoalIDs: [String] {
        goalCompletions.filter(\.wasMeasuredToday).map(\.goalID)
    }
    var goalsStillNeedingPractice: [String] {
        goalCompletions.filter { $0.status == .needsMorePractice }.map(\.goalID)
    }
}

/// Produces a small, typed coaching plan from readiness evidence, then turns a
/// saved manual drive into a privacy-safe debrief. It does not score driving,
/// infer route conditions, or send local history anywhere.
enum PracticePlanEngine {
    static func makePlan(
        assessment: DriverReadinessAssessment,
        route: ScoredRoute,
        createdAt: Date = Date()
    ) -> PracticePlan {
        var goals: [PracticeGoal] = []

        if assessment.verdict == .insufficientHistory {
            goals.append(
                PracticeGoal(
                    id: "recordedHistory",
                    kind: .buildRecordedHistory
                )
            )
        }

        // A persisted assessment predates this file's deduplication, so the
        // dictionary build must tolerate repeats rather than trap on them.
        let insightsByID = assessment.insights.keyedByID()
        let demandGoals = (route.routeDemands ?? []).enumerated().compactMap { index, demand -> (demand: RouteDemand, index: Int, state: DriverReadinessInsightState)? in
            guard demand.available,
                  demand.intensity >= 0.34,
                  let insight = insightsByID[demand.id],
                  insight.state == .practiceNeeded || insight.state == .unmeasured else {
                return nil
            }
            return (demand, index, insight.state)
        }
        .sorted { lhs, rhs in
            if lhs.demand.intensity != rhs.demand.intensity {
                return lhs.demand.intensity > rhs.demand.intensity
            }
            let lhsStateOrder = demandStateOrder(lhs.state)
            let rhsStateOrder = demandStateOrder(rhs.state)
            if lhsStateOrder != rhsStateOrder {
                return lhsStateOrder < rhsStateOrder
            }
            return lhs.index < rhs.index
        }

        for candidate in demandGoals where goals.count < PracticePlan.maximumGoalCount {
            goals.append(
                PracticeGoal(
                    id: "demand:\(candidate.demand.id)",
                    kind: .routeDemand,
                    demandID: candidate.demand.id
                )
            )
        }

        if goals.count < PracticePlan.maximumGoalCount,
           insightsByID[DriverReadinessInsightID.familiarity]?.state == .practiceNeeded {
            goals.append(
                PracticeGoal(
                    id: "routeFamiliarity",
                    kind: .routeFamiliarity
                )
            )
        }

        if goals.count < PracticePlan.maximumGoalCount,
           insightsByID[DriverReadinessInsightID.drivingQuality]?.state == .practiceNeeded {
            goals.append(
                PracticeGoal(
                    id: "drivingQuality",
                    kind: .drivingQuality
                )
            )
        }

        return PracticePlan(createdAt: createdAt, goals: goals)
    }

    static func makeDebrief(
        plan: PracticePlan,
        savedDrive: RecordedDrive,
        coverage: PracticeRouteCoverageSummary?,
        profileBefore: DriverReadinessProfile,
        profileAfter: DriverReadinessProfile,
        configuration: DriverReadinessEngine.Configuration = .init(),
        calendar: Calendar = .current,
        createdAt: Date? = nil
    ) -> PracticeDriveDebrief {
        let qualifies = DriverReadinessEngine.qualifies(
            savedDrive,
            configuration: configuration,
            calendar: calendar
        )
        let outcome: PracticeDriveDebriefOutcome
        if !qualifies {
            outcome = .savedNotYetQualifying
        } else if let coverage, coverage.isVerifiedRoutePractice {
            outcome = .verifiedRoutePractice
        } else if coverage?.hasMeasuredRouteProgress == true {
            outcome = .partialRouteCoverage
        } else {
            outcome = .insufficientGPSCoverage
        }

        let recordedAt = createdAt ?? savedDrive.startedAt
        let completions = plan.goals.map {
            completion(
                for: $0,
                qualifies: qualifies,
                outcome: outcome,
                coverage: coverage,
                profileBefore: profileBefore,
                profileAfter: profileAfter,
                configuration: configuration,
                recordedAt: recordedAt
            )
        }
        return PracticeDriveDebrief(
            planID: plan.id,
            createdAt: recordedAt,
            outcome: outcome,
            coverage: coverage,
            goalCompletions: completions
        )
    }

    private static func demandStateOrder(_ state: DriverReadinessInsightState) -> Int {
        switch state {
        case .unmeasured: 0
        case .practiceNeeded: 1
        case .matched, .informational: 2
        }
    }

    private static func completion(
        for goal: PracticeGoal,
        qualifies: Bool,
        outcome: PracticeDriveDebriefOutcome,
        coverage: PracticeRouteCoverageSummary?,
        profileBefore: DriverReadinessProfile,
        profileAfter: DriverReadinessProfile,
        configuration: DriverReadinessEngine.Configuration,
        recordedAt: Date
    ) -> PracticeGoalCompletion {
        let status: PracticeGoalStatus
        let wasMeasuredToday: Bool

        switch goal.kind {
        case .buildRecordedHistory:
            guard qualifies else {
                status = .notMeasured
                wasMeasuredToday = false
                break
            }
            wasMeasuredToday = true
            status = !profileBefore.hasEnoughRecordedExperience(using: configuration) &&
                profileAfter.hasEnoughRecordedExperience(using: configuration)
                ? .measured
                : .needsMorePractice
        case .routeDemand:
            guard qualifies, let demandID = goal.demandID else {
                status = .notMeasured
                wasMeasuredToday = false
                break
            }
            guard let coveredShare = coverage?.coveredShare(for: demandID) else {
                status = .notMeasured
                wasMeasuredToday = false
                break
            }
            wasMeasuredToday = true
            status = outcome == .verifiedRoutePractice &&
                coveredShare >= PracticeRouteCoverageSummary.demandCoverageThreshold
                ? .measured
                : .needsMorePractice
        case .routeFamiliarity:
            guard qualifies, let coverage else {
                status = .notMeasured
                wasMeasuredToday = false
                break
            }
            wasMeasuredToday = coverage.hasMeasuredRouteProgress
            status = outcome == .verifiedRoutePractice ? .measured : .needsMorePractice
        case .drivingQuality:
            guard qualifies else {
                status = .notMeasured
                wasMeasuredToday = false
                break
            }
            wasMeasuredToday = true
            let behavior = profileAfter.behavior
            let isCalmEnough = (behavior.recentWeightedEventRatePerTenMiles ?? .greatestFiniteMagnitude) <= 3.5 &&
                (behavior.recentWeightedAverageScore ?? 0) >= 75
            status = isCalmEnough ? .measured : .needsMorePractice
        }

        return PracticeGoalCompletion(
            goalID: goal.id,
            status: status,
            wasMeasuredToday: wasMeasuredToday,
            recordedAt: recordedAt
        )
    }
}
