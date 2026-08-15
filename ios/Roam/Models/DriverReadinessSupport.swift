import CoreLocation
import Foundation

/// Result of the in-memory route-practice matcher. It is deliberately not
/// Codable: only privacy-safe verified exposure values are persisted.
struct PracticeRouteCoverage {
    let overallCoverage: Double
    let longestContinuousCoverage: Double
    let originCoverage: Double
    let destinationCoverage: Double
    let demandExposures: [VerifiedDemandExposure]
}

struct HistoryDrive {
    let drive: RecordedDrive
    let summary: DriveExperienceSummary
}

struct ExposureObservation {
    let miles: Double
    let duration: TimeInterval
    let date: Date
    let localDayKey: String
    let episodeDuration: TimeInterval
    let episodeMiles: Double
}

struct ExposureAccumulator {
    var observations: [ExposureObservation] = []

    mutating func add(
        miles: Double,
        duration: TimeInterval,
        date: Date,
        localDayKey: String,
        episodeDuration: TimeInterval = 0,
        episodeMiles: Double = 0
    ) {
        guard miles > 0 || duration > 0 else { return }
        observations.append(ExposureObservation(
            miles: max(0, miles),
            duration: max(0, duration),
            date: date,
            localDayKey: localDayKey,
            episodeDuration: max(0, episodeDuration),
            episodeMiles: max(0, episodeMiles)
        ))
    }

    func makeExposure(
        referenceDate: Date,
        configuration: DriverReadinessEngine.Configuration
    ) -> DriverExperienceExposure {
        let recentThreshold = configuration.recentWindowDays * 86_400
        let recent = observations.filter {
            let age = referenceDate.timeIntervalSince($0.date)
            return age >= 0 && age <= recentThreshold
        }
        let recentMiles = recent.reduce(0) { $0 + $1.miles }
        let days = Set(observations.map(\.localDayKey))
        let recentDays = Set(recent.map(\.localDayKey))
        let halfLifeSeconds = configuration.experienceHalfLifeDays * 86_400
        let effectiveMiles = observations.reduce(0) { partial, observation in
            let age = max(0, referenceDate.timeIntervalSince(observation.date))
            return partial + observation.miles * pow(0.5, age / halfLifeSeconds)
        }
        let episodes = observations.compactMap { observation -> DriverExperienceEpisode? in
            guard observation.episodeDuration > 0 else { return nil }
            return DriverExperienceEpisode(
                duration: observation.episodeDuration,
                miles: observation.episodeMiles,
                recordedAt: observation.date,
                localDayKey: observation.localDayKey
            )
        }
        return DriverExperienceExposure(
            miles: observations.reduce(0) { $0 + $1.miles },
            effectiveMiles: effectiveMiles,
            duration: observations.reduce(0) { $0 + $1.duration },
            sessionCount: observations.count,
            distinctDayCount: days.count,
            recentMiles: recentMiles,
            recentSessionCount: recent.count,
            recentDistinctDayCount: recentDays.count,
            lastRecordedAt: observations.map(\.date).max(),
            longestEpisodeDuration: observations.map(\.episodeDuration).max() ?? 0,
            longestEpisodeMiles: observations.map(\.episodeMiles).max() ?? 0,
            episodes: episodes
        )
    }
}

struct WeightedScoreAccumulator {
    private var totalWeight = 0.0
    private var totalScore = 0.0
    private var recentWeight = 0.0
    private var recentScore = 0.0

    mutating func add(score: Double, miles: Double, date: Date, referenceDate: Date, recentWindowDays: Double) {
        let weight = min(12, max(1, miles))
        totalWeight += weight
        totalScore += score * weight
        if referenceDate.timeIntervalSince(date) <= recentWindowDays * 86_400 {
            recentWeight += weight
            recentScore += score * weight
        }
    }

    var average: Double? { totalWeight > 0 ? totalScore / totalWeight : nil }
    var recentAverage: Double? { recentWeight > 0 ? recentScore / recentWeight : nil }
}

struct BehaviorAccumulator {
    private var measuredMiles = 0.0
    private var recentMeasuredMiles = 0.0
    private var weightedEvents = 0.0
    private var recentWeightedEvents = 0.0
    private var highSpeedMiles = 0.0
    private var highSpeedEvents = 0
    private var nightMiles = 0.0
    private var nightEvents = 0
    private var hardBrakes = 0
    private var sharpCorners = 0
    private var scoreAccumulator = WeightedScoreAccumulator()

    mutating func add(
        summary: DriveExperienceSummary,
        score: Double,
        miles: Double,
        date: Date,
        referenceDate: Date,
        recentWindowDays: Double
    ) {
        let events = summary.eventExposure
        let eventWeight = events.weightedCoachingEvents
        measuredMiles += miles
        weightedEvents += eventWeight
        highSpeedMiles += summary.speedExposure.milesAt45Plus
        highSpeedEvents += events.highSpeedEventCount
        nightMiles += summary.lightingExposure.afterDarkMiles
        nightEvents += events.afterDarkEventCount
        hardBrakes += events.hardBrakeCount
        sharpCorners += events.sharpCornerCount
        scoreAccumulator.add(score: score, miles: miles, date: date, referenceDate: referenceDate, recentWindowDays: recentWindowDays)
        if referenceDate.timeIntervalSince(date) <= recentWindowDays * 86_400 {
            recentMeasuredMiles += miles
            recentWeightedEvents += eventWeight
        }
    }

    func makeProfile() -> DrivingBehaviorProfile {
        func rate(_ amount: Double, miles: Double) -> Double? {
            guard miles >= 0.5 else { return nil }
            return amount / miles * 10
        }
        return DrivingBehaviorProfile(
            measuredMiles: measuredMiles,
            recentMeasuredMiles: recentMeasuredMiles,
            weightedEventRatePerTenMiles: rate(weightedEvents, miles: measuredMiles),
            recentWeightedEventRatePerTenMiles: rate(recentWeightedEvents, miles: recentMeasuredMiles),
            highSpeedEventRatePerTenMiles: rate(Double(highSpeedEvents), miles: highSpeedMiles),
            afterDarkEventRatePerTenMiles: rate(Double(nightEvents), miles: nightMiles),
            weightedAverageScore: scoreAccumulator.average,
            recentWeightedAverageScore: scoreAccumulator.recentAverage,
            hardBrakesPerTenMiles: rate(Double(hardBrakes), miles: measuredMiles),
            sharpCornersPerTenMiles: rate(Double(sharpCorners), miles: measuredMiles)
        )
    }
}

extension Sequence where Element: Identifiable {
    /// Non-trapping counterpart to `Dictionary(uniqueKeysWithValues:)`.
    ///
    /// Route demands and readiness insights are keyed by server-supplied ids,
    /// so uniqueness is not a property the client may assume. The first
    /// occurrence wins, which keeps the result deterministic for a given input
    /// order.
    func keyedByID() -> [Element.ID: Element] {
        Dictionary(map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

extension Array where Element: Identifiable {
    /// Keeps the first element per id, preserving order. Applied where a list
    /// mixes locally generated entries with server-supplied ones.
    func uniquedByID() -> [Element] {
        var seenIDs = Set<Element.ID>()
        return filter { seenIDs.insert($0.id).inserted }
    }
}

struct RouteProgressSample {
    let coordinate: DriveCoordinate
    let fraction: Double
    let bearing: Double
}

struct OrderedRouteMatches {
    let flags: [Bool]
    let traceIndices: [Int?]
    let continuityGroups: [Int?]
}

/// A Foundation/CoreLocation-only Google encoded-polyline decoder. Keeping it
/// here lets readiness checks run without importing the SwiftUI map component.
enum RoutePolylineDecoder {
    /// Widest shift a well-formed 32-bit varint component can reach. A valid
    /// component is at most seven 5-bit chunks, so anything beyond this is a
    /// malformed component rather than a long one.
    private static let maximumComponentShift: Int32 = 30

    static func decode(_ encoded: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var index = encoded.startIndex
        var latitude: Int32 = 0
        var longitude: Int32 = 0
        while index < encoded.endIndex {
            // Accumulation reports overflow instead of trapping: a malformed
            // polyline must degrade to a truncated result, never kill the
            // process. Wrapping (`&+`) is not an option either — it would hand
            // the matcher a plausible-looking coordinate on the far side of the
            // globe. Overflow takes the same exit as a bad component.
            guard let latitudeDelta = decodeComponent(from: encoded, index: &index) else { break }
            let (accumulatedLatitude, latitudeOverflowed) = latitude.addingReportingOverflow(latitudeDelta)
            guard !latitudeOverflowed else { break }
            latitude = accumulatedLatitude
            guard let longitudeDelta = decodeComponent(from: encoded, index: &index) else { break }
            let (accumulatedLongitude, longitudeOverflowed) = longitude.addingReportingOverflow(longitudeDelta)
            guard !longitudeOverflowed else { break }
            longitude = accumulatedLongitude
            // A component can be in range and still accumulate past the poles
            // or the antimeridian. Such a point is not a location, and feeding
            // it to the route matcher would silently corrupt familiarity, so it
            // ends the decode on the same path as a bad component.
            let coordinate = CLLocationCoordinate2D(
                latitude: Double(latitude) / 1e5,
                longitude: Double(longitude) / 1e5
            )
            guard CLLocationCoordinate2DIsValid(coordinate) else { break }
            coordinates.append(coordinate)
        }
        return coordinates
    }

    private static func decodeComponent(from encoded: String, index: inout String.Index) -> Int32? {
        var result: Int32 = 0
        var shift: Int32 = 0
        var byte: Int32
        repeat {
            guard index < encoded.endIndex, shift <= maximumComponentShift else { return nil }
            let scalar = encoded[index].asciiValue.map(Int32.init) ?? 0
            index = encoded.index(after: index)
            byte = scalar - 63
            result |= (byte & 0x1F) << shift
            shift += 5
        } while byte >= 0x20
        return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
    }
}
