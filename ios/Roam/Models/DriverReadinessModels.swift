import CoreLocation
import Foundation

/// The coaching states shown for a route. They are deliberately not a driving
/// permission or safety guarantee.
enum DriverReadinessVerdict: String {
    case insufficientHistory
    case looksLikeMatch
    case practiceWithAdult

    var title: String {
        switch self {
        case .insufficientHistory: "Need more recorded experience"
        case .looksLikeMatch: "Looks like a match for recorded experience"
        case .practiceWithAdult: "Practice this with an adult"
        }
    }
}

enum DriverReadinessInsightState: String, Hashable {
    case matched
    case practiceNeeded
    case unmeasured
    case informational
}

enum DriverReadinessEvidenceSource: String, Hashable {
    case gpsMotion
    case routeOverlap
    case taggedPractice
    case unavailable
}

struct DriverReadinessEvidence: Hashable {
    let source: DriverReadinessEvidenceSource
    let recordedValue: String
    let comparisonTarget: String?
    let routeEvidence: String
    let collectionNote: String?
}

struct DriverReadinessInsight: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let state: DriverReadinessInsightState
    let evidence: DriverReadinessEvidence?

    init(
        id: String,
        title: String,
        detail: String,
        state: DriverReadinessInsightState,
        evidence: DriverReadinessEvidence? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.state = state
        self.evidence = evidence
    }
}

enum RouteFamiliarityLevel: String {
    case unmeasured
    case unfamiliar
    case partlyFamiliar
    case familiar
}

/// Local GPS overlap only. No familiarity value or recorded trace is sent to
/// the route-analysis backend.
struct RouteFamiliarity {
    let level: RouteFamiliarityLevel
    let matchedShare: Double
    let sampledPointCount: Int
    let matchingPointCount: Int
    let bestSingleDriveShare: Double
    let longestContinuousShare: Double
    let matchingDriveCount: Int
    let mostRecentMatchingDrive: Date?
}

/// Exposure from continuous, qualifying drives. A session only counts when its
/// local trace actually measured the characteristic.
struct DriverExperienceExposure {
    let miles: Double
    let effectiveMiles: Double
    let duration: TimeInterval
    let sessionCount: Int
    let distinctDayCount: Int
    let recentMiles: Double
    let recentSessionCount: Int
    let recentDistinctDayCount: Int
    let lastRecordedAt: Date?
    let longestEpisodeDuration: TimeInterval
    let longestEpisodeMiles: Double
    let episodes: [DriverExperienceEpisode]
}

struct DriverExperienceEpisode: Hashable {
    let duration: TimeInterval
    let miles: Double
    let recordedAt: Date
    let localDayKey: String
}

struct DrivingBehaviorProfile {
    let measuredMiles: Double
    let recentMeasuredMiles: Double
    let weightedEventRatePerTenMiles: Double?
    let recentWeightedEventRatePerTenMiles: Double?
    let highSpeedEventRatePerTenMiles: Double?
    let afterDarkEventRatePerTenMiles: Double?
    let weightedAverageScore: Double?
    let recentWeightedAverageScore: Double?
    let hardBrakesPerTenMiles: Double?
    let sharpCornersPerTenMiles: Double?
}

struct TaggedPracticeEvidence {
    let driveID: UUID
    let demandIntensity: Double
    let coveredShare: Double
    let routeShare: Double
    let recordedAt: Date
}

/// A private aggregate view of usable drives on this phone. It intentionally
/// contains no origin, destination, cloud identifier, or outbound history.
struct DriverReadinessProfile {
    let qualifyingDriveCount: Int
    let qualifyingDriveDayCount: Int
    let totalMiles: Double
    let reliableTraceMiles: Double
    let recentQualifyingDriveCount: Int
    let recentReliableTraceMiles: Double
    let effectiveReliableTraceMiles: Double
    let totalContinuousDuration: TimeInterval
    let nightMiles: Double
    let highSpeedMiles: Double
    let highestSpeedMiles: Double
    let longestDriveDuration: TimeInterval
    let averageDrivingScore: Double?
    let recentAverageDrivingScore: Double?
    let taggedExposureCounts: [String: Int]
    let nightExposure: DriverExperienceExposure
    let fastRoad45Exposure: DriverExperienceExposure
    let fastRoad55Exposure: DriverExperienceExposure
    let fastRoad60Exposure: DriverExperienceExposure
    let fastRoad65Exposure: DriverExperienceExposure
    let sustainedExposure: DriverExperienceExposure
    let behavior: DrivingBehaviorProfile
    let taggedPracticeEvidence: [String: [TaggedPracticeEvidence]]

    var hasEnoughRecordedExperience: Bool {
        hasEnoughRecordedExperience(using: DriverReadinessEngine.Configuration())
    }

    func hasEnoughRecordedExperience(using configuration: DriverReadinessEngine.Configuration) -> Bool {
        let recentHistoryFloor = min(
            configuration.minimumHistoryMiles,
            max(configuration.minimumRecentHistoryMiles, configuration.minimumHistoryMiles * 0.25)
        )
        return qualifyingDriveCount >= configuration.minimumHistoryDriveCount &&
            qualifyingDriveDayCount >= configuration.minimumHistoryDayCount &&
            reliableTraceMiles >= configuration.minimumHistoryMiles &&
            totalContinuousDuration >= configuration.minimumHistoryTraceDuration &&
            recentQualifyingDriveCount >= configuration.minimumRecentHistoryDriveCount &&
            recentReliableTraceMiles >= recentHistoryFloor
    }

    func taggedExposureCount(for demand: RouteDemandKind) -> Int {
        taggedExposureCounts[demand.rawValue, default: 0]
    }

    func taggedPractice(for demandID: String) -> [TaggedPracticeEvidence] {
        taggedPracticeEvidence[demandID, default: []]
    }
}

struct DriverReadinessAssessment {
    let verdict: DriverReadinessVerdict
    let headline: String
    let summary: String
    let insights: [DriverReadinessInsight]
    let profile: DriverReadinessProfile
    let familiarity: RouteFamiliarity
}
