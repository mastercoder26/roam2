import CoreLocation
import Foundation

/// Ordered, direction-aware matching between a planned route and a locally
/// recorded GPS trace. It is deliberately separate from readiness verdicts so
/// proximity thresholds and continuity rules can be exercised independently.
enum DriverReadinessRouteMatcher {
    static func matchesPlannedPracticeRoute(
        plannedPolyline: String,
        recordedRoute: [DriveRoutePoint]
    ) -> Bool {
        let configuration = DriverReadinessEngine.Configuration()
        let coverage = practiceRouteCoverage(
            plannedPolyline: plannedPolyline,
            recordedRoute: recordedRoute,
            demands: [],
            configuration: configuration
        )
        return coverage.overallCoverage >= 0.60 &&
            coverage.longestContinuousCoverage >= configuration.minimumPracticeContiguousShare &&
            coverage.originCoverage >= 0.60 &&
            coverage.destinationCoverage >= 0.60
    }

    /// Calculates route and demand-specific coverage while the queued route
    /// polyline remains in memory. Callers persist only returned numeric
    /// demand evidence, never the plan's geometry.
    static func practiceRouteCoverage(
        plannedPolyline: String,
        recordedRoute: [DriveRoutePoint],
        demands: [RouteDemand],
        configuration: DriverReadinessEngine.Configuration
    ) -> PracticeRouteCoverage {
        let planned = sampledRoute(
            polyline: plannedPolyline,
            limit: configuration.routeFamiliaritySampleLimit
        )
        let recorded = DriveExperienceEngine.validTraceSegments(for: recordedRoute)
        guard planned.count >= 3,
              recorded.count >= 4,
              routeDistanceMeters(for: plannedPolyline) >= configuration.minimumPracticeRouteDistanceMeters else {
            return PracticeRouteCoverage(
                overallCoverage: 0,
                longestContinuousCoverage: 0,
                originCoverage: 0,
                destinationCoverage: 0,
                demandExposures: []
            )
        }
        let matches = orderedPracticeMatches(
            planned: planned,
            trace: recorded,
            threshold: configuration.practiceRouteMatchDistanceMeters
        )
        let overall = share(of: matches.flags)
        let contiguous = longestOrderedContinuousShare(matches)
        let endpointWindow = min(12, max(3, Int((Double(planned.count) * 0.08).rounded(.up))))
        let originCoverage = share(of: Array(matches.flags.prefix(endpointWindow)))
        let destinationCoverage = share(of: Array(matches.flags.suffix(endpointWindow)))
        let demandExposures = demandCoverage(
            demands: demands,
            samples: planned,
            matches: matches,
            threshold: configuration.practiceCoverageThreshold,
            fullRouteCoverage: overall,
            fullRouteContinuousCoverage: contiguous,
            minimumContinuousCoverage: configuration.minimumPracticeContiguousShare
        )
        return PracticeRouteCoverage(
            overallCoverage: overall,
            longestContinuousCoverage: contiguous,
            originCoverage: originCoverage,
            destinationCoverage: destinationCoverage,
            demandExposures: demandExposures
        )
    }

    static func familiarity(
        for route: ScoredRoute,
        qualifyingDrives: [HistoryDrive],
        configuration: DriverReadinessEngine.Configuration
    ) -> RouteFamiliarity {
        let planned = sampledRoute(
            polyline: route.polyline,
            limit: configuration.routeFamiliaritySampleLimit
        )
        guard planned.count >= 3 else {
            return RouteFamiliarity(
                level: .unmeasured,
                matchedShare: 0,
                sampledPointCount: 0,
                matchingPointCount: 0,
                bestSingleDriveShare: 0,
                longestContinuousShare: 0,
                matchingDriveCount: 0,
                mostRecentMatchingDrive: nil
            )
        }

        var combined = Array(repeating: false, count: planned.count)
        var bestShare = 0.0
        var bestContinuous = 0.0
        var matchingDrives = 0
        var mostRecent: Date?
        var sawUsableTrace = false

        for history in qualifyingDrives {
            let trace = DriveExperienceEngine.validTraceSegments(for: history.drive.route)
            guard trace.count >= 4 else { continue }
            sawUsableTrace = true
            let matches = matchingFlags(
                planned: planned,
                trace: evenlySampled(trace, limit: 1_200),
                threshold: configuration.routeFamiliarityDistanceMeters
            )
            let coverage = share(of: matches)
            let continuous = longestRunShare(of: matches)
            bestShare = max(bestShare, coverage)
            bestContinuous = max(bestContinuous, continuous)
            if coverage >= 0.10 {
                matchingDrives += 1
                if mostRecent == nil || history.drive.startedAt > mostRecent! {
                    mostRecent = history.drive.startedAt
                }
            }
            for index in combined.indices where matches[index] {
                combined[index] = true
            }
        }

        guard sawUsableTrace else {
            return RouteFamiliarity(
                level: .unmeasured,
                matchedShare: 0,
                sampledPointCount: planned.count,
                matchingPointCount: 0,
                bestSingleDriveShare: 0,
                longestContinuousShare: 0,
                matchingDriveCount: 0,
                mostRecentMatchingDrive: nil
            )
        }

        let combinedShare = share(of: combined)
        let level: RouteFamiliarityLevel
        if bestShare >= 0.65 && bestContinuous >= 0.45 {
            level = .familiar
        } else if combinedShare >= 0.15 {
            level = .partlyFamiliar
        } else {
            level = .unfamiliar
        }
        return RouteFamiliarity(
            level: level,
            matchedShare: combinedShare,
            sampledPointCount: planned.count,
            matchingPointCount: combined.filter { $0 }.count,
            bestSingleDriveShare: bestShare,
            longestContinuousShare: bestContinuous,
            matchingDriveCount: matchingDrives,
            mostRecentMatchingDrive: mostRecent
        )
    }

    private static func demandCoverage(
        demands: [RouteDemand],
        samples: [RouteProgressSample],
        matches: OrderedRouteMatches,
        threshold: Double,
        fullRouteCoverage: Double,
        fullRouteContinuousCoverage: Double,
        minimumContinuousCoverage: Double
    ) -> [VerifiedDemandExposure] {
        guard samples.count == matches.flags.count else { return [] }
        return demands.compactMap { demand in
            guard demand.available, demand.intensity >= 0.34 else {
                return nil
            }
            let routeWideCondition = demand.kind == .weatherVisibility ||
                demand.kind == .traffic ||
                demand.kind == .roadConditions
            guard let ranges = demand.coverageRanges, !ranges.isEmpty else {
                // Weather, traffic, and road data are route-wide snapshots in
                // this release. They have no honest map section, but a manual
                // drive that substantially followed the full plan can retain
                // that it was recorded against the planned snapshot. The
                // readiness copy makes clear this never proves today's live
                // conditions.
                guard routeWideCondition,
                      fullRouteCoverage >= threshold,
                      fullRouteContinuousCoverage >= minimumContinuousCoverage else {
                    return nil
                }
                return VerifiedDemandExposure(
                    demandID: demand.id,
                    demandIntensity: demand.intensity,
                    coveredShare: fullRouteCoverage,
                    routeShare: 1,
                    recordedAt: Date()
                )
            }
            let normalizedRanges = ranges.map(\.normalized)
            let indices = samples.indices.filter { index in
                normalizedRanges.contains { range in
                    samples[index].fraction >= range.startFraction && samples[index].fraction <= range.endFraction
                }
            }
            guard !indices.isEmpty else { return nil }
            let covered = Double(indices.filter { matches.flags[$0] }.count) / Double(indices.count)
            let continuous = longestOrderedContinuousShare(matches, limitedTo: indices)
            let routeShare = Double(indices.count) / Double(samples.count)
            guard covered >= threshold, continuous >= threshold else { return nil }
            return VerifiedDemandExposure(
                demandID: demand.id,
                demandIntensity: demand.intensity,
                coveredShare: covered,
                routeShare: routeShare,
                recordedAt: Date()
            )
        }
    }

    private static func sampledRoute(polyline: String, limit: Int) -> [RouteProgressSample] {
        let coordinates = RoutePolylineDecoder.decode(polyline).filter(CLLocationCoordinate2DIsValid)
        guard coordinates.count >= 2 else { return [] }
        let distances = zip(coordinates, coordinates.dropFirst()).map {
            coordinateDistanceMeters(DriveCoordinate($0.0), DriveCoordinate($0.1))
        }
        let total = distances.reduce(0, +)
        guard total > 0 else { return [] }
        let count = min(limit, max(40, Int((total / 35).rounded()) + 1))
        let spacing = total / Double(max(1, count - 1))
        var samples: [RouteProgressSample] = []
        var segmentIndex = 0
        var beforeSegment = 0.0

        for sampleIndex in 0..<count {
            let target = min(total, Double(sampleIndex) * spacing)
            while segmentIndex < distances.count - 1,
                  target > beforeSegment + distances[segmentIndex] {
                beforeSegment += distances[segmentIndex]
                segmentIndex += 1
            }
            let segmentDistance = max(0.001, distances[segmentIndex])
            let withinSegment = min(1, max(0, (target - beforeSegment) / segmentDistance))
            let start = coordinates[segmentIndex]
            let end = coordinates[segmentIndex + 1]
            samples.append(
                RouteProgressSample(
                    coordinate: interpolatedCoordinate(from: start, to: end, fraction: withinSegment),
                    fraction: target / total,
                    bearing: bearing(from: start, to: end)
                )
            )
        }
        return samples
    }

    private static func matchingFlags(
        planned: [RouteProgressSample],
        trace: [DriveTraceSegment],
        threshold: CLLocationDistance
    ) -> [Bool] {
        planned.map { sample in
            trace.contains { segment in
                guard directionDifferenceDegrees(
                    sample.bearing,
                    bearing(
                        from: segment.start.coordinate.clLocationCoordinate,
                        to: segment.end.coordinate.clLocationCoordinate
                    )
                ) <= 75 else {
                    return false
                }
                return distanceFromSegmentMeters(
                    sample.coordinate,
                    start: segment.start.coordinate.clLocationCoordinate,
                    end: segment.end.coordinate.clLocationCoordinate
                ) <= threshold
            }
        }
    }

    /// A stricter matcher used only to verify a manually queued practice
    /// route. Each planned sample consumes a later segment of the recorded
    /// trace, so proximity alone cannot turn a reversed or scattered trip into
    /// a route match. Familiarity deliberately remains a looser local cue.
    private static func orderedPracticeMatches(
        planned: [RouteProgressSample],
        trace: [DriveTraceSegment],
        threshold: CLLocationDistance
    ) -> OrderedRouteMatches {
        guard !planned.isEmpty, !trace.isEmpty else {
            return OrderedRouteMatches(flags: [], traceIndices: [], continuityGroups: [])
        }

        var group = 0
        var groups: [Int] = []
        for index in trace.indices {
            if index > 0, !traceSegmentsAreContinuous(trace[index - 1], trace[index]) {
                group += 1
            }
            groups.append(group)
        }

        var flags: [Bool] = []
        var traceIndices: [Int?] = []
        var continuityGroups: [Int?] = []
        var lastTraceIndex = -1

        for sample in planned {
            var matchedIndex: Int?
            if lastTraceIndex + 1 < trace.count {
                for index in (lastTraceIndex + 1)..<trace.count {
                    if traceSegment(trace[index], matches: sample, threshold: threshold) {
                        matchedIndex = index
                        break
                    }
                }
            }
            guard let index = matchedIndex else {
                flags.append(false)
                traceIndices.append(nil)
                continuityGroups.append(nil)
                continue
            }
            flags.append(true)
            traceIndices.append(index)
            continuityGroups.append(groups[index])
            lastTraceIndex = index
        }

        return OrderedRouteMatches(
            flags: flags,
            traceIndices: traceIndices,
            continuityGroups: continuityGroups
        )
    }

    private static func traceSegment(
        _ segment: DriveTraceSegment,
        matches sample: RouteProgressSample,
        threshold: CLLocationDistance
    ) -> Bool {
        guard directionDifferenceDegrees(
            sample.bearing,
            bearing(
                from: segment.start.coordinate.clLocationCoordinate,
                to: segment.end.coordinate.clLocationCoordinate
            )
        ) <= 60 else {
            return false
        }
        return distanceFromSegmentMeters(
            sample.coordinate,
            start: segment.start.coordinate.clLocationCoordinate,
            end: segment.end.coordinate.clLocationCoordinate
        ) <= threshold
    }

    private static func traceSegmentsAreContinuous(
        _ lhs: DriveTraceSegment,
        _ rhs: DriveTraceSegment
    ) -> Bool {
        lhs.endIndex == rhs.startIndex &&
            abs(rhs.start.timestamp.timeIntervalSince(lhs.end.timestamp)) < 0.01
    }

    private static func longestOrderedContinuousShare(
        _ matches: OrderedRouteMatches,
        limitedTo indices: [Int]? = nil
    ) -> Double {
        let selected = indices ?? Array(matches.flags.indices)
        guard !selected.isEmpty else { return 0 }
        var longest = 0
        var current = 0
        var previousSampleIndex: Int?
        var previousGroup: Int?

        for index in selected {
            let isMatched = matches.flags[index]
            let group = matches.continuityGroups[index]
            let continues = isMatched &&
                previousSampleIndex.map { $0 + 1 == index } == true &&
                previousGroup == group
            if continues {
                current += 1
            } else if isMatched {
                current = 1
            } else {
                current = 0
            }
            longest = max(longest, current)
            previousSampleIndex = index
            previousGroup = isMatched ? group : nil
        }
        return Double(longest) / Double(selected.count)
    }

    private static func routeDistanceMeters(for polyline: String) -> CLLocationDistance {
        let coordinates = RoutePolylineDecoder.decode(polyline).filter(CLLocationCoordinate2DIsValid)
        return zip(coordinates, coordinates.dropFirst()).reduce(0) {
            $0 + coordinateDistanceMeters(DriveCoordinate($1.0), DriveCoordinate($1.1))
        }
    }

    private static func share(of flags: [Bool]) -> Double {
        guard !flags.isEmpty else { return 0 }
        return Double(flags.filter { $0 }.count) / Double(flags.count)
    }

    private static func longestRunShare(of flags: [Bool]) -> Double {
        guard !flags.isEmpty else { return 0 }
        var longest = 0
        var current = 0
        for value in flags {
            if value {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return Double(longest) / Double(flags.count)
    }

    private static func evenlySampled<Element>(_ values: [Element], limit: Int) -> [Element] {
        guard values.count > limit else { return values }
        // A limit of 1 makes the divisor zero, so `step` becomes infinite and
        // `Int(_:)` traps rather than returning a clamped index. Callers pass
        // a constant today, but the trap is one careless caller away.
        guard limit > 1 else { return Array(values.prefix(max(0, limit))) }

        let step = Double(values.count - 1) / Double(limit - 1)
        let lastIndex = values.count - 1
        return (0..<limit).map { values[min(lastIndex, Int((Double($0) * step).rounded()))] }
    }

    private static func coordinateDistanceMeters(
        _ lhs: DriveCoordinate,
        _ rhs: DriveCoordinate
    ) -> CLLocationDistance {
        DriveExperienceEngine.coordinateDistanceMeters(lhs, rhs)
    }

    private static func interpolatedCoordinate(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        fraction: Double
    ) -> DriveCoordinate {
        let longitudeDelta = normalizedLongitudeDelta(end.longitude - start.longitude)
        return DriveCoordinate(
            CLLocationCoordinate2D(
                latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                longitude: start.longitude + longitudeDelta * fraction
            )
        )
    }

    private static func bearing(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> Double {
        let radians = Double.pi / 180
        let latitude1 = start.latitude * radians
        let latitude2 = end.latitude * radians
        let longitudeDelta = normalizedLongitudeDelta(end.longitude - start.longitude) * radians
        let y = sin(longitudeDelta) * cos(latitude2)
        let x = cos(latitude1) * sin(latitude2) - sin(latitude1) * cos(latitude2) * cos(longitudeDelta)
        let value = atan2(y, x) * 180 / Double.pi
        return (value + 360).truncatingRemainder(dividingBy: 360)
    }

    private static func directionDifferenceDegrees(_ lhs: Double, _ rhs: Double) -> Double {
        let difference = abs((lhs - rhs).truncatingRemainder(dividingBy: 360))
        return difference > 180 ? 360 - difference : difference
    }

    /// Local equirectangular projection is accurate enough for a nearby
    /// 60-meter comparison and avoids needing MapKit in this pure model.
    private static func distanceFromSegmentMeters(
        _ point: DriveCoordinate,
        start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        let earthRadius = 6_371_000.0
        let radians = Double.pi / 180
        let referenceLatitude = point.latitude * radians

        func projection(_ coordinate: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            let longitudeDelta = normalizedLongitudeDelta(coordinate.longitude - point.longitude) * radians
            return (
                x: longitudeDelta * earthRadius * cos(referenceLatitude),
                y: (coordinate.latitude - point.latitude) * radians * earthRadius
            )
        }

        let a = projection(start)
        let b = projection(end)
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(a.x, a.y) }
        let progress = min(1, max(0, -(a.x * dx + a.y * dy) / lengthSquared))
        return hypot(a.x + progress * dx, a.y + progress * dy)
    }

    private static func normalizedLongitudeDelta(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        if wrapped > 180 { return wrapped - 360 }
        if wrapped < -180 { return wrapped + 360 }
        return wrapped
    }
}
