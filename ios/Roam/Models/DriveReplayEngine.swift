import CoreLocation
import Foundation

/// A local replay item for one recorded coaching event. A coordinate is only
/// available when the event timestamp falls inside a verified continuous GPS
/// segment. This deliberately does not bridge tracking gaps.
struct DriveReplayMoment: Identifiable, Hashable {
    let id: UUID
    let kind: DrivingEventKind
    let timestamp: Date
    let elapsedSinceDriveStart: TimeInterval
    let source: DrivingEventSource
    let coordinate: DriveCoordinate?
    /// The closest accepted GPS speed to the event. It is nil when the event
    /// could not be placed on a continuous trace.
    let nearestSpeedMetersPerSecond: Double?
    /// Progress through measured continuous-trace distance, in the range
    /// 0...1. It is intentionally nil when a location could not be verified.
    let routeProgress: Double?

    var locationAvailable: Bool { coordinate != nil }

    init(
        event: DrivingEvent,
        startedAt: Date,
        coordinate: DriveCoordinate?,
        nearestSpeedMetersPerSecond: Double?,
        routeProgress: Double?
    ) {
        id = event.id
        kind = event.kind
        timestamp = event.timestamp
        elapsedSinceDriveStart = max(0, event.timestamp.timeIntervalSince(startedAt))
        source = event.source
        self.coordinate = coordinate
        self.nearestSpeedMetersPerSecond = nearestSpeedMetersPerSecond
        self.routeProgress = routeProgress
    }
}

/// Builds a replay solely from saved local route points and coaching events.
/// It purposefully uses `DriveExperienceEngine.validTraceSegments` so a map
/// never draws or interpolates through an unmeasured GPS discontinuity.
enum DriveReplayEngine {
    static func moments(for drive: RecordedDrive) -> [DriveReplayMoment] {
        let segments = DriveExperienceEngine.validTraceSegments(for: drive.route)
        let totalDistance = segments.reduce(0) { $0 + $1.distanceMeters }
        let indexedSegments = indexed(segments)

        return drive.score.events
            .sorted(by: chronologicalOrder)
            .map { event in
                guard let indexedSegment = indexedSegments.first(where: {
                    event.timestamp >= $0.segment.start.timestamp &&
                        event.timestamp <= $0.segment.end.timestamp
                }) else {
                    return DriveReplayMoment(
                        event: event,
                        startedAt: drive.startedAt,
                        coordinate: nil,
                        nearestSpeedMetersPerSecond: nil,
                        routeProgress: nil
                    )
                }

                let segment = indexedSegment.segment
                let fraction = interpolationFraction(for: event.timestamp, within: segment)
                let interpolatedCoordinate = interpolate(
                    from: segment.start.coordinate,
                    to: segment.end.coordinate,
                    fraction: fraction
                )
                let coordinate = validCoordinate(event.coordinate) ?? interpolatedCoordinate
                let nearestSpeed = fraction <= 0.5
                    ? segment.start.speedMetersPerSecond
                    : segment.end.speedMetersPerSecond
                let progress = totalDistance > 0
                    ? min(1, max(0, (indexedSegment.distanceBefore + segment.distanceMeters * fraction) / totalDistance))
                    : nil

                return DriveReplayMoment(
                    event: event,
                    startedAt: drive.startedAt,
                    coordinate: coordinate,
                    nearestSpeedMetersPerSecond: nearestSpeed,
                    routeProgress: progress
                )
            }
    }

    private struct IndexedSegment {
        let segment: DriveTraceSegment
        let distanceBefore: CLLocationDistance
    }

    private static func indexed(_ segments: [DriveTraceSegment]) -> [IndexedSegment] {
        var distanceBefore: CLLocationDistance = 0
        return segments.map { segment in
            defer { distanceBefore += segment.distanceMeters }
            return IndexedSegment(segment: segment, distanceBefore: distanceBefore)
        }
    }

    private static func chronologicalOrder(_ lhs: DrivingEvent, _ rhs: DrivingEvent) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func interpolationFraction(
        for timestamp: Date,
        within segment: DriveTraceSegment
    ) -> Double {
        guard segment.duration > 0 else { return 0 }
        return min(
            1,
            max(0, timestamp.timeIntervalSince(segment.start.timestamp) / segment.duration)
        )
    }

    private static func interpolate(
        from start: DriveCoordinate,
        to end: DriveCoordinate,
        fraction: Double
    ) -> DriveCoordinate {
        DriveCoordinate(
            CLLocationCoordinate2D(
                latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                longitude: start.longitude + (end.longitude - start.longitude) * fraction
            )
        )
    }

    private static func validCoordinate(_ coordinate: DriveCoordinate?) -> DriveCoordinate? {
        guard let coordinate,
              CLLocationCoordinate2DIsValid(coordinate.clLocationCoordinate) else {
            return nil
        }
        return coordinate
    }
}
