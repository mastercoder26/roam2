import CoreLocation
import Foundation

enum DrivingEventKind: String, CaseIterable, Identifiable, Codable {
    case hardBrake
    case rapidAcceleration
    case sharpCorner
    case phoneMovement

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hardBrake: "Hard braking"
        case .rapidAcceleration: "Rapid acceleration"
        case .sharpCorner: "Sharp corner"
        case .phoneMovement: "Possible phone handling"
        }
    }

    var symbol: String {
        switch self {
        case .hardBrake: "brakesignal"
        case .rapidAcceleration: "bolt.car.fill"
        case .sharpCorner: "arrow.triangle.turn.up.right.diamond.fill"
        case .phoneMovement: "iphone.gen3.radiowaves.left.and.right"
        }
    }
}

struct DriveCoordinate: Codable, Hashable {
    let latitude: CLLocationDegrees
    let longitude: CLLocationDegrees

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var clLocationCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct DriveRoutePoint: Codable, Identifiable, Hashable {
    let timestamp: Date
    let coordinate: DriveCoordinate
    let speedMetersPerSecond: Double

    var id: Date { timestamp }
}

struct DrivingEvent: Identifiable, Codable, Hashable {
    let id: UUID
    let kind: DrivingEventKind
    let timestamp: Date
    let source: DrivingEventSource
    /// Present for GPS/fused events and for motion events after a GPS fix.
    let coordinate: DriveCoordinate?

    init(id: UUID = UUID(), kind: DrivingEventKind, timestamp: Date, source: DrivingEventSource, coordinate: DriveCoordinate? = nil) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.source = source
        self.coordinate = coordinate
    }
}

struct DrivingScore: Codable {
    let score: Int
    let duration: TimeInterval
    let distanceMeters: CLLocationDistance
    let topSpeedMetersPerSecond: CLLocationSpeed
    let events: [DrivingEvent]
    let motionSamples: Int
    let dataQuality: DriveDataQuality

    var distanceMiles: Double { distanceMeters / 1_609.344 }
    var topSpeedMPH: Int { Int((topSpeedMetersPerSecond * 2.23694).rounded()) }
    var formattedDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 3_600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? "0m"
    }

    var grade: String {
        if dataQuality.confidence == .low { return "Preliminary" }
        switch score {
        case 90...:
            return "Excellent"
        case 78...:
            return "Steady"
        case 65...:
            return "Needs attention"
        default:
            return "Practice needed"
        }
    }

    var summary: String {
        guard dataQuality.confidence != .low else {
            return dataQuality.summary
        }
        guard !events.isEmpty else {
            return "Smooth trip. Keep leaving room to brake and taking turns calmly."
        }
        let mostCommon = Dictionary(grouping: events, by: \.kind)
            .max { $0.value.count < $1.value.count }?.key
        return mostCommon.map { "Focus on fewer \($0.title.lowercased()) events next drive." }
            ?? "Review this trip before the next drive."
    }

    func count(for kind: DrivingEventKind) -> Int {
        events.filter { $0.kind == kind }.count
    }
}

/// A locally verified portion of a planned route demand. It stores only a
/// stable demand identifier and coverage numbers—never an address, route
/// polyline, or map coordinate.
struct VerifiedDemandExposure: Identifiable, Codable, Hashable {
    var id: String { demandID }
    let demandID: String
    let demandIntensity: Double
    /// Share of the demand's mapped route range covered by a continuous,
    /// directionally aligned GPS trace.
    let coveredShare: Double
    /// Portion of the full planned route represented by this demand range.
    let routeShare: Double
    let recordedAt: Date

    private enum CodingKeys: String, CodingKey {
        case demandID
        case demandIntensity
        case coveredShare
        case routeShare
        case recordedAt
    }

    init(
        demandID: String,
        demandIntensity: Double,
        coveredShare: Double,
        routeShare: Double,
        recordedAt: Date
    ) {
        self.demandID = demandID
        self.demandIntensity = min(max(demandIntensity, 0), 1)
        self.coveredShare = min(max(coveredShare, 0), 1)
        self.routeShare = min(max(routeShare, 0), 1)
        self.recordedAt = recordedAt
    }

    /// Decoding is the untrusted path, so it must not be the one path that
    /// skips the clamping above. The synthesized conformance assigned stored
    /// properties directly, letting a `coveredShare` of 9 pass every share
    /// threshold downstream. Key names are unchanged, so saved history that was
    /// written before this initializer existed still reads back.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            demandID: try values.decode(String.self, forKey: .demandID),
            demandIntensity: try values.decode(Double.self, forKey: .demandIntensity),
            coveredShare: try values.decode(Double.self, forKey: .coveredShare),
            routeShare: try values.decode(Double.self, forKey: .routeShare),
            recordedAt: try values.decode(Date.self, forKey: .recordedAt)
        )
    }
}

/// A minimal description of a planned route demand retained with a practice
/// record. It intentionally retains only a stable demand ID. Display copy,
/// numeric metrics, and mapped route ranges are needed only while the plan is
/// in memory.
struct PlannedRouteDemandTag: Codable, Hashable {
    let id: String

    init(_ demand: RouteDemand) {
        id = demand.id
    }
}

/// Route characteristics intentionally saved with a manually started practice
/// drive. It contains no origin, destination, raw polyline, map coordinates,
/// or demand-location ranges; the recorded GPS trace remains local to the
/// device as part of the drive.
struct PlannedRouteContext: Identifiable, Codable, Hashable {
    let id: UUID
    let createdAt: Date
    /// Full demands exist only while a queued/active practice plan is in
    /// memory. The custom encoder below persists `routeDemandTags` instead.
    let routeDemands: [RouteDemand]
    let routeDemandTags: [PlannedRouteDemandTag]
    /// Set only after the locally recorded GPS trace overlaps the in-memory
    /// planned route. It stores a verdict, never route geometry or addresses.
    let recordedRouteMatched: Bool?
    /// Demand-specific coverage derived while the planned geometry was still
    /// in memory. Older contexts intentionally decode without these claims.
    let verifiedDemandExposures: [VerifiedDemandExposure]?
    /// A typed, local coaching plan. It carries stable goal IDs only and never
    /// planned addresses, map geometry, or route prose.
    let practicePlan: PracticePlan?
    /// Numeric coverage produced while the planned polyline was held in
    /// memory. Saved history retains these measurements, not the geometry.
    let coverageSummary: PracticeRouteCoverageSummary?
    /// The local post-drive coaching result for a queued practice plan.
    let debrief: PracticeDriveDebrief?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        routeDemands: [RouteDemand],
        recordedRouteMatched: Bool? = nil,
        verifiedDemandExposures: [VerifiedDemandExposure]? = nil,
        practicePlan: PracticePlan? = nil,
        coverageSummary: PracticeRouteCoverageSummary? = nil,
        debrief: PracticeDriveDebrief? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.routeDemands = routeDemands
        self.routeDemandTags = routeDemands.map(PlannedRouteDemandTag.init)
        self.recordedRouteMatched = recordedRouteMatched
        self.verifiedDemandExposures = verifiedDemandExposures
        self.practicePlan = practicePlan
        self.coverageSummary = coverageSummary
        self.debrief = debrief
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case routeDemands // legacy saved contexts only
        case routeDemandTags
        case recordedRouteMatched
        case verifiedDemandExposures
        case practicePlan
        case coverageSummary
        case debrief
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        let legacyDemands = try values.decodeIfPresent([RouteDemand].self, forKey: .routeDemands)
        let savedTags = try values.decodeIfPresent([PlannedRouteDemandTag].self, forKey: .routeDemandTags)
        routeDemandTags = savedTags ?? legacyDemands?.map(PlannedRouteDemandTag.init) ?? []
        // A restored context never needs detailed demand mapping to assess
        // history. The verified numeric exposures below are the only evidence
        // used. Lightweight placeholders preserve compatibility for callers
        // that still inspect this property after decoding old history.
        routeDemands = legacyDemands ?? routeDemandTags.map(Self.placeholderDemand)
        recordedRouteMatched = try values.decodeIfPresent(Bool.self, forKey: .recordedRouteMatched)
        verifiedDemandExposures = try values.decodeIfPresent(
            [VerifiedDemandExposure].self,
            forKey: .verifiedDemandExposures
        )
        practicePlan = try values.decodeIfPresent(PracticePlan.self, forKey: .practicePlan)
        coverageSummary = try values.decodeIfPresent(PracticeRouteCoverageSummary.self, forKey: .coverageSummary)
        debrief = try values.decodeIfPresent(PracticeDriveDebrief.self, forKey: .debrief)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(createdAt, forKey: .createdAt)
        // Do not serialize routeDemands. Their metrics and coverage ranges can
        // reconstruct planned-route detail and are unnecessary after a drive.
        try values.encode(routeDemandTags, forKey: .routeDemandTags)
        try values.encodeIfPresent(recordedRouteMatched, forKey: .recordedRouteMatched)
        try values.encodeIfPresent(verifiedDemandExposures, forKey: .verifiedDemandExposures)
        try values.encodeIfPresent(practicePlan, forKey: .practicePlan)
        try values.encodeIfPresent(coverageSummary, forKey: .coverageSummary)
        try values.encodeIfPresent(debrief, forKey: .debrief)
    }

    private static func placeholderDemand(for tag: PlannedRouteDemandTag) -> RouteDemand {
        return RouteDemand(
            id: tag.id,
            intensity: 0,
            level: .low,
            evidence: "Saved planned-route category.",
            available: false
        )
    }
}

struct RecordedDrive: Identifiable, Codable {
    let id: UUID
    let startedAt: Date
    let score: DrivingScore
    let route: [DriveRoutePoint]
    /// Captured for new recordings so clock-based after-dark history keeps the
    /// driver's local time even if the phone later changes time zones.
    let recordingTimeZoneIdentifier: String?
    /// A privacy-preserving local summary. Legacy drives derive this from their
    /// saved trace when readiness is evaluated.
    let experienceSummary: DriveExperienceSummary?
    /// Absent on historical drives and on ordinary manual drives. Its optional
    /// type makes old `recorded-drives-v1` data decode without a migration.
    let plannedRouteContext: PlannedRouteContext?
    /// Compact result of the automatic start-to-destination route analysis.
    /// It deliberately retains no endpoint text, coordinates, or route geometry.
    let routeAnalysis: DriveRouteAnalysis?

    init(
        id: UUID = UUID(),
        startedAt: Date,
        score: DrivingScore,
        route: [DriveRoutePoint],
        recordingTimeZoneIdentifier: String? = nil,
        experienceSummary: DriveExperienceSummary? = nil,
        plannedRouteContext: PlannedRouteContext? = nil,
        routeAnalysis: DriveRouteAnalysis? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.score = score
        self.route = route
        self.recordingTimeZoneIdentifier = recordingTimeZoneIdentifier
        self.experienceSummary = experienceSummary
        self.plannedRouteContext = plannedRouteContext
        self.routeAnalysis = routeAnalysis
    }

    func replacingRouteAnalysis(with routeAnalysis: DriveRouteAnalysis) -> RecordedDrive {
        RecordedDrive(
            id: id,
            startedAt: startedAt,
            score: score,
            route: route,
            recordingTimeZoneIdentifier: recordingTimeZoneIdentifier,
            experienceSummary: experienceSummary,
            plannedRouteContext: plannedRouteContext,
            routeAnalysis: routeAnalysis
        )
    }
}
