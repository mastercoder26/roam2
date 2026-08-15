import Foundation
import CoreLocation

// MARK: - Untrusted numbers

/// Clamping and conversion helpers for numbers that arrive from the backend or
/// from persisted JSON. Two Swift behaviours make the obvious spelling unsafe
/// here: `min`/`max` propagate `NaN` instead of clamping it, and `Int(_: Double)`
/// traps rather than saturating. Every value type that treats server data as
/// untrusted routes its clamping through this type so the rules stay identical
/// on the `init` path and the `Decodable` path.
enum UntrustedNumber {
    /// Fractions of a route, a share, or an intensity are all `0...1`.
    static let unitRange: ClosedRange<Double> = 0...1

    /// Widest magnitude a backend metric may carry before it is treated as
    /// corrupt rather than as data. Roam's metrics are miles, minutes, and
    /// miles per hour; nothing legitimate approaches this bound.
    static let metricMagnitudeLimit: Double = 1e9

    /// Clamps into `range`, substituting `fallback` for a non-finite value.
    static func clamped(
        _ value: Double,
        to range: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Clamps into `0...1`. A non-finite value carries no information, so it
    /// collapses to `fallback` rather than to an arbitrary endpoint.
    static func unitFraction(_ value: Double, fallback: Double = 0) -> Double {
        clamped(value, to: unitRange, fallback: fallback)
    }

    /// `Int` conversion that saturates instead of trapping. `Int(_: Double)`
    /// is a runtime trap for `NaN`, infinity, and anything beyond `Int`'s
    /// range, so no untrusted `Double` may reach it directly.
    static func roundedInt(
        _ value: Double,
        rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero,
        fallback: Int = 0
    ) -> Int {
        guard value.isFinite else { return fallback }
        let rounded = value.rounded(rule)
        // `Double(Int.max)` rounds *up* to 2^63, so the upper bound is strict.
        guard rounded >= Double(Int.min) else { return Int.min }
        guard rounded < Double(Int.max) else { return Int.max }
        return Int(rounded)
    }

    /// A backend metric that is finite and within a plausible magnitude, or
    /// `nil`. Callers fall back to their own derived value when this returns
    /// `nil`, which is more honest than clamping nonsense into range.
    static func metric(_ value: Double) -> Double? {
        guard value.isFinite, abs(value) <= metricMagnitudeLimit else { return nil }
        return value
    }

    /// Drops every metric that fails `metric(_:)`. Returns `nil` when the input
    /// was `nil` so "absent" and "present but empty" stay distinguishable.
    static func metrics(_ values: [String: Double]?) -> [String: Double]? {
        values?.compactMapValues(metric)
    }
}

// MARK: - Request

struct RouteCoordinateEndpoint: Codable, Hashable {
    let latitude: Double
    let longitude: Double
}

enum RouteRequestEndpoint: Encodable {
    case address(String)
    case coordinate(RouteCoordinateEndpoint)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .address(let address):
            var container = encoder.singleValueContainer()
            try container.encode(address)
        case .coordinate(let coordinate):
            try coordinate.encode(to: encoder)
        }
    }
}

struct RouteDifficultyRequest: Encodable {
    let origin: RouteRequestEndpoint
    let destination: RouteRequestEndpoint
    /// Omitted when analyzing "right now": by the time a timestamp captured
    /// on-device reaches Google's Routes API, network and queueing latency
    /// can put it in the past, which Google rejects outright. Leaving it out
    /// tells the provider to use live conditions instead of failing.
    let departureTime: String?
    /// The driver's selected local clock time, independent from server timezone.
    let departureLocalMinutes: Int
    let includeAlternates: Bool
    let continuousDriveMinutes: Double?
}

/// A time-window comparison intentionally contains only route inputs. The
/// phone's saved driving history stays on-device and is never part of this
/// request.
struct DepartureComparisonRequest: Encodable {
    let origin: String
    let destination: String
    let candidates: [DepartureComparisonCandidate]
}

struct DepartureComparisonCandidate: Codable, Identifiable, Hashable {
    let id: String
    let departureTime: String
    let departureLocalMinutes: Int
}

// MARK: - Response

struct RouteDifficultyResponse: Decodable {
    let primaryRoute: ScoredRoute
    let alternateRoutes: [ScoredRoute]
}

struct DepartureComparisonResponse: Decodable {
    let candidates: [DepartureComparisonCandidateResult]
}

struct DepartureComparisonCandidateResult: Decodable, Identifiable, Hashable {
    let id: String
    let departureTime: String
    let departureLocalMinutes: Int
    let route: ScoredRoute?
    let error: DepartureComparisonError?

    var departureDate: Date? {
        ISO8601DateFormatter().date(from: departureTime)
    }
}

struct DepartureComparisonError: Decodable, Hashable {
    let message: String
}

/// Pure calendar logic for the automatic before, selected, and after route
/// comparison. It keeps the server's timestamp and the driver's local clock
/// minutes separate, which matters at midnight and across daylight saving.
enum DepartureComparisonWindowBuilder {
    static func makeCandidates(
        selectedDeparture: Date,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        formatter: ISO8601DateFormatter = ISO8601DateFormatter()
    ) -> [DepartureComparisonCandidate] {
        let oneHourEarlier = calendar.date(byAdding: .hour, value: -1, to: selectedDeparture)
            ?? selectedDeparture
        let oneHourLater = calendar.date(byAdding: .hour, value: 1, to: selectedDeparture)
            ?? selectedDeparture

        let earlier: Date
        if oneHourEarlier > now {
            earlier = oneHourEarlier
        } else {
            let startOfCurrentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
            // The replacement must be a genuinely distinct comparison row.
            // For example, when the selected time is exactly the next hour,
            // the first future hourly slot would otherwise duplicate it.
            var replacement = calendar.date(byAdding: .hour, value: 1, to: startOfCurrentHour) ?? now
            while replacement <= now ||
                sameMoment(replacement, selectedDeparture) ||
                sameMoment(replacement, oneHourLater) {
                replacement = calendar.date(byAdding: .hour, value: 1, to: replacement) ?? replacement.addingTimeInterval(3_600)
            }
            earlier = replacement
        }

        return [
            candidate(id: "earlier", date: earlier, calendar: calendar, formatter: formatter),
            candidate(id: "selected", date: selectedDeparture, calendar: calendar, formatter: formatter),
            candidate(id: "later", date: oneHourLater, calendar: calendar, formatter: formatter)
        ]
    }

    static func localMinutes(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return max(0, min(1_439, (components.hour ?? 0) * 60 + (components.minute ?? 0)))
    }

    private static func candidate(
        id: String,
        date: Date,
        calendar: Calendar,
        formatter: ISO8601DateFormatter
    ) -> DepartureComparisonCandidate {
        DepartureComparisonCandidate(
            id: id,
            departureTime: formatter.string(from: date),
            departureLocalMinutes: localMinutes(for: date, calendar: calendar)
        )
    }

    private static func sameMoment(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) < 1
    }
}

/// The time comparison only calls a window calm when every required measured
/// input is present. A missing provider signal is deliberately unavailable,
/// not silently treated as calm.
enum DepartureComparisonRanking {
    static func calmestCandidateID(in results: [DepartureComparisonCandidateResult]) -> String? {
        let usable = results.compactMap { result -> DepartureComparisonCandidateResult? in
            guard result.route != nil, hasComparableConditions(result) else { return nil }
            return result
        }
        guard usable.count == results.count, usable.count >= 2 else { return nil }

        return usable.min { lhs, rhs in
            guard let left = lhs.route, let right = rhs.route else { return false }
            let leftLoad = comparisonLoad(for: left)
            let rightLoad = comparisonLoad(for: right)
            if leftLoad != rightLoad { return leftLoad < rightLoad }
            if left.score != right.score { return left.score < right.score }
            if left.durationSeconds != right.durationSeconds { return left.durationSeconds < right.durationSeconds }
            return lhs.id < rhs.id
        }?.id
    }

    static func hasComparableConditions(_ result: DepartureComparisonCandidateResult) -> Bool {
        guard let route = result.route else { return false }
        let demands = route.routeDemands ?? []
        let trafficAvailable = demands.first(where: { $0.kind == .traffic })?.available == true
        let nightAvailable = demands.first(where: { $0.kind == .afterDark })?.available == true
        let weatherAvailable = route.conditions?.weather.available == true
        return trafficAvailable && nightAvailable && weatherAvailable
    }

    static func comparisonLoad(for route: ScoredRoute) -> Double {
        let demands = route.routeDemands ?? []
        func intensity(_ kind: RouteDemandKind) -> Double {
            demands.first(where: { $0.kind == kind && $0.available })?.intensity ?? 0
        }

        return intensity(.traffic) * 0.45
            + intensity(.afterDark) * 0.30
            + intensity(.weatherVisibility) * 0.25
    }
}

struct ScoredRoute: Decodable, Identifiable, Hashable {
    // Google route polylines commonly share their opening segment. The complete
    // encoded polyline is needed to keep SwiftUI identities distinct.
    var id: String { polyline }

    let score: Double
    let uncalibratedScore: Double?
    let label: DifficultyLabel
    let reasons: [String]
    let breakdown: DifficultyBreakdown
    let contributions: [FactorContribution]?
    let uncertainty: ScoreUncertainty?
    let hotspots: [SegmentHotspot]?
    let conditions: RouteConditions?
    let modelVersion: String?
    let distanceMeters: Int
    let durationSeconds: Int
    let staticDurationSeconds: Int
    let trafficDelaySeconds: Int
    let polyline: String
    let bounds: RouteBounds
    let scoreDelta: Double?
    /// A semantic, evidence-backed description of what this route asks of a
    /// driver. It is optional while older backend deployments are still in use.
    let routeDemands: [RouteDemand]?

    func hash(into hasher: inout Hasher) {
        hasher.combine(polyline)
    }

    static func == (lhs: ScoredRoute, rhs: ScoredRoute) -> Bool {
        lhs.polyline == rhs.polyline
    }
}

// MARK: - Route Readiness

/// Stable identifiers emitted by the route-analysis service. Keep these
/// identifiers separate from display copy: a planned practice drive stores only
/// the identifier and its factual route evidence, never an address or polyline.
enum RouteDemandKind: String, Codable, CaseIterable, Hashable {
    case afterDark
    case fastRoads
    case merges
    case complexIntersections
    case weatherVisibility
    case sustainedDrive
    case traffic
    case roadConditions

    var defaultTitle: String {
        switch self {
        case .afterDark: "After-dark driving"
        case .fastRoads: "Fast roads"
        case .merges: "Merges"
        case .complexIntersections: "Complex intersections"
        case .weatherVisibility: "Weather and visibility"
        case .sustainedDrive: "Sustained drive"
        case .traffic: "Traffic"
        case .roadConditions: "Road conditions"
        }
    }
}

enum RouteDemandLevel: String, Codable, Hashable {
    case low
    case moderate
    case high

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "low", "minimal": self = .low
        case "moderate", "medium", "elevated": self = .moderate
        case "high", "severe": self = .high
        default:
            // The numeric intensity remains available to the UI and readiness
            // engine even if a newer server introduces a display level.
            self = .moderate
        }
    }
}

/// A normalized distance range along the planned route's overview-polyline
/// geometry. The backend emits it only when its step mapping can be verified
/// against that same geometry. These values are held only with the in-memory
/// plan while a practice drive is recorded; saved history stores coverage
/// percentages, never route geometry.
struct RouteDemandCoverageRange: Codable, Hashable {
    let startFraction: Double
    let endFraction: Double

    init(startFraction: Double, endFraction: Double) {
        self.startFraction = UntrustedNumber.unitFraction(startFraction)
        self.endFraction = UntrustedNumber.unitFraction(endFraction)
    }

    /// The synthesized `Decodable` would assign both stored properties
    /// directly and skip the clamp above, which is exactly backwards: decoding
    /// *is* the untrusted path. Routing the decoded values back through the
    /// designated initializer keeps one set of invariants. `Encodable` stays
    /// synthesized, so the encoded key names are unchanged.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            startFraction: try container.decode(Double.self, forKey: .startFraction),
            endFraction: try container.decode(Double.self, forKey: .endFraction)
        )
    }

    var normalized: RouteDemandCoverageRange {
        startFraction <= endFraction
            ? self
            : RouteDemandCoverageRange(startFraction: endFraction, endFraction: startFraction)
    }
}

/// A verified route characteristic returned by the backend. `evidence` is a
/// concise factual sentence, such as "42% of the route is on major roads.".
struct RouteDemand: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let intensity: Double
    let level: RouteDemandLevel
    let evidence: String
    let available: Bool
    /// Factual numeric requirements (for example, estimated 60+ mph miles).
    /// Missing values simply keep older backend responses compatible.
    let metrics: [String: Double]?
    /// Factual route portions that contribute to the demand when the routing
    /// provider can identify them. This is optional for older responses and
    /// unavailable route characteristics.
    let coverageRanges: [RouteDemandCoverageRange]?

    init(
        id: String,
        title: String? = nil,
        intensity: Double,
        level: RouteDemandLevel,
        evidence: String,
        available: Bool,
        metrics: [String: Double]? = nil,
        coverageRanges: [RouteDemandCoverageRange]? = nil
    ) {
        self.id = id
        self.title = title ?? RouteDemandKind(rawValue: id)?.defaultTitle ?? id
        self.intensity = UntrustedNumber.unitFraction(intensity)
        self.level = level
        self.evidence = evidence
        self.available = available
        // A metric outside a plausible magnitude is dropped rather than
        // clamped: readiness copy falls back to a route-derived value, which is
        // truthful, where a clamped 1e300 would be invented data.
        self.metrics = UntrustedNumber.metrics(metrics)
        self.coverageRanges = coverageRanges?.map(\.normalized)
    }

    /// Explicit decoding so the clamping above also applies to server and
    /// persisted JSON. The keys match the synthesized `CodingKeys`, and
    /// `Encodable` remains synthesized, so stored data stays readable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            intensity: try container.decode(Double.self, forKey: .intensity),
            level: try container.decode(RouteDemandLevel.self, forKey: .level),
            evidence: try container.decode(String.self, forKey: .evidence),
            available: try container.decode(Bool.self, forKey: .available),
            metrics: try container.decodeIfPresent([String: Double].self, forKey: .metrics),
            coverageRanges: try container.decodeIfPresent(
                [RouteDemandCoverageRange].self,
                forKey: .coverageRanges
            )
        )
    }

    var kind: RouteDemandKind? {
        RouteDemandKind(rawValue: id)
    }
}

struct FactorContribution: Decodable, Identifiable {
    var id: String { factor }
    let factor: String
    let label: String
    let value: Double
    let weight: Double
    let contribution: Double
    let share: Double
}

enum ScoreEvidenceLevel: String, Decodable {
    case limited
    case partial
    case wellSupported

    var title: String {
        switch self {
        case .limited: "Limited evidence"
        case .partial: "Partial evidence"
        case .wellSupported: "Well-supported inputs"
        }
    }
}

enum ScoreEvidenceSignal: String, Decodable, CaseIterable {
    case routeGeometry
    case trafficTiming
    case speedLimits
    case weather
    case roadMetadata
    case turnControls

    var title: String {
        switch self {
        case .routeGeometry: "route geometry"
        case .trafficTiming: "traffic timing"
        case .speedLimits: "posted speed limits"
        case .weather: "weather"
        case .roadMetadata: "road details"
        case .turnControls: "turn controls"
        }
    }
}

enum PredictiveValidationStatus: String, Decodable {
    case notValidated
}

/// Input provenance for a route score. This is deliberately not a probability,
/// personal readiness assessment, or prediction of safety.
struct ScoreEvidence: Decodable {
    let schemaVersion: String
    let inputCoverage: Double
    let level: ScoreEvidenceLevel
    let predictiveValidation: PredictiveValidationStatus
    let signalCoverage: [ScoreEvidenceSignal: Double]
    let verifiedSignals: [ScoreEvidenceSignal]
    let missingSignals: [ScoreEvidenceSignal]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, inputCoverage, level, predictiveValidation
        case signalCoverage, verifiedSignals, missingSignals
    }

    init(
        schemaVersion: String,
        inputCoverage: Double,
        level: ScoreEvidenceLevel,
        predictiveValidation: PredictiveValidationStatus,
        signalCoverage: [ScoreEvidenceSignal: Double],
        verifiedSignals: [ScoreEvidenceSignal],
        missingSignals: [ScoreEvidenceSignal]
    ) {
        self.schemaVersion = schemaVersion
        self.inputCoverage = inputCoverage
        self.level = level
        self.predictiveValidation = predictiveValidation
        self.signalCoverage = signalCoverage
        self.verifiedSignals = verifiedSignals
        self.missingSignals = missingSignals
    }

    // `Dictionary`'s synthesized `Decodable` conformance only reads a JSON
    // object for `String`/`Int` keys; a `RawRepresentable` enum key like
    // `ScoreEvidenceSignal` otherwise expects a flat `[key, value, ...]`
    // array and fails to decode the server's keyed object. Unknown keys
    // (a newer signal type from the server) are dropped rather than
    // failing the whole response.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        inputCoverage = try container.decode(Double.self, forKey: .inputCoverage)
        level = try container.decode(ScoreEvidenceLevel.self, forKey: .level)
        predictiveValidation = try container.decode(PredictiveValidationStatus.self, forKey: .predictiveValidation)
        let rawSignalCoverage = try container.decode([String: Double].self, forKey: .signalCoverage)
        signalCoverage = rawSignalCoverage.reduce(into: [:]) { result, entry in
            guard let signal = ScoreEvidenceSignal(rawValue: entry.key) else { return }
            result[signal] = entry.value
        }
        verifiedSignals = try container.decode([ScoreEvidenceSignal].self, forKey: .verifiedSignals)
        missingSignals = try container.decode([ScoreEvidenceSignal].self, forKey: .missingSignals)
    }

    var verifiedInputCount: Int { verifiedSignals.count }
    var totalInputCount: Int { ScoreEvidenceSignal.allCases.count }
    var unavailableInputTitles: String {
        missingSignals.map(\.title).joined(separator: ", ")
    }
}

struct ScoreUncertainty: Decodable {
    let low: Double
    let high: Double
    /// Legacy backend compatibility only. It is not rendered as a probability.
    let confidence: Double
    let spread: Double
    let evidence: ScoreEvidence?

    var formattedBand: String {
        String(format: "%.1f to %.1f", low, high)
    }
}

struct SegmentHotspot: Decodable, Identifiable {
    var id: Int { segmentIndex }
    let segmentIndex: Int
    let difficulty: Double
    let cumulativeSecondsFromStart: Double
    let label: String?
}

struct DifficultyBreakdown: Decodable {
    let speed: Double?
    let merges: Double?
    let turns: Double?
    let traffic: Double
    let length: Double?
    let fatigue: Double?
    let weather: Double?
    let road: Double?
    let highway: Double
    let maneuvers: Double
    let navDensity: Double
    let effort: Double

    var items: [(key: String, title: String, value: Double)] {
        if speed != nil {
            var rows: [(key: String, title: String, value: Double)] = [
                ("speed", "Speed", speed ?? highway),
                ("merges", "Merges", merges ?? 0),
                ("turns", "Turns", turns ?? maneuvers),
                ("traffic", "Traffic", traffic),
                ("length", "Length", length ?? effort),
                ("fatigue", "Drive Load", fatigue ?? 0)
            ]
            if let weather, weather > 0.02 {
                rows.append(("weather", "Weather", weather))
            }
            if let road, road > 0.02 {
                rows.append(("road", "Road Conditions", road))
            }
            return rows
        }
        return [
            ("highway", "Road Type", highway),
            ("maneuvers", "Turns", maneuvers),
            ("traffic", "Traffic", traffic),
            ("navDensity", "Navigation", navDensity),
            ("effort", "Drive Length", effort)
        ]
    }
}

// MARK: - Live Conditions

struct RouteConditions: Decodable {
    let weather: WeatherConditions
    let road: RoadConditions
    let turns: TurnExposure
    let sources: [String]
}

struct WeatherConditions: Decodable {
    let available: Bool
    let condition: String
    let severity: Double
    let precipIntensity: Double
    let snowRisk: Double
    let windSeverity: Double
    let lowVisibilityRisk: Double
    let icyRisk: Double
    let temperatureF: Double
    let windGustMph: Double
    let visibilityMiles: Double

    var systemImage: String {
        switch condition.lowercased() {
        case "clear": return "sun.max.fill"
        case "partly cloudy": return "cloud.sun.fill"
        case "overcast": return "cloud.fill"
        case "fog": return "cloud.fog.fill"
        case "drizzle": return "cloud.drizzle.fill"
        case "rain": return "cloud.rain.fill"
        case "freezing rain": return "cloud.sleet.fill"
        case "snow": return "cloud.snow.fill"
        case "thunderstorm": return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    var severityLabel: String {
        switch severity {
        case ..<0.15: return "Good"
        case ..<0.4: return "Fair"
        case ..<0.7: return "Poor"
        default: return "Severe"
        }
    }
}

struct RoadConditions: Decodable {
    let available: Bool
    let avgLanes: Double
    let narrowRoadShare: Double
    let majorRoadShare: Double
    let unpavedShare: Double
    let roadSizeScore: Double
    let constructionZones: Int
    let dominantRoadClass: String

    var dominantRoadLabel: String {
        switch dominantRoadClass {
        case "motorway", "motorway_link": return "Interstate / freeway"
        case "trunk", "trunk_link": return "Major highway"
        case "primary", "primary_link": return "Primary road"
        case "secondary", "secondary_link": return "Secondary road"
        case "tertiary", "tertiary_link": return "Local connector"
        case "residential": return "Residential streets"
        case "living_street", "service": return "Small access roads"
        case "track": return "Unpaved track"
        default: return "Mixed roads"
        }
    }
}

struct TurnExposure: Decodable {
    let available: Bool
    let unprotectedLeftTurns: Int
    let protectedLeftTurns: Int
    let unprotectedTurnShare: Double
}

struct RouteBounds: Decodable {
    let southwest: Coordinate
    let northeast: Coordinate

    var mapRect: (southwest: CLLocationCoordinate2D, northeast: CLLocationCoordinate2D) {
        (
            southwest: CLLocationCoordinate2D(latitude: southwest.latitude, longitude: southwest.longitude),
            northeast: CLLocationCoordinate2D(latitude: northeast.latitude, longitude: northeast.longitude)
        )
    }
}

struct Coordinate: Decodable {
    let latitude: Double
    let longitude: Double

    enum CodingKeys: String, CodingKey {
        case latitude = "lat"
        case longitude = "lng"
    }
}

enum DifficultyLabel: String, Codable, CaseIterable {
    case veryEasy = "Very Easy"
    case easy = "Easy"
    case moderate = "Moderate"
    case hard = "Hard"
    case veryHard = "Very Hard"

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let match = DifficultyLabel(rawValue: raw) {
            self = match
            return
        }
        switch raw.lowercased() {
        case "very easy": self = .veryEasy
        case "easy": self = .easy
        case "moderate": self = .moderate
        case "hard": self = .hard
        case "very hard": self = .veryHard
        default: self = .moderate
        }
    }
}

// MARK: - Formatting

extension ScoredRoute {
    var distanceMiles: Double {
        Double(distanceMeters) / 1609.344
    }

    var formattedDistance: String {
        String(format: "%.1f mi", distanceMiles)
    }

    var formattedDuration: String {
        Self.formatDuration(seconds: durationSeconds)
    }

    var formattedStaticDuration: String {
        Self.formatDuration(seconds: staticDurationSeconds)
    }

    var formattedDelay: String? {
        guard trafficDelaySeconds > 0 else { return nil }
        return "+\(Self.formatDuration(seconds: trafficDelaySeconds))"
    }

    /// A route demand score is shown without a pseudo-precision interval. The
    /// evidence card explains exactly which inputs were available instead.
    var formattedScore: String {
        String(format: "%.1f", score)
    }

    static func formatDuration(seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes) min"
    }
}

extension DifficultyLabel {
    var colorName: String {
        switch self {
        case .veryEasy: return "DifficultyVeryEasy"
        case .easy: return "DifficultyEasy"
        case .moderate: return "DifficultyModerate"
        case .hard: return "DifficultyHard"
        case .veryHard: return "DifficultyVeryHard"
        }
    }
}
