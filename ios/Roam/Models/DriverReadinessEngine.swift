import CoreLocation
import Foundation

/// Identifiers for the readiness insights Roam generates locally.
///
/// Locally generated insights share one id namespace with backend route-demand
/// ids, and that list is later keyed by id. A reserved prefix makes a collision
/// structurally impossible: `RouteDemandKind` raw values are bare camel-case
/// names, and any backend id containing the prefix is still deduplicated by
/// `uniquedByID()` before the list leaves `assess`.
enum DriverReadinessInsightID {
    /// Reserved for client-generated insights. No backend demand id uses it.
    static let reservedPrefix = "roam.local."

    static let routeDemandsUnavailable = reservedPrefix + "routeDemandsUnavailable"
    static let drivingQuality = reservedPrefix + "drivingQuality"
    static let familiarity = reservedPrefix + "familiarity"
    static let history = reservedPrefix + "history"

    static func isSynthetic(_ id: String) -> Bool {
        id.hasPrefix(reservedPrefix)
    }
}

/// Pure local reasoning for “Can I drive this?” Route demands arrive from the
/// backend, but all history and route-overlap analysis stays on the device.
enum DriverReadinessEngine {

    static func assess(
        route: ScoredRoute,
        recordedDrives: [RecordedDrive]
    ) -> DriverReadinessAssessment {
        assess(
            route: route,
            recordedDrives: recordedDrives,
            configuration: Configuration(),
            calendar: .current,
            referenceDate: Date()
        )
    }

    /// Injectable time/configuration makes the local calculation deterministic
    /// in checks without adding mutable global state.
    static func assess(
        route: ScoredRoute,
        recordedDrives: [RecordedDrive],
        configuration: Configuration,
        calendar: Calendar,
        referenceDate: Date = Date()
    ) -> DriverReadinessAssessment {
        let qualifying = DriverReadinessProfileBuilder.qualifyingDrives(
            from: recordedDrives,
            configuration: configuration,
            calendar: calendar
        )
        let profile = DriverReadinessProfileBuilder.makeProfile(
            qualifyingDrives: qualifying,
            configuration: configuration,
            calendar: calendar,
            referenceDate: referenceDate
        )
        let familiarity = DriverReadinessRouteMatcher.familiarity(
            for: route,
            qualifyingDrives: qualifying,
            configuration: configuration
        )

        guard profile.hasEnoughRecordedExperience(using: configuration) else {
            let summary = historyRequirementSummary(profile: profile, configuration: configuration)
            return DriverReadinessAssessment(
                verdict: .insufficientHistory,
                headline: DriverReadinessVerdict.insufficientHistory.title,
                summary: summary,
                insights: [
                    historyInsight(profile: profile, configuration: configuration),
                    familiarityInsight(
                        familiarity,
                        routeMaxIntensity: (route.routeDemands ?? []).map(\.intensity).max() ?? 0
                    )
                ],
                profile: profile,
                familiarity: familiarity
            )
        }

        let routeDemands = route.routeDemands ?? []
        guard !routeDemands.isEmpty else {
            return DriverReadinessAssessment(
                verdict: .practiceWithAdult,
                headline: DriverReadinessVerdict.practiceWithAdult.title,
                summary: "Route demand details are not available yet, so this route cannot be compared with recorded experience.",
                insights: [
                    DriverReadinessInsight(
                        id: DriverReadinessInsightID.routeDemandsUnavailable,
                        title: "Route readiness details",
                        detail: "This route’s specific demands were not available to verify.",
                        state: .informational,
                        evidence: DriverReadinessEvidence(
                            source: .unavailable,
                            recordedValue: historyBaseText(profile),
                            comparisonTarget: nil,
                            routeEvidence: "Route demand data was unavailable.",
                            collectionNote: nil
                        )
                    ),
                    drivingQualityInsight(profile, configuration: configuration),
                    familiarityInsight(familiarity, routeMaxIntensity: 0)
                ],
                profile: profile,
                familiarity: familiarity
            )
        }

        let demandInsights = routeDemands.map {
            readinessInsight(
                for: $0,
                route: route,
                profile: profile,
                configuration: configuration,
                referenceDate: referenceDate
            )
        }
        let quality = drivingQualityInsight(profile, configuration: configuration)
        let familiarityInsightValue = familiarityInsight(
            familiarity,
            routeMaxIntensity: routeDemands.map(\.intensity).max() ?? 0
        )
        // Two duplicate ids are possible here even with the reserved prefix:
        // the backend may repeat a demand id. Deduplicating once, at the point
        // the list is built, means no later consumer can be handed a list that
        // traps when keyed by id — including a plan built from a persisted
        // assessment.
        let insights = (demandInsights + [quality, familiarityInsightValue]).uniquedByID()

        let demandByID = routeDemands.keyedByID()
        let demandGap = insights.contains { insight in
            guard let demand = demandByID[insight.id] else { return false }
            switch insight.state {
            case .practiceNeeded:
                return true
            case .unmeasured:
                return demand.available && demand.intensity >= 0.60
            case .matched, .informational:
                return false
            }
        }
        let behaviorGap = quality.state == .practiceNeeded
        let familiarityGap = familiarityInsightValue.state == .practiceNeeded
        let verdict: DriverReadinessVerdict = demandGap || behaviorGap || familiarityGap
            ? .practiceWithAdult
            : .looksLikeMatch

        let summary: String
        switch verdict {
        case .looksLikeMatch:
            summary = "\(historyBaseText(profile)). The measured route demands fit the experience this phone can compare."
        case .practiceWithAdult:
            summary = "\(historyBaseText(profile)). At least one meaningful route demand is new, lightly practiced, or not yet measured."
        case .insufficientHistory:
            summary = historyRequirementSummary(profile: profile, configuration: configuration)
        }

        return DriverReadinessAssessment(
            verdict: verdict,
            headline: verdict.title,
            summary: summary,
            insights: insights,
            profile: profile,
            familiarity: familiarity
        )
    }

    static func profile(from recordedDrives: [RecordedDrive]) -> DriverReadinessProfile {
        profile(
            from: recordedDrives,
            configuration: Configuration(),
            calendar: .current,
            referenceDate: Date()
        )
    }

    static func profile(
        from recordedDrives: [RecordedDrive],
        configuration: Configuration,
        calendar: Calendar,
        referenceDate: Date = Date()
    ) -> DriverReadinessProfile {
        DriverReadinessProfileBuilder.makeProfile(
            qualifyingDrives: DriverReadinessProfileBuilder.qualifyingDrives(
                from: recordedDrives,
                configuration: configuration,
                calendar: calendar
            ),
            configuration: configuration,
            calendar: calendar,
            referenceDate: referenceDate
        )
    }

    static func qualifies(
        _ drive: RecordedDrive,
        configuration: Configuration = Configuration(),
        calendar: Calendar = .current
    ) -> Bool {
        guard drive.score.dataQuality.confidence == .medium || drive.score.dataQuality.confidence == .high else {
            return false
        }
        let summary = DriveExperienceEngine.summary(for: drive, calendar: calendar)
        return summary.measuredMinutes >= configuration.minimumQualifyingDuration / 60 ||
            summary.measuredMiles >= configuration.minimumQualifyingMiles
    }

    /// Verifies a manually recorded drive substantially followed the route
    /// selected immediately before it. Long tracking gaps, reversed travel,
    /// and fragments from scattered road sections cannot verify the route.
    static func matchesPlannedPracticeRoute(
        plannedPolyline: String,
        recordedRoute: [DriveRoutePoint]
    ) -> Bool {
        DriverReadinessRouteMatcher.matchesPlannedPracticeRoute(
            plannedPolyline: plannedPolyline,
            recordedRoute: recordedRoute
        )
    }

    /// Calculates route and demand-specific coverage while the queued route
    /// polyline remains in memory. Callers persist only returned numeric
    /// demand evidence, never the plan's geometry.
    static func practiceRouteCoverage(
        plannedPolyline: String,
        recordedRoute: [DriveRoutePoint],
        demands: [RouteDemand],
        configuration: Configuration = Configuration()
    ) -> PracticeRouteCoverage {
        DriverReadinessRouteMatcher.practiceRouteCoverage(
            plannedPolyline: plannedPolyline,
            recordedRoute: recordedRoute,
            demands: demands,
            configuration: configuration
        )
    }

    private static func readinessInsight(
        for demand: RouteDemand,
        route: ScoredRoute,
        profile: DriverReadinessProfile,
        configuration: Configuration,
        referenceDate: Date
    ) -> DriverReadinessInsight {
        let routeEvidence = demand.evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard demand.available else {
            return DriverReadinessInsight(
                id: demand.id,
                title: demand.title,
                detail: "\(routeEvidence) This route characteristic was not available to compare.",
                state: .informational,
                evidence: DriverReadinessEvidence(
                    source: .unavailable,
                    recordedValue: historyBaseText(profile),
                    comparisonTarget: nil,
                    routeEvidence: routeEvidence,
                    collectionNote: "Roam leaves unavailable route data out rather than estimating it."
                )
            )
        }
        guard demand.level != .low && demand.intensity >= 0.34 else {
            return DriverReadinessInsight(
                id: demand.id,
                title: demand.title,
                detail: "\(routeEvidence) This is a lower-demand part of this route.",
                state: .informational,
                evidence: DriverReadinessEvidence(
                    source: .gpsMotion,
                    recordedValue: historyBaseText(profile),
                    comparisonTarget: nil,
                    routeEvidence: routeEvidence,
                    collectionNote: nil
                )
            )
        }

        switch demand.kind {
        case .afterDark:
            let target = max(
                2,
                min(20, demand.metrics?["nightMiles"] ?? route.distanceMiles * demand.intensity)
            )
            return exposureInsight(
                demand: demand,
                exposure: profile.nightExposure,
                targetMiles: target,
                requiredSessions: demand.intensity >= 0.67 ? 2 : 1,
                experienceName: "after-dark driving",
                routeEvidence: routeEvidence,
                configuration: configuration,
                referenceDate: referenceDate
            )
        case .fastRoads:
            let estimated65Miles = demand.metrics?["estimatedMilesAt65"] ?? 0
            let estimated60Miles = demand.metrics?["estimatedMilesAt60"] ?? 0
            let expected45Miles = demand.metrics?["estimatedMilesAt45"] ?? route.distanceMiles * demand.intensity
            let meaningfulRouteShare = max(1, route.distanceMiles * 0.12)
            let requiredBand: Int
            let routeBandMiles: Double
            let exposure: DriverExperienceExposure
            if estimated65Miles >= meaningfulRouteShare {
                requiredBand = 65
                routeBandMiles = estimated65Miles
                exposure = profile.fastRoad65Exposure
            } else if estimated60Miles >= meaningfulRouteShare {
                requiredBand = 60
                routeBandMiles = estimated60Miles
                exposure = profile.fastRoad60Exposure
            } else {
                requiredBand = 45
                routeBandMiles = expected45Miles
                exposure = profile.fastRoad45Exposure
            }
            let target = max(
                requiredBand >= 60 ? 2.5 : 2,
                min(25, routeBandMiles * 0.75)
            )
            return exposureInsight(
                demand: demand,
                exposure: exposure,
                targetMiles: target,
                requiredSessions: demand.intensity >= 0.67 ? 2 : 1,
                experienceName: "\(requiredBand)+ mph driving",
                routeEvidence: routeEvidence,
                configuration: configuration,
                referenceDate: referenceDate
            )
        case .sustainedDrive:
            let expectedMinutes = demand.metrics?["expectedDurationMinutes"] ?? Double(route.durationSeconds) / 60
            let target = max(15 * 60, expectedMinutes * 60 * 0.80)
            let secondSessionTarget = target * 0.50
            let requiredSessions = demand.intensity >= 0.67 ? 2 : 1
            let episodes = profile.sustainedExposure.episodes
            let comparableEpisodes = episodes.filter { $0.duration >= target }
            let supportingEpisodes = episodes.filter { $0.duration >= secondSessionTarget }
            let recentSupportingEpisodes = supportingEpisodes.filter {
                isWithinRecentWindow($0.recordedAt, referenceDate: referenceDate, configuration: configuration)
            }
            let mostRecentComparable = comparableEpisodes.map(\.recordedAt).max()
            let hasFreshComparableLongest = comparableEpisodes.contains {
                !isStale($0.recordedAt, referenceDate: referenceDate, configuration: configuration)
            }
            let hasRepeatedPractice = recentSupportingEpisodes.count >= requiredSessions
            let state: DriverReadinessInsightState = hasFreshComparableLongest && hasRepeatedPractice
                ? .matched
                : .practiceNeeded
            let targetText = "\(durationText(target)) continuous trace"
            let recordText = "longest continuous trace: \(durationText(profile.sustainedExposure.longestEpisodeDuration)) · \(recentSupportingEpisodes.count) recent \(durationText(secondSessionTarget))+ session\(recentSupportingEpisodes.count == 1 ? "" : "s")"
            let detail: String
            if state == .matched {
                detail = "\(routeEvidence) Your \(recordText) is comparable with this trip."
            } else if isStale(mostRecentComparable, referenceDate: referenceDate, configuration: configuration) {
                detail = "\(routeEvidence) Your \(recordText) includes a longer drive, but it is not recent enough to use as a current comparison."
            } else if profile.sustainedExposure.longestEpisodeDuration >= secondSessionTarget {
                detail = "\(routeEvidence) Your \(recordText) is a start; a longer supervised practice drive would make this comparison stronger."
            } else {
                detail = "\(routeEvidence) Your \(recordText) is shorter than this route’s measured drive time."
            }
            return DriverReadinessInsight(
                id: demand.id,
                title: demand.title,
                detail: detail,
                state: state,
                evidence: DriverReadinessEvidence(
                    source: .gpsMotion,
                    recordedValue: recordText,
                    comparisonTarget: requiredSessions > 1
                        ? "\(targetText), plus \(requiredSessions) recent sessions of at least \(durationText(secondSessionTarget))"
                        : targetText,
                    routeEvidence: routeEvidence,
                    collectionNote: "Only continuous GPS trace time is used; background gaps are not joined, and a long drive is not carried forward indefinitely."
                )
            )
        case .merges, .complexIntersections:
            return taggedDemandInsight(
                demand: demand,
                profile: profile,
                configuration: configuration,
                referenceDate: referenceDate,
                routeEvidence: routeEvidence,
                conditionSnapshot: false
            )
        case .weatherVisibility, .traffic, .roadConditions:
            return taggedDemandInsight(
                demand: demand,
                profile: profile,
                configuration: configuration,
                referenceDate: referenceDate,
                routeEvidence: routeEvidence,
                conditionSnapshot: true
            )
        case .none:
            return DriverReadinessInsight(
                id: demand.id,
                title: demand.title,
                detail: "\(routeEvidence) Experience with this route demand is not yet measured.",
                state: .unmeasured,
                evidence: DriverReadinessEvidence(
                    source: .unavailable,
                    recordedValue: "No comparable on-device record",
                    comparisonTarget: nil,
                    routeEvidence: routeEvidence,
                    collectionNote: nil
                )
            )
        }
    }

    private static func exposureInsight(
        demand: RouteDemand,
        exposure: DriverExperienceExposure,
        targetMiles: Double,
        requiredSessions: Int,
        experienceName: String,
        routeEvidence: String,
        configuration: Configuration,
        referenceDate: Date
    ) -> DriverReadinessInsight {
        let stale = isStale(exposure.lastRecordedAt, referenceDate: referenceDate, configuration: configuration)
        let requiredRecentMiles = min(targetMiles, max(1.5, targetMiles * 0.25))
        let requiredRecentSessions = min(requiredSessions, 2)
        let sufficient = exposure.effectiveMiles >= targetMiles &&
            exposure.sessionCount >= requiredSessions &&
            exposure.recentMiles >= requiredRecentMiles &&
            exposure.recentSessionCount >= requiredRecentSessions &&
            !stale
        let state: DriverReadinessInsightState = sufficient ? .matched : .practiceNeeded
        let recordText = "\(milesText(exposure.miles)) saved · \(milesText(exposure.recentMiles)) in the last \(Int(configuration.recentWindowDays)) days · \(exposure.sessionCount) qualifying \(driveWord(exposure.sessionCount))"
        let targetText = "about \(milesText(targetMiles)) of recency-weighted practice, including \(milesText(requiredRecentMiles)) recently across \(requiredSessions) \(driveWord(requiredSessions))"
        let recency = recencyText(exposure.lastRecordedAt, referenceDate: referenceDate)
        let detail: String
        if sufficient {
            detail = "\(routeEvidence) \(recordText) of \(experienceName) is saved on this phone\(recency)."
        } else if stale {
            detail = "\(routeEvidence) \(recordText) is saved, but the last comparable drive was\(recency). A recent supervised refresh would make this comparison stronger."
        } else if exposure.recentMiles < requiredRecentMiles || exposure.recentSessionCount < requiredRecentSessions {
            detail = "\(routeEvidence) \(recordText) of \(experienceName) is saved, but more recent measured practice is needed before this route can be compared."
        } else {
            detail = "\(routeEvidence) \(recordText) of \(experienceName) is saved; this route calls for \(targetText)."
        }
        return DriverReadinessInsight(
            id: demand.id,
            title: demand.title,
            detail: detail,
            state: state,
            evidence: DriverReadinessEvidence(
                source: .gpsMotion,
                recordedValue: recordText,
                comparisonTarget: targetText,
                routeEvidence: routeEvidence,
                collectionNote: "Speed exposure requires continuous GPS samples at or above the band; one GPS spike is not credited."
            )
        )
    }

    private static func taggedDemandInsight(
        demand: RouteDemand,
        profile: DriverReadinessProfile,
        configuration: Configuration,
        referenceDate: Date,
        routeEvidence: String,
        conditionSnapshot: Bool
    ) -> DriverReadinessInsight {
        let comparable = profile.taggedPractice(for: demand.id).filter {
            $0.coveredShare >= configuration.practiceCoverageThreshold &&
                $0.demandIntensity >= max(0.34, demand.intensity * 0.75)
        }
        let driveIDs = Set(comparable.map(\.driveID))
        let requiredSessions = demand.intensity >= 0.67 ? 2 : 1
        let recentDriveIDs = Set(comparable.filter {
            isWithinRecentWindow($0.recordedAt, referenceDate: referenceDate, configuration: configuration)
        }.map(\.driveID))
        let last = comparable.map(\.recordedAt).max()
        let stale = isStale(last, referenceDate: referenceDate, configuration: configuration)
        let hasEnough = driveIDs.count >= requiredSessions &&
            recentDriveIDs.count >= requiredSessions &&
            !stale
        let recordText: String
        if driveIDs.isEmpty {
            recordText = "No demand-specific, route-covered practice drive is saved"
        } else {
            let averageCoverage = comparable.map(\.coveredShare).reduce(0, +) / Double(comparable.count)
            recordText = "\(driveIDs.count) route-covered practice \(driveWord(driveIDs.count)) · \(recentDriveIDs.count) recent · average mapped coverage \(percentText(averageCoverage))"
        }
        let note = conditionSnapshot
            ? "This records coverage of a route planned with that live-condition demand; it does not guarantee today’s weather, traffic, or road conditions."
            : "Only GPS coverage of the demand’s mapped route section is counted."

        if hasEnough {
            return DriverReadinessInsight(
                id: demand.id,
                title: demand.title,
                detail: "\(routeEvidence) \(recordText) is saved on this phone\(recencyText(last, referenceDate: referenceDate)).",
                state: .matched,
                evidence: DriverReadinessEvidence(
                    source: .taggedPractice,
                    recordedValue: recordText,
                    comparisonTarget: "\(requiredSessions) route-covered practice \(driveWord(requiredSessions))",
                    routeEvidence: routeEvidence,
                    collectionNote: note
                )
            )
        }

        let state: DriverReadinessInsightState = driveIDs.isEmpty ? .unmeasured : .practiceNeeded
        let ending: String
        if driveIDs.isEmpty {
            ending = "This demand is not yet measured. A manual practice drive needs to cover the mapped part of a planned route before it can be compared."
        } else if stale {
            ending = "The last comparable practice drive was\(recencyText(last, referenceDate: referenceDate)); a recent supervised refresh would make this comparison stronger."
        } else if recentDriveIDs.count < requiredSessions {
            ending = "This route needs \(requiredSessions) recent comparable route-covered practice \(driveWord(requiredSessions))."
        } else {
            ending = "This route needs \(requiredSessions) comparable route-covered practice \(driveWord(requiredSessions))."
        }
        return DriverReadinessInsight(
            id: demand.id,
            title: demand.title,
            detail: "\(routeEvidence) \(recordText). \(ending)",
            state: state,
            evidence: DriverReadinessEvidence(
                source: .taggedPractice,
                recordedValue: recordText,
                comparisonTarget: "\(requiredSessions) route-covered practice \(driveWord(requiredSessions))",
                routeEvidence: routeEvidence,
                collectionNote: note
            )
        )
    }

    private static func drivingQualityInsight(
        _ profile: DriverReadinessProfile,
        configuration: Configuration
    ) -> DriverReadinessInsight {
        let behavior = profile.behavior
        guard behavior.recentMeasuredMiles >= configuration.minimumRecentQualityMiles,
              let recentRate = behavior.recentWeightedEventRatePerTenMiles,
              let recentScore = behavior.recentWeightedAverageScore else {
            return DriverReadinessInsight(
                id: DriverReadinessInsightID.drivingQuality,
                title: "Recent driving quality",
                detail: "Recent coaching-event data is still thin, so it is not being used to judge this route.",
                state: .unmeasured,
                evidence: DriverReadinessEvidence(
                    source: .gpsMotion,
                    recordedValue: "\(milesText(behavior.recentMeasuredMiles)) of recent trace-backed driving",
                    comparisonTarget: "\(milesText(configuration.minimumRecentQualityMiles)) of recent driving",
                    routeEvidence: "Driving quality is reviewed separately from route exposure.",
                    collectionNote: "Rates use Roam’s existing braking, acceleration, cornering, and phone-motion coaching events."
                )
            )
        }

        let needsPractice = recentRate > 3.5 || recentScore < 75
        let recordText = "last \(milesText(behavior.recentMeasuredMiles)) · \(String(format: "%.1f", recentRate)) weighted coaching events per 10 mi · \(UntrustedNumber.roundedInt(recentScore))/100"
        let detail: String
        if needsPractice {
            detail = "Recent trace-backed drives show \(recordText). Continue practicing smooth braking, acceleration, and turns before adding more demand."
        } else {
            detail = "Recent trace-backed drives show \(recordText). Keep using those calm driving habits on a new route."
        }
        return DriverReadinessInsight(
            id: DriverReadinessInsightID.drivingQuality,
            title: "Recent driving quality",
            detail: detail,
            state: needsPractice ? .practiceNeeded : .matched,
            evidence: DriverReadinessEvidence(
                source: .gpsMotion,
                recordedValue: recordText,
                comparisonTarget: "Recent, trace-backed coaching data",
                routeEvidence: "Quality is coaching context, not a safety guarantee.",
                collectionNote: "Short or low-confidence drives do not contribute."
            )
        )
    }

    private static func historyInsight(
        profile: DriverReadinessProfile,
        configuration: Configuration
    ) -> DriverReadinessInsight {
        let recordText = historyBaseText(profile)
        let target = "\(configuration.minimumHistoryDriveCount) qualifying drives on \(configuration.minimumHistoryDayCount) days · \(milesText(configuration.minimumHistoryMiles)) · \(durationText(configuration.minimumHistoryTraceDuration))"
        return DriverReadinessInsight(
            id: DriverReadinessInsightID.history,
            title: "Recorded history",
            detail: "\(recordText). Roam needs more repeated, trace-backed driving before comparing this route with confidence.",
            state: .informational,
            evidence: DriverReadinessEvidence(
                source: .gpsMotion,
                recordedValue: recordText,
                comparisonTarget: target,
                routeEvidence: "A route comparison needs repeated measured practice, not a single trip.",
                collectionNote: "Only medium- or high-confidence GPS and motion records count."
            )
        )
    }

    private static func historyRequirementSummary(
        profile: DriverReadinessProfile,
        configuration: Configuration
    ) -> String {
        if profile.qualifyingDriveCount == 0 {
            return "No qualifying GPS and motion drives are saved yet. Record a few manual drives before using this comparison."
        }
        return "\(historyBaseText(profile)). Save a few more qualifying drives on different days before relying on a route comparison."
    }

    private static func familiarityInsight(
        _ familiarity: RouteFamiliarity,
        routeMaxIntensity: Double
    ) -> DriverReadinessInsight {
        let percentage = percentText(familiarity.matchedShare)
        let recordText = familiarity.sampledPointCount == 0
            ? "No usable local GPS overlap"
            : "\(percentage) of sampled route distance overlaps saved, directionally aligned GPS traces"
        switch familiarity.level {
        case .unmeasured:
            return DriverReadinessInsight(
                id: DriverReadinessInsightID.familiarity,
                title: "Route familiarity",
                detail: "Route overlap has not yet been measured because saved qualifying drives need usable continuous GPS traces.",
                state: .unmeasured,
                evidence: DriverReadinessEvidence(
                    source: .routeOverlap,
                    recordedValue: recordText,
                    comparisonTarget: nil,
                    routeEvidence: "Familiarity is calculated on-device from local GPS traces.",
                    collectionNote: nil
                )
            )
        case .unfamiliar:
            let needsPractice = routeMaxIntensity >= 0.60
            return DriverReadinessInsight(
                id: DriverReadinessInsightID.familiarity,
                title: "Route familiarity",
                detail: "\(recordText). \(needsPractice ? "Practice the route with an adult before relying on familiarity." : "This route is not familiar yet, but the route-demand comparison above remains separate.")",
                state: needsPractice ? .practiceNeeded : .informational,
                evidence: DriverReadinessEvidence(
                    source: .routeOverlap,
                    recordedValue: recordText,
                    comparisonTarget: nil,
                    routeEvidence: "Only continuous traces traveling in the planned direction are matched.",
                    collectionNote: "Parallel roads and long GPS gaps are excluded."
                )
            )
        case .partlyFamiliar:
            return DriverReadinessInsight(
                id: DriverReadinessInsightID.familiarity,
                title: "Route familiarity",
                detail: "\(recordText) across \(familiarity.matchingDriveCount) saved \(driveWord(familiarity.matchingDriveCount)).",
                state: .matched,
                evidence: DriverReadinessEvidence(
                    source: .routeOverlap,
                    recordedValue: recordText,
                    comparisonTarget: nil,
                    routeEvidence: "Part of the route has been driven before.",
                    collectionNote: nil
                )
            )
        case .familiar:
            return DriverReadinessInsight(
                id: DriverReadinessInsightID.familiarity,
                title: "Route familiarity",
                detail: "\(recordText); the best single saved drive covered \(percentText(familiarity.bestSingleDriveShare)) of the route.",
                state: .matched,
                evidence: DriverReadinessEvidence(
                    source: .routeOverlap,
                    recordedValue: recordText,
                    comparisonTarget: nil,
                    routeEvidence: "Most of this route overlaps a continuous saved drive.",
                    collectionNote: nil
                )
            )
        }
    }

    private static func isStale(
        _ date: Date?,
        referenceDate: Date,
        configuration: Configuration
    ) -> Bool {
        guard let date else { return true }
        return referenceDate.timeIntervalSince(date) > configuration.staleExperienceDays * 86_400
    }

    private static func isWithinRecentWindow(
        _ date: Date,
        referenceDate: Date,
        configuration: Configuration
    ) -> Bool {
        let age = referenceDate.timeIntervalSince(date)
        return age >= 0 && age <= configuration.recentWindowDays * 86_400
    }

    private static func historyBaseText(_ profile: DriverReadinessProfile) -> String {
        "\(profile.qualifyingDriveCount) qualifying \(driveWord(profile.qualifyingDriveCount)) · \(milesText(profile.reliableTraceMiles)) of validated GPS trace · \(profile.qualifyingDriveDayCount) \(profile.qualifyingDriveDayCount == 1 ? "day" : "days")"
    }

    private static func milesText(_ miles: Double) -> String {
        String(format: "%.1f mi", max(0, miles))
    }

    /// `duration` can originate in an unvalidated backend metric, so the
    /// `Int` conversion saturates rather than trapping.
    private static func durationText(_ duration: TimeInterval) -> String {
        let minutes = max(0, UntrustedNumber.roundedInt(duration / 60))
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes) min"
    }

    private static func driveWord(_ count: Int) -> String {
        count == 1 ? "drive" : "drives"
    }

    private static func percentText(_ value: Double) -> String {
        "\(UntrustedNumber.roundedInt(UntrustedNumber.unitFraction(value) * 100))%"
    }

    /// A decoded `Date` can be arbitrarily far from `referenceDate`, so the day
    /// count saturates rather than trapping on the `Int` conversion.
    private static func recencyText(_ date: Date?, referenceDate: Date) -> String {
        guard let date else { return "" }
        let days = max(0, UntrustedNumber.roundedInt(
            referenceDate.timeIntervalSince(date) / 86_400,
            rule: .down
        ))
        if days == 0 { return " today" }
        if days == 1 { return " 1 day ago" }
        return " \(days) days ago"
    }
}
