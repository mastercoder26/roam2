import CoreLocation
import Foundation

@main
struct DriverReadinessEngineChecks {
    static func main() throws {
        let calendar = utcCalendar()
        let referenceDate = makeDate(
            year: 2026,
            month: 7,
            day: 16,
            hour: 22,
            minute: 0,
            calendar: calendar
        )
        let routeAnchors = [
            coordinate(30.0000, -97.0000),
            coordinate(30.0000, -96.8000),
            coordinate(30.0500, -96.8000),
        ]
        let plannedPolyline = encodePolyline(routeAnchors.map(\.clLocationCoordinate))
        let fastNightTrace = trace(
            anchors: routeAnchors,
            start: referenceDate.addingTimeInterval(-3 * 86_400),
            speedMetersPerSecond: 27
        )
        let traceMiles = traceDistanceMiles(fastNightTrace)
        expect(traceMiles > 14, "fixture should contain a meaningful continuous drive")

        let summary = DriveExperienceEngine.summarize(
            drive: drive(
                startedAt: referenceDate.addingTimeInterval(-3 * 86_400),
                route: fastNightTrace
            ),
            calendar: calendar
        )
        expect(summary.traceQuality.validSegmentCount > 400, "continuous fixture should retain validated GPS segments")
        expect(summary.traceQuality.usableDistanceMeters > 20_000, "continuous fixture should retain measurable distance")
        expect(summary.speedExposure.milesAt45Plus > 14, "sustained 60 mph GPS trace should count as 45+ experience")
        expect(summary.speedExposure.milesAt60Plus > 14, "sustained 60 mph GPS trace should count as 60+ experience")
        expect(summary.speedExposure.longest60PlusDuration > 10 * 60, "engine should retain sustained high-speed episode duration")
        expect(summary.lightingExposure.afterDarkMiles > 14, "UTC night fixture should count after-dark trace distance")

        var legacySummaryObject = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(summary)
        ) as! [String: Any]
        var legacySpeedExposure = legacySummaryObject["speedExposure"] as! [String: Any]
        legacySpeedExposure.removeValue(forKey: "milesAt60Plus")
        legacySpeedExposure.removeValue(forKey: "longest60PlusDuration")
        legacySpeedExposure.removeValue(forKey: "longest60PlusDistanceMiles")
        legacySummaryObject["speedExposure"] = legacySpeedExposure
        let decodedLegacySummary = try JSONDecoder().decode(
            DriveExperienceSummary.self,
            from: JSONSerialization.data(withJSONObject: legacySummaryObject)
        )
        expect(
            decodedLegacySummary.speedExposure.milesAt60Plus == 0,
            "older persisted summaries should decode before the 60+ mph field existed"
        )

        var spikeTrace = trace(
            anchors: routeAnchors,
            start: referenceDate.addingTimeInterval(-4 * 86_400),
            speedMetersPerSecond: 12
        )
        spikeTrace[spikeTrace.count / 2] = DriveRoutePoint(
            timestamp: spikeTrace[spikeTrace.count / 2].timestamp,
            coordinate: spikeTrace[spikeTrace.count / 2].coordinate,
            speedMetersPerSecond: 50
        )
        let spikeSummary = DriveExperienceEngine.summarize(
            drive: drive(
                startedAt: referenceDate.addingTimeInterval(-4 * 86_400),
                route: spikeTrace
            ),
            calendar: calendar
        )
        expect(spikeSummary.speedExposure.milesAt45Plus == 0, "a one-point GPS speed spike must not earn fast-road experience")

        let demands = [
            demand(
                .afterDark,
                intensity: 0.80,
                evidence: "About 15 miles of the drive fall in the 8 PM–6 AM window.",
                metrics: ["nightMiles": 15],
                ranges: [RouteDemandCoverageRange(startFraction: 0, endFraction: 1)]
            ),
            demand(
                .fastRoads,
                intensity: 0.80,
                evidence: "Most of the route is estimated at 60+ mph.",
                metrics: ["estimatedMilesAt45": 15, "estimatedMilesAt60": 12],
                ranges: [RouteDemandCoverageRange(startFraction: 0, endFraction: 0.82)]
            ),
            demand(
                .merges,
                intensity: 0.80,
                evidence: "Two ramp transitions appear on this route.",
                metrics: ["mergeTransitionCount": 2],
                ranges: [RouteDemandCoverageRange(startFraction: 0.35, endFraction: 0.45)]
            ),
            demand(
                .complexIntersections,
                intensity: 0.80,
                evidence: "Several turn instructions are closely spaced.",
                metrics: ["intersectionInstructionCount": 4],
                ranges: [RouteDemandCoverageRange(startFraction: 0.78, endFraction: 0.90)]
            ),
            demand(
                .sustainedDrive,
                intensity: 0.60,
                evidence: "Expected drive time is about 18 minutes.",
                metrics: ["expectedDurationMinutes": 18],
                ranges: [RouteDemandCoverageRange(startFraction: 0, endFraction: 1)]
            ),
            demand(
                .weatherVisibility,
                intensity: 0.80,
                evidence: "Live route weather includes rain and reduced visibility.",
                metrics: ["weatherSeverity": 0.8]
            ),
        ]
        let route = scoredRoute(polyline: plannedPolyline, demands: demands)

        let baseDrives = (1...3).map { offset in
            drive(
                startedAt: referenceDate.addingTimeInterval(TimeInterval(-offset * 86_400)),
                route: trace(
                    anchors: routeAnchors,
                    start: referenceDate.addingTimeInterval(TimeInterval(-offset * 86_400)),
                    speedMetersPerSecond: 27
                )
            )
        }
        let profile = DriverReadinessEngine.profile(
            from: baseDrives,
            configuration: .init(),
            calendar: calendar,
            referenceDate: referenceDate
        )
        expect(profile.qualifyingDriveCount == 3, "three high-confidence continuous records should qualify")
        expect(profile.qualifyingDriveDayCount == 3, "repeated practice on separate days should be retained")
        expect(profile.reliableTraceMiles > 40, "profile should aggregate validated trace distance rather than score distance")
        expect(profile.nightExposure.sessionCount == 3, "night exposure should retain separate sessions")
        expect(profile.fastRoad55Exposure.sessionCount == 3, "speed-band exposure should retain separate sessions")
        expect(profile.hasEnoughRecordedExperience, "three repeated 15-mile records should clear the cautious history baseline")

        let untagged = DriverReadinessEngine.assess(
            route: route,
            recordedDrives: baseDrives,
            configuration: .init(),
            calendar: calendar,
            referenceDate: referenceDate
        )
        expect(untagged.verdict == .practiceWithAdult, "unmeasured high merge/intersection demand must not become a match")
        expect(
            insight("merges", in: untagged)?.state == .unmeasured,
            "GPS speed history alone must not claim a merge was practiced"
        )
        expect(
            insight("complexIntersections", in: untagged)?.detail.lowercased().contains("not yet measured") == true,
            "intersection gaps must be explicit rather than calling a first experience"
        )
        expect(
            untagged.familiarity.level == .familiar,
            "a single continuous direction-aligned saved trace should make the route familiar"
        )

        let coverage = DriverReadinessEngine.practiceRouteCoverage(
            plannedPolyline: plannedPolyline,
            recordedRoute: fastNightTrace,
            demands: demands
        )
        expect(coverage.overallCoverage > 0.95, "matching continuous trace should cover the planned route")
        expect(coverage.longestContinuousCoverage > 0.95, "matching continuous trace should preserve order and continuity")
        expect(
            coverage.demandExposures.contains { $0.demandID == RouteDemandKind.merges.rawValue && $0.coveredShare > 0.95 },
            "mapped merge range should produce demand-specific local coverage"
        )
        expect(
            coverage.demandExposures.contains { $0.demandID == RouteDemandKind.complexIntersections.rawValue && $0.coveredShare > 0.95 },
            "mapped intersection range should produce demand-specific local coverage"
        )
        expect(
            coverage.demandExposures.contains { $0.demandID == RouteDemandKind.weatherVisibility.rawValue && $0.coveredShare > 0.95 },
            "a full planned practice pass should retain the planned weather snapshot as explicitly caveated context"
        )
        expect(
            DriverReadinessEngine.matchesPlannedPracticeRoute(
                plannedPolyline: plannedPolyline,
                recordedRoute: fastNightTrace
            ),
            "matching trace should verify a planned practice route"
        )

        let reverseTrace = trace(
            anchors: routeAnchors.reversed(),
            start: referenceDate.addingTimeInterval(-5 * 86_400),
            speedMetersPerSecond: 27
        )
        expect(
            !DriverReadinessEngine.matchesPlannedPracticeRoute(
                plannedPolyline: plannedPolyline,
                recordedRoute: reverseTrace
            ),
            "reverse-direction travel must not verify an origin-to-destination practice route"
        )

        let fragmentedTrace = fragmentedMiddle(trace: fastNightTrace)
        let fragmentedCoverage = DriverReadinessEngine.practiceRouteCoverage(
            plannedPolyline: plannedPolyline,
            recordedRoute: fragmentedTrace,
            demands: demands
        )
        expect(fragmentedCoverage.overallCoverage > 0.50, "two real route fragments should retain their local coverage")
        expect(fragmentedCoverage.longestContinuousCoverage < 0.45, "a long GPS gap must not bridge fragments into a continuous practice drive")
        expect(
            !DriverReadinessEngine.matchesPlannedPracticeRoute(
                plannedPolyline: plannedPolyline,
                recordedRoute: fragmentedTrace
            ),
            "fragmented GPS history must not verify a whole planned practice route"
        )

        let parallelTrace = trace(
            anchors: routeAnchors.map { coordinate($0.latitude + 0.00035, $0.longitude) },
            start: referenceDate.addingTimeInterval(-5 * 86_400),
            speedMetersPerSecond: 27
        )
        expect(
            !DriverReadinessEngine.matchesPlannedPracticeRoute(
                plannedPolyline: plannedPolyline,
                recordedRoute: parallelTrace
            ),
            "a same-direction parallel frontage road must not verify the planned route"
        )

        let outOfOrderTrace = trace(
            anchors: [routeAnchors[1], routeAnchors[2], routeAnchors[0], routeAnchors[1]],
            start: referenceDate.addingTimeInterval(-5 * 86_400),
            speedMetersPerSecond: 27
        )
        expect(
            !DriverReadinessEngine.matchesPlannedPracticeRoute(
                plannedPolyline: plannedPolyline,
                recordedRoute: outOfOrderTrace
            ),
            "scattered route fragments recorded out of order must not verify a planned route"
        )

        let shortPolyline = encodePolyline([
            coordinate(30.0000, -97.0000).clLocationCoordinate,
            coordinate(30.0000, -96.9992).clLocationCoordinate
        ])
        let shortTrace = trace(
            anchors: [coordinate(30.0000, -97.0000), coordinate(30.0000, -96.9992)],
            start: referenceDate.addingTimeInterval(-5 * 86_400),
            speedMetersPerSecond: 12,
            spacingMeters: 10
        )
        expect(
            !DriverReadinessEngine.matchesPlannedPracticeRoute(
                plannedPolyline: shortPolyline,
                recordedRoute: shortTrace
            ),
            "a very short route should not be GPS-verified as planned practice"
        )

        let verifiedExposures = coverage.demandExposures.map {
            VerifiedDemandExposure(
                demandID: $0.demandID,
                demandIntensity: $0.demandIntensity,
                coveredShare: $0.coveredShare,
                routeShare: $0.routeShare,
                recordedAt: referenceDate.addingTimeInterval(-2 * 86_400)
            )
        }
        let firstPractice = drive(
            startedAt: referenceDate.addingTimeInterval(-2 * 86_400),
            route: trace(
                anchors: routeAnchors,
                start: referenceDate.addingTimeInterval(-2 * 86_400),
                speedMetersPerSecond: 27
            ),
            context: PlannedRouteContext(
                createdAt: referenceDate.addingTimeInterval(-2 * 86_400),
                routeDemands: demands,
                recordedRouteMatched: true,
                verifiedDemandExposures: verifiedExposures
            )
        )
        let onePracticeAssessment = DriverReadinessEngine.assess(
            route: route,
            recordedDrives: baseDrives + [firstPractice],
            configuration: .init(),
            calendar: calendar,
            referenceDate: referenceDate
        )
        expect(
            insight("merges", in: onePracticeAssessment)?.state == .practiceNeeded,
            "one mapped high-demand practice drive must not satisfy a repeated-practice requirement"
        )

        let secondPractice = drive(
            startedAt: referenceDate.addingTimeInterval(-1 * 86_400),
            route: trace(
                anchors: routeAnchors,
                start: referenceDate.addingTimeInterval(-1 * 86_400),
                speedMetersPerSecond: 27
            ),
            context: PlannedRouteContext(
                createdAt: referenceDate.addingTimeInterval(-1 * 86_400),
                routeDemands: demands,
                recordedRouteMatched: true,
                verifiedDemandExposures: verifiedExposures.map {
                    VerifiedDemandExposure(
                        demandID: $0.demandID,
                        demandIntensity: $0.demandIntensity,
                        coveredShare: $0.coveredShare,
                        routeShare: $0.routeShare,
                        recordedAt: referenceDate.addingTimeInterval(-1 * 86_400)
                    )
                }
            )
        )
        let measuredAssessment = DriverReadinessEngine.assess(
            route: route,
            recordedDrives: baseDrives + [firstPractice, secondPractice],
            configuration: .init(),
            calendar: calendar,
            referenceDate: referenceDate
        )
        expect(
            insight("merges", in: measuredAssessment)?.state == .matched,
            "two mapped, route-covered practice records should count for a high merge demand"
        )
        expect(
            insight("complexIntersections", in: measuredAssessment)?.state == .matched,
            "two mapped, route-covered practice records should count for a high intersection demand"
        )
        expect(
            measuredAssessment.verdict == .looksLikeMatch,
            "a route should match only once every meaningful measured demand is supported"
        )

        let legacyBooleanPractice = drive(
            startedAt: referenceDate.addingTimeInterval(-86_400),
            route: fastNightTrace,
            context: PlannedRouteContext(
                createdAt: referenceDate.addingTimeInterval(-86_400),
                routeDemands: demands,
                recordedRouteMatched: true
            )
        )
        let legacyProfile = DriverReadinessEngine.profile(
            from: baseDrives + [legacyBooleanPractice],
            configuration: .init(),
            calendar: calendar,
            referenceDate: referenceDate
        )
        expect(
            legacyProfile.taggedExposureCount(for: .merges) == 0,
            "legacy whole-route Boolean tags must not claim demand-specific merge exposure"
        )

        let slowerHistory = (1...3).map { offset in
            drive(
                startedAt: referenceDate.addingTimeInterval(TimeInterval(-offset * 86_400)),
                route: trace(
                    anchors: routeAnchors,
                    start: referenceDate.addingTimeInterval(TimeInterval(-offset * 86_400)),
                    speedMetersPerSecond: 22
                )
            )
        }
        let fastOnlyRoute = scoredRoute(
            polyline: plannedPolyline,
            demands: [demands[1]]
        )
        let slowAssessment = DriverReadinessEngine.assess(
            route: fastOnlyRoute,
            recordedDrives: slowerHistory,
            configuration: .init(),
            calendar: calendar,
            referenceDate: referenceDate
        )
        expect(
            insight("fastRoads", in: slowAssessment)?.state == .practiceNeeded,
            "45–50 mph history must not satisfy a route whose factual demand includes sustained 60+ mph roads"
        )

        let fiftyFiveHistory = (1...3).map { offset in
            drive(
                startedAt: referenceDate.addingTimeInterval(TimeInterval(-offset * 86_400)),
                route: trace(
                    anchors: routeAnchors,
                    start: referenceDate.addingTimeInterval(TimeInterval(-offset * 86_400)),
                    speedMetersPerSecond: 25
                )
            )
        }
        let fiftyFiveAssessment = DriverReadinessEngine.assess(
            route: fastOnlyRoute,
            recordedDrives: fiftyFiveHistory,
            configuration: .init(),
            calendar: calendar,
            referenceDate: referenceDate
        )
        expect(
            insight("fastRoads", in: fiftyFiveAssessment)?.state == .practiceNeeded,
            "55 mph GPS history must not be treated as equivalent to a 60+ mph route"
        )

        var staleHistory: [RecordedDrive] = []
        for offset in 1...3 {
            let oldDate = referenceDate.addingTimeInterval(-Double(365 + offset) * 86_400)
            staleHistory.append(
                drive(
                    startedAt: oldDate,
                    route: trace(
                        anchors: routeAnchors,
                        start: oldDate,
                        speedMetersPerSecond: 27
                    )
                )
            )
        }
        let freshShortHistory = drive(
            startedAt: referenceDate.addingTimeInterval(-86_400),
            route: trace(
                anchors: [coordinate(30.0000, -97.0000), coordinate(30.0000, -96.9800)],
                start: referenceDate.addingTimeInterval(-86_400),
                speedMetersPerSecond: 12,
                spacingMeters: 20
            )
        )
        let staleProfile = DriverReadinessEngine.profile(
            from: staleHistory + [freshShortHistory],
            configuration: .init(),
            calendar: calendar,
            referenceDate: referenceDate
        )
        expect(
            !staleProfile.hasEnoughRecordedExperience,
            "large stale history plus one tiny fresh trip must not clear the current-history baseline"
        )

        let freshShortFastDrive = drive(
            startedAt: referenceDate.addingTimeInterval(-86_400),
            route: trace(
                anchors: [coordinate(30.0000, -97.0000), coordinate(30.0000, -96.9800)],
                start: referenceDate.addingTimeInterval(-86_400),
                speedMetersPerSecond: 27,
                spacingMeters: 20
            )
        )
        let staleFastAssessment = DriverReadinessEngine.assess(
            route: fastOnlyRoute,
            recordedDrives: staleHistory + [freshShortFastDrive],
            configuration: DriverReadinessEngine.Configuration(
                minimumHistoryDriveCount: 1,
                minimumHistoryDayCount: 1,
                minimumHistoryMiles: 0.5,
                minimumHistoryTraceDuration: 60,
                minimumRecentHistoryMiles: 0.5,
                minimumRecentHistoryDriveCount: 1
            ),
            calendar: calendar,
            referenceDate: referenceDate
        )
        expect(
            insight("fastRoads", in: staleFastAssessment)?.state == .practiceNeeded,
            "old fast-road mileage plus one brief fresh pass must not count as current fast-road experience"
        )

        let sustainedOnlyRoute = scoredRoute(
            polyline: plannedPolyline,
            demands: [
                demand(
                    .sustainedDrive,
                    intensity: 0.80,
                    evidence: "Expected drive time is about 100 minutes.",
                    metrics: ["expectedDurationMinutes": 100],
                    ranges: [RouteDemandCoverageRange(startFraction: 0, endFraction: 1)]
                )
            ]
        )
        let longTrace = trace(
            anchors: routeAnchors,
            start: referenceDate.addingTimeInterval(-2 * 86_400),
            speedMetersPerSecond: 5,
            spacingMeters: 20
        )
        let freshLongDrive = drive(
            startedAt: referenceDate.addingTimeInterval(-2 * 86_400),
            route: longTrace
        )
        let focusedHistoryConfiguration = DriverReadinessEngine.Configuration(
            minimumHistoryDriveCount: 1,
            minimumHistoryDayCount: 1,
            minimumHistoryMiles: 0.5,
            minimumHistoryTraceDuration: 60,
            minimumRecentHistoryMiles: 0.5,
            minimumRecentHistoryDriveCount: 1
        )
        let oneLongOneShortAssessment = DriverReadinessEngine.assess(
            route: sustainedOnlyRoute,
            recordedDrives: [freshLongDrive, freshShortHistory],
            configuration: focusedHistoryConfiguration,
            calendar: calendar,
            referenceDate: referenceDate
        )
        expect(
            insight("sustainedDrive", in: oneLongOneShortAssessment)?.state == .practiceNeeded,
            "a single long drive plus a short errand must not satisfy the second sustained-session requirement"
        )

        let oldRouteJSON = """
        {
          "score": 6.2,
          "label": "Hard",
          "reasons": [],
          "breakdown": {"traffic": 0, "highway": 0, "maneuvers": 0, "navDensity": 0, "effort": 0},
          "distanceMeters": 5000,
          "durationSeconds": 600,
          "staticDurationSeconds": 600,
          "trafficDelaySeconds": 0,
          "polyline": "abc",
          "bounds": {
            "southwest": {"lat": 30, "lng": -97},
            "northeast": {"lat": 30.1, "lng": -96.9}
          }
        }
        """.data(using: .utf8)!
        let decodedOldRoute = try JSONDecoder().decode(ScoredRoute.self, from: oldRouteJSON)
        expect(decodedOldRoute.routeDemands == nil, "older backend responses must remain decodable")

        let mappedDemandJSON = """
        {
          "id": "merges",
          "title": "Merges and ramps",
          "intensity": 0.82,
          "level": "high",
          "evidence": "Two merge transitions appear.",
          "available": true,
          "metrics": {"mergeTransitionCount": 2},
          "coverageRanges": [{"startFraction": 0.35, "endFraction": 0.45}]
        }
        """.data(using: .utf8)!
        let decodedMappedDemand = try JSONDecoder().decode(RouteDemand.self, from: mappedDemandJSON)
        expect(
            decodedMappedDemand.metrics?["mergeTransitionCount"] == 2,
            "new factual route-demand metrics must decode on iOS"
        )
        expect(
            decodedMappedDemand.coverageRanges?.first?.startFraction == 0.35,
            "new mapped coverage ranges must decode on iOS"
        )

        let encodedNewDrive = try JSONEncoder().encode(firstPractice)
        var legacyDriveObject = try JSONSerialization.jsonObject(with: encodedNewDrive) as! [String: Any]
        let savedContext = legacyDriveObject["plannedRouteContext"] as! [String: Any]
        expect(
            savedContext["routeDemands"] == nil && savedContext["routeDemandTags"] != nil,
            "new practice history must persist only demand tags, not mapped route ranges or demand metrics"
        )
        legacyDriveObject.removeValue(forKey: "experienceSummary")
        legacyDriveObject.removeValue(forKey: "recordingTimeZoneIdentifier")
        var legacyContext = legacyDriveObject["plannedRouteContext"] as! [String: Any]
        legacyContext.removeValue(forKey: "verifiedDemandExposures")
        legacyDriveObject["plannedRouteContext"] = legacyContext
        let decodedLegacyDrive = try JSONDecoder().decode(
            RecordedDrive.self,
            from: JSONSerialization.data(withJSONObject: legacyDriveObject)
        )
        expect(decodedLegacyDrive.experienceSummary == nil, "legacy saved drives should decode without a summary migration")
        expect(decodedLegacyDrive.recordingTimeZoneIdentifier == nil, "legacy saved drives should decode without a timezone migration")
        expect(
            decodedLegacyDrive.plannedRouteContext?.verifiedDemandExposures == nil,
            "legacy practice contexts should not fabricate demand-specific evidence"
        )

        var prePrivacyDriveObject = try JSONSerialization.jsonObject(with: encodedNewDrive) as! [String: Any]
        var prePrivacyContext = prePrivacyDriveObject["plannedRouteContext"] as! [String: Any]
        prePrivacyContext.removeValue(forKey: "routeDemandTags")
        prePrivacyContext["routeDemands"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(demands)
        )
        prePrivacyDriveObject["plannedRouteContext"] = prePrivacyContext
        let decodedPrePrivacyDrive = try JSONDecoder().decode(
            RecordedDrive.self,
            from: JSONSerialization.data(withJSONObject: prePrivacyDriveObject)
        )
        expect(
            decodedPrePrivacyDrive.plannedRouteContext?.routeDemands.count == demands.count,
            "older saved contexts with full route demands must still decode after privacy minimization"
        )

        print("DriverReadinessEngine checks passed")
    }

    private static func demand(
        _ kind: RouteDemandKind,
        intensity: Double,
        evidence: String,
        metrics: [String: Double] = [:],
        ranges: [RouteDemandCoverageRange] = []
    ) -> RouteDemand {
        RouteDemand(
            id: kind.rawValue,
            intensity: intensity,
            level: intensity >= 0.67 ? .high : .moderate,
            evidence: evidence,
            available: true,
            metrics: metrics,
            coverageRanges: ranges
        )
    }

    private static func scoredRoute(
        polyline: String,
        demands: [RouteDemand]
    ) -> ScoredRoute {
        ScoredRoute(
            score: 6.8,
            uncalibratedScore: nil,
            label: .hard,
            reasons: [],
            breakdown: DifficultyBreakdown(
                speed: nil,
                merges: nil,
                turns: nil,
                traffic: 0,
                length: nil,
                fatigue: nil,
                weather: nil,
                road: nil,
                highway: 0,
                maneuvers: 0,
                navDensity: 0,
                effort: 0
            ),
            contributions: nil,
            uncertainty: nil,
            hotspots: nil,
            conditions: nil,
            modelVersion: nil,
            distanceMeters: 25_000,
            durationSeconds: 18 * 60,
            staticDurationSeconds: 18 * 60,
            trafficDelaySeconds: 0,
            polyline: polyline,
            bounds: RouteBounds(
                southwest: Coordinate(latitude: 29.9, longitude: -97.1),
                northeast: Coordinate(latitude: 30.1, longitude: -96.7)
            ),
            scoreDelta: nil,
            routeDemands: demands
        )
    }

    private static func drive(
        startedAt: Date,
        route: [DriveRoutePoint],
        context: PlannedRouteContext? = nil
    ) -> RecordedDrive {
        let distanceMeters = traceDistanceMeters(route)
        let duration = max(
            5 * 60,
            (route.last?.timestamp.timeIntervalSince(route.first?.timestamp ?? startedAt) ?? 0)
        )
        return RecordedDrive(
            startedAt: startedAt,
            score: DrivingScore(
                score: 92,
                duration: duration,
                distanceMeters: distanceMeters,
                topSpeedMetersPerSecond: route.map(\.speedMetersPerSecond).max() ?? 0,
                events: [],
                motionSamples: 1_500,
                dataQuality: DriveDataQuality(
                    acceptedLocationSamples: route.count,
                    rejectedLocationSamples: 0,
                    motionSamples: 1_500,
                    confidence: .high
                )
            ),
            route: route,
            recordingTimeZoneIdentifier: "UTC",
            plannedRouteContext: context
        )
    }

    private static func trace(
        anchors: [DriveCoordinate],
        start: Date,
        speedMetersPerSecond: Double,
        spacingMeters: Double = 40
    ) -> [DriveRoutePoint] {
        guard anchors.count >= 2 else { return [] }
        var result: [DriveRoutePoint] = []
        var timestamp = start
        var previous: DriveCoordinate?

        for (startCoordinate, endCoordinate) in zip(anchors, anchors.dropFirst()) {
            let distance = distanceMeters(startCoordinate, endCoordinate)
            let steps = max(1, Int((distance / spacingMeters).rounded(.up)))
            for index in 0...steps {
                if !result.isEmpty && index == 0 { continue }
                let fraction = Double(index) / Double(steps)
                let coordinate = interpolate(startCoordinate, endCoordinate, fraction: fraction)
                if let previous {
                    timestamp = timestamp.addingTimeInterval(
                        distanceMeters(previous, coordinate) / speedMetersPerSecond
                    )
                }
                result.append(
                    DriveRoutePoint(
                        timestamp: timestamp,
                        coordinate: coordinate,
                        speedMetersPerSecond: speedMetersPerSecond
                    )
                )
                previous = coordinate
            }
        }
        return result
    }

    private static func fragmentedMiddle(trace: [DriveRoutePoint]) -> [DriveRoutePoint] {
        let firstEnd = trace.count * 3 / 10
        let secondStart = trace.count * 7 / 10
        return Array(trace[..<firstEnd]) + Array(trace[secondStart...])
    }

    private static func coordinate(_ latitude: Double, _ longitude: Double) -> DriveCoordinate {
        DriveCoordinate(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
    }

    private static func interpolate(
        _ start: DriveCoordinate,
        _ end: DriveCoordinate,
        fraction: Double
    ) -> DriveCoordinate {
        coordinate(
            start.latitude + (end.latitude - start.latitude) * fraction,
            start.longitude + (end.longitude - start.longitude) * fraction
        )
    }

    private static func traceDistanceMeters(_ trace: [DriveRoutePoint]) -> Double {
        zip(trace, trace.dropFirst()).reduce(0) {
            $0 + distanceMeters($1.0.coordinate, $1.1.coordinate)
        }
    }

    private static func traceDistanceMiles(_ trace: [DriveRoutePoint]) -> Double {
        traceDistanceMeters(trace) / 1_609.344
    }

    private static func distanceMeters(
        _ lhs: DriveCoordinate,
        _ rhs: DriveCoordinate
    ) -> Double {
        CLLocation(latitude: lhs.latitude, longitude: lhs.longitude).distance(
            from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude)
        )
    }

    private static func insight(
        _ id: String,
        in assessment: DriverReadinessAssessment
    ) -> DriverReadinessInsight? {
        assessment.insights.first { $0.id == id }
    }

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        calendar: Calendar
    ) -> Date {
        calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }

    private static func encodePolyline(_ coordinates: [CLLocationCoordinate2D]) -> String {
        var previousLatitude = 0
        var previousLongitude = 0
        var encoded = ""

        for coordinate in coordinates {
            let latitude = Int((coordinate.latitude * 100_000).rounded())
            let longitude = Int((coordinate.longitude * 100_000).rounded())
            encoded += encodePolylineComponent(latitude - previousLatitude)
            encoded += encodePolylineComponent(longitude - previousLongitude)
            previousLatitude = latitude
            previousLongitude = longitude
        }
        return encoded
    }

    private static func encodePolylineComponent(_ value: Int) -> String {
        var value = value < 0 ? ~(value << 1) : value << 1
        var scalars = String.UnicodeScalarView()
        while value >= 0x20 {
            scalars.append(UnicodeScalar((0x20 | (value & 0x1F)) + 63)!)
            value >>= 5
        }
        scalars.append(UnicodeScalar(value + 63)!)
        return String(scalars)
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fatalError("DriverReadinessEngine check failed: \(message)")
        }
    }
}
