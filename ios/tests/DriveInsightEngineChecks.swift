import CoreLocation
import Foundation

@main
struct DriveInsightEngineChecks {
    static func main() {
        let calendar = utcCalendar()
        let start = date(2026, 1, 3, 22, 0, calendar: calendar)

        replayChecks(start: start)
        progressChecks(start: start, calendar: calendar)
        placementChecks(start: start)

        print("DriveInsightEngine checks passed")
    }

    private static func replayChecks(start: Date) {
        let route = [
            point(start, 30.0000, -97.0000, speed: 10),
            point(start.addingTimeInterval(2), 30.0002, -97.0000, speed: 12),
            point(start.addingTimeInterval(4), 30.0004, -97.0000, speed: 14),
            // The 16-second gap is intentionally invalid and must never be
            // interpolated by replay.
            point(start.addingTimeInterval(20), 30.0010, -97.0000, speed: 10),
            point(start.addingTimeInterval(22), 30.0012, -97.0000, speed: 8),
        ]
        let interpolatedID = UUID()
        let gapID = UUID()
        let trailingID = UUID()
        let recordedDrive = drive(
            startedAt: start,
            route: route,
            events: [
                DrivingEvent(
                    id: trailingID,
                    kind: .sharpCorner,
                    timestamp: start.addingTimeInterval(21),
                    source: .gpsSpeed
                ),
                DrivingEvent(
                    id: gapID,
                    kind: .hardBrake,
                    timestamp: start.addingTimeInterval(10),
                    source: .gpsSpeed,
                    coordinate: coordinate(30.0007, -97.0000)
                ),
                DrivingEvent(
                    id: interpolatedID,
                    kind: .rapidAcceleration,
                    timestamp: start.addingTimeInterval(1),
                    source: .fused
                ),
            ]
        )

        let moments = DriveReplayEngine.moments(for: recordedDrive)
        expect(moments.map { $0.id } == [interpolatedID, gapID, trailingID], "replay should be chronological")
        let interpolated = moments[0]
        expect(interpolated.locationAvailable, "an event without its own coordinate should interpolate inside a valid trace segment")
        expect(interpolated.coordinate?.latitude ?? 0 > 30.0000, "replay interpolation should place an in-segment event between accepted points")
        expect(interpolated.nearestSpeedMetersPerSecond == 10, "replay should expose the nearest measured speed, not an invented speed")
        expect(interpolated.routeProgress != nil, "a valid trace event should expose measured route progress")

        let gap = moments[1]
        expect(!gap.locationAvailable, "an event inside a GPS gap must not use its saved coordinate as a replay location")
        expect(gap.nearestSpeedMetersPerSecond == nil && gap.routeProgress == nil, "GPS-gap events must remain unlocated")

        let trailing = moments[2]
        expect(trailing.locationAvailable && trailing.routeProgress != nil, "a later independent valid segment should still be replayable")
        expect(trailing.elapsedSinceDriveStart == 21, "replay should retain relative drive time")

        let noTrace = drive(
            startedAt: start,
            route: [],
            events: [DrivingEvent(
                kind: .hardBrake,
                timestamp: start.addingTimeInterval(1),
                source: .gpsSpeed
            )]
        )
        let unlocated = DriveReplayEngine.moments(for: noTrace)
        expect(unlocated.count == 1 && !unlocated[0].locationAvailable, "events without usable route data need a calm unlocated replay state")
        expect(DriveReplayEngine.moments(for: drive(startedAt: start, route: route, events: [])).isEmpty, "a drive without events should not manufacture replay moments")
    }

    private static func progressChecks(start: Date, calendar: Calendar) {
        let qualifying = (0...8).map { weeksAgo in
            drive(
                startedAt: calendar.date(byAdding: .weekOfYear, value: -weeksAgo, to: start)!,
                route: qualifyingRoute(
                    start: calendar.date(byAdding: .weekOfYear, value: -weeksAgo, to: start)!,
                    speed: 22
                )
            )
        }
        let preliminary = drive(
            startedAt: start.addingTimeInterval(-60),
            route: qualifyingRoute(start: start.addingTimeInterval(-60), speed: 22),
            confidence: .low
        )
        let summary = DriverProgressEngine.makeSummary(
            from: qualifying + [preliminary],
            referenceDate: start,
            calendar: calendar
        )
        expect(summary.qualifyingDriveCount == 9, "only high-confidence, measurable drives should count toward progress")
        expect(summary.qualifyingDriveDayCount == 9, "qualifying days should retain recorded calendar days")
        expect(summary.validatedMiles > 8, "validated miles should derive from continuous GPS trace rather than score distance")
        expect(summary.afterDarkMiles > 8, "UTC night recordings should contribute measured after-dark miles")
        expect(summary.milesAt45Plus > 8, "45+ miles should require qualifying continuous speed exposure")
        expect(summary.longestContinuousDuration > 100, "longest continuous trace should come from qualified GPS segments")
        expect(summary.weeklyMeasuredMiles.count == 8, "progress must always expose eight chart buckets")
        expect(summary.weeklyMeasuredMiles.allSatisfy { $0.startDate < $0.endDate }, "weekly bucket bounds should be valid")
        expect(summary.weeklyMeasuredMiles == summary.weeklyMeasuredMiles.sorted { $0.startDate < $1.startDate }, "weekly buckets should be chronological across a year boundary")
        expect(summary.weeklyMeasuredMiles.reduce(0) { $0 + $1.measuredMiles } < summary.validatedMiles, "drives older than eight weeks should remain in totals but not the chart")

        let noHistory = DriverProgressEngine.makeSummary(from: [preliminary], referenceDate: start, calendar: calendar)
        expect(!noHistory.hasRecordedEvidence && noHistory.validatedMiles == 0, "preliminary-only history must not inflate progress")
    }

    private static func placementChecks(start: Date) {
        var unavailable = PhonePlacementAnalyzer(startedAt: start)
        for second in 0...20 {
            unavailable.ingest(observation(start, second, motionAvailable: false))
        }
        expect(unavailable.finish(at: start.addingTimeInterval(21)) == .unavailable, "missing motion data must remain unavailable")

        var incomplete = PhonePlacementAnalyzer(startedAt: start)
        for second in 0...10 {
            incomplete.ingest(observation(start, second))
        }
        expect(incomplete.assessment == .inconclusive, "an early or short drive should not claim stable placement")

        var oneEpisode = PhonePlacementAnalyzer(startedAt: start)
        for second in 0...20 {
            oneEpisode.ingest(observation(start, second, highConfidenceEpisode: second == 4))
        }
        expect(oneEpisode.assessment == .stable, "one high-confidence episode must not produce a placement warning")

        var twoEpisodes = PhonePlacementAnalyzer(startedAt: start)
        for second in 0...25 {
            twoEpisodes.ingest(observation(start, second, highConfidenceEpisode: second == 4 || second == 14))
        }
        expect(twoEpisodes.assessment == .needsAdjustment, "two well-separated high-confidence episodes after useful observation should prompt a placement check")

        var clusteredEpisodes = PhonePlacementAnalyzer(startedAt: start)
        for second in 0...20 {
            clusteredEpisodes.ingest(observation(start, second, highConfidenceEpisode: second == 4 || second == 8))
        }
        expect(clusteredEpisodes.assessment == .stable, "two closely clustered reports should remain one placement episode")

        var tinyMovement = PhonePlacementAnalyzer(startedAt: start)
        for second in 0...20 {
            // Raw tiny movement is intentionally absent from the input contract;
            // without a detector-confirmed episode it remains stable.
            tinyMovement.ingest(observation(start, second))
        }
        expect(tinyMovement.assessment == .stable, "ordinary small motion must not become a placement warning")

        var poorGPS = PhonePlacementAnalyzer(startedAt: start)
        for second in 0...20 {
            poorGPS.ingest(observation(start, second, freshGPS: false, highConfidenceEpisode: true))
        }
        expect(poorGPS.assessment == .inconclusive, "poor or stale GPS must not create a placement warning")

        var stopped = PhonePlacementAnalyzer(startedAt: start)
        for second in 0...20 {
            stopped.ingest(
                PhonePlacementObservation(
                    timestamp: start.addingTimeInterval(TimeInterval(second)),
                    vehicleSpeedMetersPerSecond: 0,
                    hasRecentAcceptedGPS: true,
                    motionDataAvailable: true,
                    highConfidenceHandlingEpisode: true
                )
            )
        }
        expect(stopped.assessment == .inconclusive, "phone setup while stopped must not produce a placement warning")

        var cutoff = PhonePlacementAnalyzer(startedAt: start)
        for second in 0...20 {
            cutoff.ingest(observation(start, second))
        }
        cutoff.ingest(observation(start, 61, highConfidenceEpisode: true))
        cutoff.ingest(observation(start, 70, highConfidenceEpisode: true))
        expect(cutoff.assessment == .stable, "episodes after the first minute must be ignored")

        twoEpisodes.reset(startedAt: start.addingTimeInterval(120))
        for second in 0...20 {
            twoEpisodes.ingest(observation(start.addingTimeInterval(120), second))
        }
        expect(twoEpisodes.assessment == .stable, "a new manual drive must reset prior placement evidence")
    }

    private static func drive(
        startedAt: Date,
        route: [DriveRoutePoint],
        events: [DrivingEvent] = [],
        confidence: DriveScoreConfidence = .high
    ) -> RecordedDrive {
        let distance = DriveExperienceEngine.validTraceSegments(for: route).reduce(0) { $0 + $1.distanceMeters }
        return RecordedDrive(
            startedAt: startedAt,
            score: DrivingScore(
                score: 92,
                duration: max(60, route.last?.timestamp.timeIntervalSince(route.first?.timestamp ?? startedAt) ?? 0),
                distanceMeters: distance,
                topSpeedMetersPerSecond: route.map { $0.speedMetersPerSecond }.max() ?? 0,
                events: events,
                motionSamples: 1_200,
                dataQuality: DriveDataQuality(
                    acceptedLocationSamples: route.count,
                    rejectedLocationSamples: 0,
                    motionSamples: 1_200,
                    confidence: confidence
                )
            ),
            route: route,
            recordingTimeZoneIdentifier: "UTC"
        )
    }

    private static func qualifyingRoute(start: Date, speed: Double) -> [DriveRoutePoint] {
        (0...60).map { index in
            point(
                start.addingTimeInterval(TimeInterval(index * 2)),
                30 + Double(index) * 0.00028,
                -97,
                speed: speed
            )
        }
    }

    private static func observation(
        _ start: Date,
        _ second: Int,
        freshGPS: Bool = true,
        motionAvailable: Bool = true,
        highConfidenceEpisode: Bool = false
    ) -> PhonePlacementObservation {
        PhonePlacementObservation(
            timestamp: start.addingTimeInterval(TimeInterval(second)),
            vehicleSpeedMetersPerSecond: 12,
            hasRecentAcceptedGPS: freshGPS,
            motionDataAvailable: motionAvailable,
            highConfidenceHandlingEpisode: highConfidenceEpisode
        )
    }

    private static func point(_ timestamp: Date, _ latitude: Double, _ longitude: Double, speed: Double) -> DriveRoutePoint {
        DriveRoutePoint(
            timestamp: timestamp,
            coordinate: coordinate(latitude, longitude),
            speedMetersPerSecond: speed
        )
    }

    private static func coordinate(_ latitude: Double, _ longitude: Double) -> DriveCoordinate {
        DriveCoordinate(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError("DriveInsightEngine check failed: \(message)")
        }
    }
}
