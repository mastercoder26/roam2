import CoreLocation
import Foundation

/// A compact, private summary derived from one saved drive. It records only
/// quantities already measured by Roam; it does not infer road type,
/// weather, traffic, or intersection controls from raw GPS.
struct DriveExperienceSummary: Codable, Hashable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let traceQuality: DriveTraceQuality
    let speedExposure: DriveSpeedExposure
    let lightingExposure: DriveLightingExposure
    let eventExposure: DriveEventExposure

    var measuredMiles: Double {
        traceQuality.usableDistanceMeters / 1_609.344
    }

    var measuredMinutes: Double {
        traceQuality.usableDuration / 60
    }
}

/// Quality of the continuous GPS trace that supports the summary. Long gaps
/// are explicitly split, so a background gap cannot become invented mileage
/// or route familiarity.
struct DriveTraceQuality: Codable, Hashable {
    let usableDistanceMeters: CLLocationDistance
    let usableDuration: TimeInterval
    let longestContinuousDuration: TimeInterval
    let longestContinuousDistanceMeters: CLLocationDistance
    let validSegmentCount: Int
    let discontinuityCount: Int
    let largestGapSeconds: TimeInterval
    /// Ratio of continuous-trace distance to Roam's saved score distance.
    /// It is a diagnostic, not a claim about the physical route.
    let distanceCoverage: Double
}

/// Conservative distance credited only when both GPS samples around a trace
/// segment support the threshold. A single high GPS spike never credits a
/// whole segment as high-speed experience.
struct DriveSpeedExposure: Codable, Hashable {
    let milesAt35Plus: Double
    let milesAt45Plus: Double
    let milesAt55Plus: Double
    let milesAt60Plus: Double
    let milesAt65Plus: Double
    let longest45PlusDuration: TimeInterval
    let longest45PlusDistanceMiles: Double
    let longest55PlusDuration: TimeInterval
    let longest55PlusDistanceMiles: Double
    let longest60PlusDuration: TimeInterval
    let longest60PlusDistanceMiles: Double
    let measuredPeakSpeedMPH: Double

    private enum CodingKeys: String, CodingKey {
        case milesAt35Plus
        case milesAt45Plus
        case milesAt55Plus
        case milesAt60Plus
        case milesAt65Plus
        case longest45PlusDuration
        case longest45PlusDistanceMiles
        case longest55PlusDuration
        case longest55PlusDistanceMiles
        case longest60PlusDuration
        case longest60PlusDistanceMiles
        case measuredPeakSpeedMPH
    }

    init(
        milesAt35Plus: Double,
        milesAt45Plus: Double,
        milesAt55Plus: Double,
        milesAt60Plus: Double,
        milesAt65Plus: Double,
        longest45PlusDuration: TimeInterval,
        longest45PlusDistanceMiles: Double,
        longest55PlusDuration: TimeInterval,
        longest55PlusDistanceMiles: Double,
        longest60PlusDuration: TimeInterval,
        longest60PlusDistanceMiles: Double,
        measuredPeakSpeedMPH: Double
    ) {
        self.milesAt35Plus = milesAt35Plus
        self.milesAt45Plus = milesAt45Plus
        self.milesAt55Plus = milesAt55Plus
        self.milesAt60Plus = milesAt60Plus
        self.milesAt65Plus = milesAt65Plus
        self.longest45PlusDuration = longest45PlusDuration
        self.longest45PlusDistanceMiles = longest45PlusDistanceMiles
        self.longest55PlusDuration = longest55PlusDuration
        self.longest55PlusDistanceMiles = longest55PlusDistanceMiles
        self.longest60PlusDuration = longest60PlusDuration
        self.longest60PlusDistanceMiles = longest60PlusDistanceMiles
        self.measuredPeakSpeedMPH = measuredPeakSpeedMPH
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            milesAt35Plus: try values.decodeIfPresent(Double.self, forKey: .milesAt35Plus) ?? 0,
            milesAt45Plus: try values.decodeIfPresent(Double.self, forKey: .milesAt45Plus) ?? 0,
            milesAt55Plus: try values.decodeIfPresent(Double.self, forKey: .milesAt55Plus) ?? 0,
            milesAt60Plus: try values.decodeIfPresent(Double.self, forKey: .milesAt60Plus) ?? 0,
            milesAt65Plus: try values.decodeIfPresent(Double.self, forKey: .milesAt65Plus) ?? 0,
            longest45PlusDuration: try values.decodeIfPresent(TimeInterval.self, forKey: .longest45PlusDuration) ?? 0,
            longest45PlusDistanceMiles: try values.decodeIfPresent(Double.self, forKey: .longest45PlusDistanceMiles) ?? 0,
            longest55PlusDuration: try values.decodeIfPresent(TimeInterval.self, forKey: .longest55PlusDuration) ?? 0,
            longest55PlusDistanceMiles: try values.decodeIfPresent(Double.self, forKey: .longest55PlusDistanceMiles) ?? 0,
            longest60PlusDuration: try values.decodeIfPresent(TimeInterval.self, forKey: .longest60PlusDuration) ?? 0,
            longest60PlusDistanceMiles: try values.decodeIfPresent(Double.self, forKey: .longest60PlusDistanceMiles) ?? 0,
            measuredPeakSpeedMPH: try values.decodeIfPresent(Double.self, forKey: .measuredPeakSpeedMPH) ?? 0
        )
    }
}

/// The same fixed 8 PM–6 AM local window used by route analysis. This is a
/// clock-based exposure, not a claim about actual sunset or visibility.
struct DriveLightingExposure: Codable, Hashable {
    let afterDarkMiles: Double
    let afterDarkDuration: TimeInterval
}

/// Counts of Roam's existing coaching events. These remain observations for
/// coaching, not diagnoses of distraction or driving safety.
struct DriveEventExposure: Codable, Hashable {
    let hardBrakeCount: Int
    let rapidAccelerationCount: Int
    let sharpCornerCount: Int
    let phoneMovementCount: Int
    let fusedEventCount: Int
    let highSpeedEventCount: Int
    let afterDarkEventCount: Int

    var weightedCoachingEvents: Double {
        Double(hardBrakeCount) * 1.0 +
            Double(rapidAccelerationCount) * 0.8 +
            Double(sharpCornerCount) * 0.7 +
            Double(phoneMovementCount) * 0.25
    }
}

/// A valid, continuous section of a saved GPS trace. This is intentionally
/// internal to the readiness model: coordinate traces never leave the phone.
struct DriveTraceSegment: Hashable {
    /// Indices in the original saved route. They make continuity explicit even
    /// when a corrupt or implausible GPS pair was dropped between two valid
    /// segments with deceptively similar timestamps.
    let startIndex: Int
    let endIndex: Int
    let start: DriveRoutePoint
    let end: DriveRoutePoint
    let distanceMeters: CLLocationDistance
    let duration: TimeInterval

    /// Both endpoints must meet a threshold before a segment earns speed
    /// exposure. This is deliberately stricter than an average.
    var conservativeSpeedMetersPerSecond: Double {
        min(start.speedMetersPerSecond, end.speedMetersPerSecond)
    }

    var midpoint: Date {
        start.timestamp.addingTimeInterval(duration / 2)
    }
}

/// Pure, on-device historical-drive analysis. It can derive a current summary
/// from legacy records as well as creating a persisted summary for new drives.
enum DriveExperienceEngine {
    static let minimumSegmentGap: TimeInterval = DriveScoringEngine.minimumSampleGap
    static let maximumSegmentGap: TimeInterval = DriveScoringEngine.maximumSampleGap
    static let afterDarkStartHour = 20
    static let afterDarkEndHour = 6

    static func summarize(
        drive: RecordedDrive,
        calendar: Calendar = .current
    ) -> DriveExperienceSummary {
        let segments = validTraceSegments(for: drive.route)
        let driveCalendar = DriveExperienceEngine.calendar(for: drive, base: calendar)
        let trace = traceQuality(
            segments: segments,
            route: drive.route,
            scoredDistanceMeters: drive.score.distanceMeters
        )
        let speed = speedExposure(segments: segments)
        let lighting = lightingExposure(segments: segments, calendar: driveCalendar)
        let events = eventExposure(
            drive.score.events,
            segments: segments,
            calendar: driveCalendar
        )

        return DriveExperienceSummary(
            schemaVersion: DriveExperienceSummary.currentSchemaVersion,
            traceQuality: trace,
            speedExposure: speed,
            lightingExposure: lighting,
            eventExposure: events
        )
    }

    /// Use a persisted summary when it is current. Legacy drives are derived
    /// lazily from their local trace so no migration or history upload exists.
    static func summary(
        for drive: RecordedDrive,
        calendar: Calendar = .current
    ) -> DriveExperienceSummary {
        if let persisted = drive.experienceSummary,
           persisted.schemaVersion == DriveExperienceSummary.currentSchemaVersion {
            return persisted
        }
        return summarize(drive: drive, calendar: calendar)
    }

    /// Only adjacent, plausible GPS fixes become a trace segment. A break in
    /// recording never draws a synthetic line through the missing time.
    static func validTraceSegments(for route: [DriveRoutePoint]) -> [DriveTraceSegment] {
        guard route.count > 1 else { return [] }

        var segments: [DriveTraceSegment] = []
        for index in 1..<route.count {
            let previous = route[index - 1]
            let current = route[index]
            guard CLLocationCoordinate2DIsValid(previous.coordinate.clLocationCoordinate),
                  CLLocationCoordinate2DIsValid(current.coordinate.clLocationCoordinate),
                  previous.speedMetersPerSecond >= 0,
                  current.speedMetersPerSecond >= 0 else {
                continue
            }

            let duration = current.timestamp.timeIntervalSince(previous.timestamp)
            guard duration >= minimumSegmentGap, duration <= maximumSegmentGap else {
                continue
            }

            let distance = coordinateDistanceMeters(previous.coordinate, current.coordinate)
            guard distance.isFinite, distance > 0 else { continue }

            // Mirrors the live plausibility envelope used while recording.
            let maximumExpectedDistance = max(
                previous.speedMetersPerSecond,
                current.speedMetersPerSecond
            ) * duration * 2.4 + 80
            guard distance <= maximumExpectedDistance else { continue }

            segments.append(
                DriveTraceSegment(
                    startIndex: index - 1,
                    endIndex: index,
                    start: previous,
                    end: current,
                    distanceMeters: distance,
                    duration: duration
                )
            )
        }
        return segments
    }

    static func calendar(for drive: RecordedDrive, base: Calendar = .current) -> Calendar {
        var calendar = base
        if let identifier = drive.recordingTimeZoneIdentifier,
           let timeZone = TimeZone(identifier: identifier) {
            calendar.timeZone = timeZone
        }
        return calendar
    }

    static func isAfterDark(_ date: Date, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= afterDarkStartHour || hour < afterDarkEndHour
    }

    static func coordinateDistanceMeters(
        _ lhs: DriveCoordinate,
        _ rhs: DriveCoordinate
    ) -> CLLocationDistance {
        CLLocation(latitude: lhs.latitude, longitude: lhs.longitude).distance(
            from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude)
        )
    }

    private static func traceQuality(
        segments: [DriveTraceSegment],
        route: [DriveRoutePoint],
        scoredDistanceMeters: CLLocationDistance
    ) -> DriveTraceQuality {
        let usableDistanceMeters = segments.reduce(0) { $0 + $1.distanceMeters }
        let usableDuration = segments.reduce(0) { $0 + $1.duration }
        let gaps = zip(route, route.dropFirst()).map {
            max(0, $1.timestamp.timeIntervalSince($0.timestamp))
        }
        // Any adjacent pair that did not become a valid segment is a break.
        // This includes bad timestamps, invalid coordinates, and implausible
        // jumps—not only literal time gaps.
        let discontinuityCount = max(0, route.count - 1 - segments.count)
        let largestGap = gaps.max() ?? 0

        var longestDuration: TimeInterval = 0
        var longestDistance: CLLocationDistance = 0
        var currentDuration: TimeInterval = 0
        var currentDistance: CLLocationDistance = 0
        var lastEndIndex: Int?

        for segment in segments {
            let isContinuous = lastEndIndex == segment.startIndex
            if !isContinuous {
                currentDuration = 0
                currentDistance = 0
            }
            currentDuration += segment.duration
            currentDistance += segment.distanceMeters
            longestDuration = max(longestDuration, currentDuration)
            longestDistance = max(longestDistance, currentDistance)
            lastEndIndex = segment.endIndex
        }

        let coverage = scoredDistanceMeters > 0
            ? min(1, usableDistanceMeters / scoredDistanceMeters)
            : 0
        return DriveTraceQuality(
            usableDistanceMeters: usableDistanceMeters,
            usableDuration: usableDuration,
            longestContinuousDuration: longestDuration,
            longestContinuousDistanceMeters: longestDistance,
            validSegmentCount: segments.count,
            discontinuityCount: discontinuityCount,
            largestGapSeconds: largestGap,
            distanceCoverage: coverage
        )
    }

    private static func speedExposure(segments: [DriveTraceSegment]) -> DriveSpeedExposure {
        var at35 = 0.0
        var at45 = 0.0
        var at55 = 0.0
        var at60 = 0.0
        var at65 = 0.0
        var measuredPeak = 0.0
        var longest45 = (duration: TimeInterval(0), distance: CLLocationDistance(0))
        var longest55 = (duration: TimeInterval(0), distance: CLLocationDistance(0))
        var longest60 = (duration: TimeInterval(0), distance: CLLocationDistance(0))
        var current45 = (duration: TimeInterval(0), distance: CLLocationDistance(0))
        var current55 = (duration: TimeInterval(0), distance: CLLocationDistance(0))
        var current60 = (duration: TimeInterval(0), distance: CLLocationDistance(0))
        var previousEndIndex: Int?

        for segment in segments {
            let speedMPH = segment.conservativeSpeedMetersPerSecond * 2.236936
            measuredPeak = max(
                measuredPeak,
                max(segment.start.speedMetersPerSecond, segment.end.speedMetersPerSecond) * 2.236936
            )
            let miles = segment.distanceMeters / 1_609.344
            if speedMPH >= 35 { at35 += miles }
            if speedMPH >= 45 { at45 += miles }
            if speedMPH >= 55 { at55 += miles }
            if speedMPH >= 60 { at60 += miles }
            if speedMPH >= 65 { at65 += miles }

            let continuous = previousEndIndex == segment.startIndex
            if speedMPH >= 45 {
                if !continuous { current45 = (0, 0) }
                current45.duration += segment.duration
                current45.distance += segment.distanceMeters
                if current45.duration > longest45.duration {
                    longest45 = current45
                }
            } else {
                current45 = (0, 0)
            }
            if speedMPH >= 55 {
                if !continuous { current55 = (0, 0) }
                current55.duration += segment.duration
                current55.distance += segment.distanceMeters
                if current55.duration > longest55.duration {
                    longest55 = current55
                }
            } else {
                current55 = (0, 0)
            }
            if speedMPH >= 60 {
                if !continuous { current60 = (0, 0) }
                current60.duration += segment.duration
                current60.distance += segment.distanceMeters
                if current60.duration > longest60.duration {
                    longest60 = current60
                }
            } else {
                current60 = (0, 0)
            }
            previousEndIndex = segment.endIndex
        }

        return DriveSpeedExposure(
            milesAt35Plus: at35,
            milesAt45Plus: at45,
            milesAt55Plus: at55,
            milesAt60Plus: at60,
            milesAt65Plus: at65,
            longest45PlusDuration: longest45.duration,
            longest45PlusDistanceMiles: longest45.distance / 1_609.344,
            longest55PlusDuration: longest55.duration,
            longest55PlusDistanceMiles: longest55.distance / 1_609.344,
            longest60PlusDuration: longest60.duration,
            longest60PlusDistanceMiles: longest60.distance / 1_609.344,
            measuredPeakSpeedMPH: measuredPeak
        )
    }

    private static func lightingExposure(
        segments: [DriveTraceSegment],
        calendar: Calendar
    ) -> DriveLightingExposure {
        var miles = 0.0
        var duration: TimeInterval = 0
        for segment in segments where isAfterDark(segment.midpoint, calendar: calendar) {
            miles += segment.distanceMeters / 1_609.344
            duration += segment.duration
        }
        return DriveLightingExposure(afterDarkMiles: miles, afterDarkDuration: duration)
    }

    private static func eventExposure(
        _ events: [DrivingEvent],
        segments: [DriveTraceSegment],
        calendar: Calendar
    ) -> DriveEventExposure {
        var hardBrakes = 0
        var rapidAcceleration = 0
        var sharpCorners = 0
        var phoneMovement = 0
        var fused = 0
        var highSpeed = 0
        var afterDark = 0

        for event in events {
            switch event.kind {
            case .hardBrake: hardBrakes += 1
            case .rapidAcceleration: rapidAcceleration += 1
            case .sharpCorner: sharpCorners += 1
            case .phoneMovement: phoneMovement += 1
            }
            if event.source == .fused { fused += 1 }
            if isAfterDark(event.timestamp, calendar: calendar) { afterDark += 1 }
            if let segment = segments.first(where: {
                event.timestamp >= $0.start.timestamp && event.timestamp <= $0.end.timestamp
            }), segment.conservativeSpeedMetersPerSecond * 2.236936 >= 45 {
                highSpeed += 1
            }
        }

        return DriveEventExposure(
            hardBrakeCount: hardBrakes,
            rapidAccelerationCount: rapidAcceleration,
            sharpCornerCount: sharpCorners,
            phoneMovementCount: phoneMovement,
            fusedEventCount: fused,
            highSpeedEventCount: highSpeed,
            afterDarkEventCount: afterDark
        )
    }
}
