import CoreLocation
import Foundation

@main
struct RoutePracticeEnginesChecks {
    static func main() throws {
        let calendar = utcCalendar()
        let referenceDate = makeDate(2026, 7, 17, 18, 0, calendar: calendar)
        let configuration = DriverReadinessEngine.Configuration(
            minimumQualifyingDuration: 2,
            minimumQualifyingMiles: 0.01,
            minimumHistoryDriveCount: 3,
            minimumHistoryDayCount: 3,
            minimumHistoryMiles: 0.04,
            minimumHistoryTraceDuration: 5,
            minimumRecentQualityMiles: 0.01,
            minimumRecentHistoryMiles: 0.01,
            minimumRecentHistoryDriveCount: 1,
            recentWindowDays: 90,
            staleExperienceDays: 180,
            experienceHalfLifeDays: 120
        )

        let steadyHistory = (1...3).map {
            drive(
                startedAt: referenceDate.addingTimeInterval(TimeInterval(-$0 * 86_400)),
                score: 92
            )
        }
        let lowQualityHistory = (1...3).map {
            drive(
                startedAt: referenceDate.addingTimeInterval(TimeInterval(-$0 * 86_400)),
                score: 60
            )
        }

        let primary = route(
            polyline: "primary-route",
            score: 6.5,
            duration: 760,
            demands: [demand(.afterDark, intensity: 0.10, level: .low)]
        )
        let hardAlternate = route(
            polyline: "hard-alternate",
            score: 4.0,
            duration: 620,
            demands: [demand(.merges, intensity: 0.90, level: .high)]
        )
        let unavailableAlternate = route(
            polyline: "unavailable-alternate",
            score: 7.5,
            duration: 700,
            demands: [
                RouteDemand(
                    id: RouteDemandKind.merges.rawValue,
                    intensity: 0.95,
                    level: .high,
                    evidence: "Merge data was unavailable.",
                    available: false
                )
            ]
        )

        let ranked = RouteChoiceRankingEngine.rank(
            primaryRoute: primary,
            alternateRoutes: [hardAlternate, unavailableAlternate],
            recordedDrives: steadyHistory,
            configuration: configuration,
            calendar: calendar,
            referenceDate: referenceDate
        )
        expect(!ranked.comparisonLimitedByHistory, "enough qualifying history should enable readiness ranking")
        expect(ranked.initialSelectedRouteID == primary.id, "the primary route must remain selected by default")
        expect(ranked.choices.first?.route.id == primary.id, "a matched route should outrank an easier but unmeasured high-demand route")
        expect(ranked.bestFitRouteID == primary.id, "the first matched route should receive the best-fit designation")
        expect(ranked.lowestDifficultyRouteID == hardAlternate.id, "the lowest numeric route difficulty should remain visible separately")
        expect(
            ranked.choice(for: primary.id)?.badges == [.bestFit],
            "the matching route should receive the best-fit badge"
        )
        expect(
            ranked.choice(for: hardAlternate.id)?.badges == [.lowestDifficulty],
            "the easier alternate should keep its lowest-difficulty badge when it differs from best fit"
        )
        expect(
            ranked.choice(for: unavailableAlternate.id)?.meaningfulGapCount == 0,
            "unavailable route enrichment must not become a readiness gap"
        )
        expect(
            !ranked.choice(for: unavailableAlternate.id)!.badges.contains(.bestFit),
            "unavailable route enrichment must not receive a personalized best-fit claim"
        )
        expect(
            ranked.selectedRouteID(preserving: hardAlternate.id) == hardAlternate.id,
            "a user-selected alternate must survive a ranking refresh"
        )
        expect(
            ranked.selectedRouteID(preserving: "missing-route") == primary.id,
            "a no-longer-returned route should fall back to the primary selection"
        )

        let limited = RouteChoiceRankingEngine.rank(
            primaryRoute: primary,
            alternateRoutes: [hardAlternate],
            recordedDrives: [],
            configuration: configuration,
            calendar: calendar,
            referenceDate: referenceDate
        )
        expect(limited.comparisonLimitedByHistory, "empty history should surface an honest comparison limitation")
        expect(limited.bestFitRouteID == nil, "thin history must never nominate a best experience fit")
        expect(limited.choices.first?.route.id == hardAlternate.id, "thin history should order routes by difficulty")

        let tiedAlternate = route(
            polyline: "tied-alternate",
            score: primary.score,
            duration: primary.durationSeconds,
            demands: primary.routeDemands ?? []
        )
        let ties = RouteChoiceRankingEngine.rank(
            primaryRoute: primary,
            alternateRoutes: [tiedAlternate],
            recordedDrives: [],
            configuration: configuration,
            calendar: calendar,
            referenceDate: referenceDate
        )
        expect(ties.choices.map(\.route.id) == [primary.id, tiedAlternate.id], "full ordering ties must retain API order")

        let keyBefore = RouteChoiceRankingEngine.cacheKey(
            primaryRoute: primary,
            alternateRoutes: [hardAlternate],
            recordedDrives: steadyHistory
        )
        let keyAfter = RouteChoiceRankingEngine.cacheKey(
            primaryRoute: primary,
            alternateRoutes: [hardAlternate],
            recordedDrives: steadyHistory + [drive(startedAt: referenceDate, score: 92)]
        )
        expect(keyBefore != keyAfter, "a saved-drive change must invalidate a cached readiness ranking")

        let insufficientAssessment = DriverReadinessEngine.assess(
            route: primary,
            recordedDrives: [],
            configuration: configuration,
            calendar: calendar,
            referenceDate: referenceDate
        )
        let historyPlan = PracticePlanEngine.makePlan(
            assessment: insufficientAssessment,
            route: primary,
            createdAt: referenceDate
        )
        expect(historyPlan.goals.first?.kind == .buildRecordedHistory, "missing qualifying history should be the first practice goal")
        expect(historyPlan.goals.first?.requiresAdultSupervision == true, "history goals should use adult-supervision coaching")

        let demandingRoute = route(
            polyline: "demanding-route",
            score: 7.5,
            duration: 960,
            demands: [
                demand(.merges, intensity: 0.95, level: .high),
                demand(.complexIntersections, intensity: 0.85, level: .high),
                demand(.weatherVisibility, intensity: 0.75, level: .high),
                demand(.traffic, intensity: 0.70, level: .high)
            ]
        )
        let demandAssessment = DriverReadinessEngine.assess(
            route: demandingRoute,
            recordedDrives: steadyHistory,
            configuration: configuration,
            calendar: calendar,
            referenceDate: referenceDate
        )
        let demandPlan = PracticePlanEngine.makePlan(
            assessment: demandAssessment,
            route: demandingRoute,
            createdAt: referenceDate
        )
        expect(demandPlan.goals.count == 3, "practice plans must cap goals at three")
        expect(
            demandPlan.goals.allSatisfy { $0.kind == .routeDemand },
            "unmeasured high-intensity route demands should take priority over less specific coaching"
        )
        expect(
            demandPlan.goals.map(\.demandID) == ["merges", "complexIntersections", "weatherVisibility"],
            "higher-intensity demands should have a stable priority order"
        )

        let qualityAssessment = DriverReadinessEngine.assess(
            route: primary,
            recordedDrives: lowQualityHistory,
            configuration: configuration,
            calendar: calendar,
            referenceDate: referenceDate
        )
        let qualityPlan = PracticePlanEngine.makePlan(
            assessment: qualityAssessment,
            route: primary,
            createdAt: referenceDate
        )
        expect(qualityPlan.goals.map(\.kind) == [.drivingQuality], "quality coaching should appear only when measured history supports it")

        let beforeProfile = DriverReadinessEngine.profile(
            from: steadyHistory,
            configuration: configuration,
            calendar: calendar,
            referenceDate: referenceDate
        )
        let practiceDrive = drive(startedAt: referenceDate, score: 90)
        let afterProfile = DriverReadinessEngine.profile(
            from: steadyHistory + [practiceDrive],
            configuration: configuration,
            calendar: calendar,
            referenceDate: referenceDate
        )
        let debriefPlan = PracticePlan(
            id: UUID(uuidString: "9C6AD2C7-9E45-4B2A-A755-76A2A2C5C611")!,
            createdAt: referenceDate,
            goals: [PracticeGoal(id: "demand:merges", kind: .routeDemand, demandID: "merges")]
        )
        let verifiedCoverage = PracticeRouteCoverageSummary(
            recordedAt: referenceDate,
            overallCoverage: 0.92,
            longestContinuousCoverage: 0.88,
            originCoverage: 0.90,
            destinationCoverage: 0.91,
            demandCoverage: [
                PracticeDemandCoverage(
                    demandID: "merges",
                    demandIntensity: 0.95,
                    coveredShare: 0.90,
                    routeShare: 0.15
                )
            ]
        )
        let verifiedDebrief = PracticePlanEngine.makeDebrief(
            plan: debriefPlan,
            savedDrive: practiceDrive,
            coverage: verifiedCoverage,
            profileBefore: beforeProfile,
            profileAfter: afterProfile,
            configuration: configuration,
            calendar: calendar,
            createdAt: referenceDate
        )
        expect(verifiedDebrief.outcome == .verifiedRoutePractice, "full continuous planned-route coverage should verify practice")
        expect(verifiedDebrief.goalCompletions.first?.status == .measured, "covered demand goals should be marked measured")

        let partialCoverage = PracticeRouteCoverageSummary(
            recordedAt: referenceDate,
            overallCoverage: 0.45,
            longestContinuousCoverage: 0.32,
            originCoverage: 0.60,
            destinationCoverage: 0.10,
            demandCoverage: [
                PracticeDemandCoverage(
                    demandID: "merges",
                    demandIntensity: 0.95,
                    coveredShare: 0.45,
                    routeShare: 0.15
                )
            ]
        )
        let partialDebrief = PracticePlanEngine.makeDebrief(
            plan: debriefPlan,
            savedDrive: practiceDrive,
            coverage: partialCoverage,
            profileBefore: beforeProfile,
            profileAfter: afterProfile,
            configuration: configuration,
            calendar: calendar,
            createdAt: referenceDate
        )
        expect(partialDebrief.outcome == .partialRouteCoverage, "partial local coverage must not be called full-route practice")
        expect(partialDebrief.goalCompletions.first?.status == .needsMorePractice, "partial demand coverage should remain a practice target")
        expect(partialDebrief.goalCompletions.first?.wasMeasuredToday == true, "partial coverage should still be clearly shown as measured today")

        let missingGPSDebrief = PracticePlanEngine.makeDebrief(
            plan: debriefPlan,
            savedDrive: practiceDrive,
            coverage: nil,
            profileBefore: beforeProfile,
            profileAfter: afterProfile,
            configuration: configuration,
            calendar: calendar,
            createdAt: referenceDate
        )
        expect(missingGPSDebrief.outcome == .insufficientGPSCoverage, "missing route coverage must have an explicit debrief state")
        expect(missingGPSDebrief.goalCompletions.first?.status == .notMeasured, "no coverage should not mark a demand as measured")

        let preliminaryDrive = drive(startedAt: referenceDate, score: 90, confidence: .low)
        let preliminaryDebrief = PracticePlanEngine.makeDebrief(
            plan: debriefPlan,
            savedDrive: preliminaryDrive,
            coverage: verifiedCoverage,
            profileBefore: beforeProfile,
            profileAfter: afterProfile,
            configuration: configuration,
            calendar: calendar,
            createdAt: referenceDate
        )
        expect(preliminaryDebrief.outcome == .savedNotYetQualifying, "a preliminary saved drive must not change readiness evidence")

        let encodedPlan = try JSONEncoder().encode(demandPlan)
        let restoredPlan = try JSONDecoder().decode(PracticePlan.self, from: encodedPlan)
        expect(restoredPlan == demandPlan, "practice plans should round-trip through local persistence")
        let encodedText = String(decoding: encodedPlan, as: UTF8.self).lowercased()
        expect(!encodedText.contains("polyline"), "practice plans must not persist route polylines")
        expect(!encodedText.contains("latitude"), "practice plans must not persist route coordinates")
        expect(!encodedText.contains("longitude"), "practice plans must not persist route coordinates")
        expect(!encodedText.contains("address"), "practice plans must not persist route addresses")
        let encodedDebriefText = String(
            decoding: try JSONEncoder().encode(verifiedDebrief),
            as: UTF8.self
        ).lowercased()
        expect(!encodedDebriefText.contains("polyline"), "practice debriefs must not persist route polylines")
        expect(!encodedDebriefText.contains("latitude"), "practice debriefs must not persist route coordinates")
        expect(!encodedDebriefText.contains("longitude"), "practice debriefs must not persist route coordinates")
        expect(!encodedDebriefText.contains("motionsamples"), "practice debriefs must not persist raw motion measurements")

        let persistedContext = PlannedRouteContext(
            routeDemands: demandingRoute.routeDemands ?? [],
            recordedRouteMatched: true,
            verifiedDemandExposures: verifiedCoverage.verifiedDemandExposures(),
            practicePlan: demandPlan,
            coverageSummary: verifiedCoverage,
            debrief: verifiedDebrief
        )
        let encodedContext = try JSONEncoder().encode(persistedContext)
        let encodedContextText = String(decoding: encodedContext, as: UTF8.self).lowercased()
        expect(!encodedContextText.contains("polyline"), "saved practice contexts must not persist planned polylines")
        expect(!encodedContextText.contains("latitude"), "saved practice contexts must not persist planned coordinates")
        expect(!encodedContextText.contains("longitude"), "saved practice contexts must not persist planned coordinates")
        expect(!encodedContextText.contains("motionsamples"), "saved practice contexts must not persist raw motion samples")
        let contextObject = try JSONSerialization.jsonObject(with: encodedContext) as! [String: Any]
        let savedTags = contextObject["routeDemandTags"] as! [[String: Any]]
        expect(
            savedTags.allSatisfy { Set($0.keys) == Set(["id"]) },
            "saved practice demand tags must retain only stable demand IDs"
        )
        let decodedContext = try JSONDecoder().decode(PlannedRouteContext.self, from: encodedContext)
        expect(decodedContext.practicePlan == demandPlan, "saved practice plans should round-trip with a route context")
        expect(decodedContext.debrief == verifiedDebrief, "saved debriefs should round-trip with a route context")

        try checkUntrustedInputHardening(
            history: steadyHistory,
            configuration: configuration,
            calendar: calendar,
            referenceDate: referenceDate
        )

        print("RoutePracticeEngines checks passed")
    }

    // MARK: - Untrusted backend and persisted input

    /// Every check below fails by trapping rather than by returning `false` on
    /// the unfixed engines: each input is one the trapping form of the code
    /// turns into a process kill. Reaching the `expect` at all is half the
    /// assertion.
    private static func checkUntrustedInputHardening(
        history: [RecordedDrive],
        configuration: DriverReadinessEngine.Configuration,
        calendar: Calendar,
        referenceDate: Date
    ) throws {
        // Finding 1 — a repeated backend demand id must not trap.
        let duplicateDemandRoute = route(
            polyline: "duplicate-demand-route",
            score: 5.0,
            duration: 700,
            demands: [
                demand(.fastRoads, intensity: 0.90, level: .high),
                demand(.fastRoads, intensity: 0.10, level: .low)
            ]
        )
        let duplicateAssessment = DriverReadinessEngine.assess(
            route: duplicateDemandRoute,
            recordedDrives: history,
            configuration: configuration,
            calendar: calendar,
            referenceDate: referenceDate
        )
        let duplicateIDs = duplicateAssessment.insights.map(\.id)
        expect(
            Set(duplicateIDs).count == duplicateIDs.count,
            "a repeated backend demand id must yield unique readiness insight ids"
        )
        let duplicateRanking = RouteChoiceRankingEngine.rank(
            primaryRoute: duplicateDemandRoute,
            alternateRoutes: [],
            recordedDrives: history,
            configuration: configuration,
            calendar: calendar,
            referenceDate: referenceDate
        )
        expect(
            duplicateRanking.choices.count == 1,
            "route ranking must tolerate a repeated backend demand id"
        )

        // Finding 2 — a backend demand id that shadows a locally generated
        // insight must not collide, and the plan must still be buildable.
        expect(
            DriverReadinessInsightID.familiarity.hasPrefix(DriverReadinessInsightID.reservedPrefix)
                && DriverReadinessInsightID.drivingQuality.hasPrefix(DriverReadinessInsightID.reservedPrefix),
            "locally generated insight ids must carry the reserved prefix"
        )
        expect(
            RouteDemandKind.allCases.allSatisfy { !DriverReadinessInsightID.isSynthetic($0.rawValue) },
            "no backend demand kind may occupy the reserved local insight namespace"
        )
        let shadowingRoute = route(
            polyline: "shadowing-demand-route",
            score: 5.0,
            duration: 700,
            demands: [
                RouteDemand(
                    id: "familiarity",
                    intensity: 0.80,
                    level: .high,
                    evidence: "Measured route demand.",
                    available: true
                ),
                RouteDemand(
                    id: "drivingQuality",
                    intensity: 0.80,
                    level: .high,
                    evidence: "Measured route demand.",
                    available: true
                )
            ]
        )
        let shadowingAssessment = DriverReadinessEngine.assess(
            route: shadowingRoute,
            recordedDrives: history,
            configuration: configuration,
            calendar: calendar,
            referenceDate: referenceDate
        )
        let shadowingIDs = shadowingAssessment.insights.map(\.id)
        expect(
            Set(shadowingIDs).count == shadowingIDs.count,
            "a backend demand named after a local insight must not duplicate an insight id"
        )
        expect(
            shadowingIDs.contains("familiarity") && shadowingIDs.contains(DriverReadinessInsightID.familiarity),
            "the backend demand and the local familiarity insight must both survive, under separate ids"
        )
        let shadowingPlan = PracticePlanEngine.makePlan(
            assessment: shadowingAssessment,
            route: shadowingRoute,
            createdAt: referenceDate
        )
        expect(
            shadowingPlan.goals.count <= PracticePlan.maximumGoalCount,
            "a plan built from a shadowed assessment must respect the goal cap"
        )

        // A plan built from an assessment that predates deduplication (a stale
        // persisted one) must not trap either.
        let repeatedInsight = DriverReadinessInsight(
            id: "familiarity",
            title: "Route familiarity",
            detail: "Stale persisted duplicate.",
            state: .practiceNeeded,
            evidence: nil
        )
        let staleAssessment = DriverReadinessAssessment(
            verdict: shadowingAssessment.verdict,
            headline: shadowingAssessment.headline,
            summary: shadowingAssessment.summary,
            insights: shadowingAssessment.insights + [repeatedInsight],
            profile: shadowingAssessment.profile,
            familiarity: shadowingAssessment.familiarity
        )
        expect(
            PracticePlanEngine.makePlan(
                assessment: staleAssessment,
                route: shadowingRoute,
                createdAt: referenceDate
            ).goals.count <= PracticePlan.maximumGoalCount,
            "a stale assessment holding duplicate insight ids must not trap when a plan is built"
        )

        // Finding 3 — a malformed polyline overflows Int32 accumulation.
        let overflowingPolyline = String(repeating: "}~~~~~@", count: 6)
        let overflowPoints = RoutePolylineDecoder.decode(overflowingPolyline)
        expect(
            overflowPoints.allSatisfy { CLLocationCoordinate2DIsValid($0) },
            "an overflowing polyline must yield only valid coordinates"
        )
        expect(
            overflowPoints.count < 6,
            "an overflowing polyline must truncate rather than decode every component"
        )
        expect(
            RoutePolylineDecoder.decode(String(repeating: "~", count: 64)).isEmpty,
            "an unterminated polyline component must decode to nothing"
        )
        let wellFormedPolyline = "_p~iF~ps|U_ulLnnqC_mqNvxq`@"
        expect(
            RoutePolylineDecoder.decode(wellFormedPolyline).count == 3,
            "overflow hardening must not change a well-formed polyline"
        )

        // Finding 5 — an unvalidated backend metric must not trap on `Int`.
        let hugeMetricRoute = route(
            polyline: "huge-metric-route",
            score: 5.0,
            duration: 700,
            demands: [
                RouteDemand(
                    id: RouteDemandKind.sustainedDrive.rawValue,
                    intensity: 0.90,
                    level: .high,
                    evidence: "Measured route demand.",
                    available: true,
                    metrics: ["expectedDurationMinutes": 1e300]
                )
            ]
        )
        expect(
            hugeMetricRoute.routeDemands?.first?.metrics?["expectedDurationMinutes"] == nil,
            "an implausible backend metric must be dropped rather than retained"
        )
        expect(
            !DriverReadinessEngine.assess(
                route: hugeMetricRoute,
                recordedDrives: history,
                configuration: configuration,
                calendar: calendar,
                referenceDate: referenceDate
            ).insights.isEmpty,
            "an implausible backend metric must not trap the readiness assessment"
        )
        let nonFiniteDemand = RouteDemand(
            id: RouteDemandKind.traffic.rawValue,
            intensity: .nan,
            level: .high,
            evidence: "Measured route demand.",
            available: true,
            metrics: ["expectedDurationMinutes": .infinity]
        )
        expect(
            nonFiniteDemand.intensity == 0,
            "a non-finite intensity must clamp rather than propagate NaN"
        )
        expect(
            nonFiniteDemand.metrics?.isEmpty == true,
            "a non-finite backend metric must be dropped"
        )
        let farFutureAssessment = DriverReadinessEngine.assess(
            route: hugeMetricRoute,
            recordedDrives: history,
            configuration: configuration,
            calendar: calendar,
            referenceDate: Date(timeIntervalSince1970: 1e17)
        )
        expect(
            !farFutureAssessment.summary.isEmpty,
            "an extreme recency interval must not trap the readiness summary"
        )

        try checkDecodedInvariants()
    }

    /// Finding 6 — the invariants below live in hand-written initializers, so
    /// they are only meaningful if the `Decodable` path enforces them too.
    /// These decode from JSON rather than calling `init` directly, which is
    /// exactly what the pre-existing checks could not see.
    private static func checkDecodedInvariants() throws {
        let decoder = JSONDecoder()

        let decodedDemand = try decoder.decode(
            RouteDemand.self,
            from: Data(#"""
            {"id":"fastRoads","title":"Fast roads","intensity":60,"level":"high",
             "evidence":"e","available":true,
             "metrics":{"expectedDurationMinutes":1e300,"routeBandMiles":12},
             "coverageRanges":[{"startFraction":-3,"endFraction":9}]}
            """#.utf8)
        )
        expect(decodedDemand.intensity == 1, "a decoded demand intensity must clamp to 0…1")
        expect(
            decodedDemand.metrics?["expectedDurationMinutes"] == nil,
            "a decoded implausible metric must be dropped"
        )
        expect(
            decodedDemand.metrics?["routeBandMiles"] == 12,
            "a decoded plausible metric must be kept"
        )
        expect(
            decodedDemand.coverageRanges?.first?.startFraction == 0
                && decodedDemand.coverageRanges?.first?.endFraction == 1,
            "a decoded coverage range must clamp to 0…1"
        )

        let decodedRange = try decoder.decode(
            RouteDemandCoverageRange.self,
            from: Data(#"{"startFraction":-3,"endFraction":9}"#.utf8)
        )
        expect(
            decodedRange.startFraction == 0 && decodedRange.endFraction == 1,
            "a decoded coverage range must clamp to 0…1 on its own"
        )

        let goalsJSON = (0..<7)
            .map { #"{"id":"goal\#($0)","kind":"drivingQuality","status":"queued"}"# }
            .joined(separator: ",")
        let decodedPlan = try decoder.decode(
            PracticePlan.self,
            from: Data(#"""
            {"id":"7C4C7F1E-0F5E-4C2E-9C1B-0C3A5E2D1F00","createdAt":0,"goals":[\#(goalsJSON)]}
            """#.utf8)
        )
        expect(
            decodedPlan.goals.count == PracticePlan.maximumGoalCount,
            "a decoded practice plan must cap its goals like a built one"
        )

        let decodedSummary = try decoder.decode(
            PracticeRouteCoverageSummary.self,
            from: Data(#"""
            {"recordedAt":0,"overallCoverage":4,"longestContinuousCoverage":-1,
             "originCoverage":0.5,"destinationCoverage":0.5,
             "demandCoverage":[{"demandID":"fastRoads","demandIntensity":5,
                                "coveredShare":9,"routeShare":-4}]}
            """#.utf8)
        )
        expect(
            decodedSummary.overallCoverage == 1 && decodedSummary.longestContinuousCoverage == 0,
            "a decoded coverage summary must clamp to 0…1"
        )
        let decodedCoverage = decodedSummary.demandCoverage.first!
        expect(
            decodedCoverage.demandIntensity == 1
                && decodedCoverage.coveredShare == 1
                && decodedCoverage.routeShare == 0,
            "decoded demand coverage must clamp to 0…1"
        )

        // Explicit decoding must not have disturbed the encoded key names, or
        // already-persisted data would stop loading.
        let encodedDemand = try JSONEncoder().encode(decodedDemand)
        let demandObject = try JSONSerialization.jsonObject(with: encodedDemand) as! [String: Any]
        expect(
            Set(demandObject.keys) == ["id", "title", "intensity", "level", "evidence", "available", "metrics", "coverageRanges"],
            "route demands must keep their persisted key names"
        )
        let roundTrippedDemand = try decoder.decode(RouteDemand.self, from: encodedDemand)
        expect(
            roundTrippedDemand == decodedDemand,
            "route demands must round-trip through their explicit decoder"
        )
        let roundTrippedSummary = try decoder.decode(
            PracticeRouteCoverageSummary.self,
            from: JSONEncoder().encode(decodedSummary)
        )
        expect(
            roundTrippedSummary == decodedSummary,
            "coverage summaries must round-trip through their explicit decoder"
        )
        let roundTrippedPlan = try decoder.decode(
            PracticePlan.self,
            from: JSONEncoder().encode(decodedPlan)
        )
        expect(
            roundTrippedPlan == decodedPlan,
            "practice plans must round-trip through their explicit decoder"
        )
    }

    private static func route(
        polyline: String,
        score: Double,
        duration: Int,
        demands: [RouteDemand]
    ) -> ScoredRoute {
        ScoredRoute(
            score: score,
            uncalibratedScore: nil,
            label: .moderate,
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
            distanceMeters: 1_000,
            durationSeconds: duration,
            staticDurationSeconds: duration,
            trafficDelaySeconds: 0,
            polyline: polyline,
            bounds: RouteBounds(
                southwest: Coordinate(latitude: 30, longitude: -97),
                northeast: Coordinate(latitude: 31, longitude: -96)
            ),
            scoreDelta: nil,
            routeDemands: demands
        )
    }

    private static func demand(
        _ kind: RouteDemandKind,
        intensity: Double,
        level: RouteDemandLevel
    ) -> RouteDemand {
        RouteDemand(
            id: kind.rawValue,
            intensity: intensity,
            level: level,
            evidence: "Measured route demand.",
            available: true
        )
    }

    private static func drive(
        startedAt: Date,
        score: Int,
        confidence: DriveScoreConfidence = .high
    ) -> RecordedDrive {
        let route = (0...8).map { index in
            DriveRoutePoint(
                timestamp: startedAt.addingTimeInterval(TimeInterval(index)),
                coordinate: DriveCoordinate(
                    CLLocationCoordinate2D(latitude: 30, longitude: -97 + Double(index) * 0.0008)
                ),
                speedMetersPerSecond: 35
            )
        }
        return RecordedDrive(
            startedAt: startedAt,
            score: DrivingScore(
                score: score,
                duration: 8,
                distanceMeters: 700,
                topSpeedMetersPerSecond: 35,
                events: [],
                motionSamples: 12,
                dataQuality: DriveDataQuality(
                    acceptedLocationSamples: route.count,
                    rejectedLocationSamples: 0,
                    motionSamples: 12,
                    confidence: confidence
                )
            ),
            route: route,
            recordingTimeZoneIdentifier: "UTC"
        )
    }

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func makeDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError("RoutePracticeEngines check failed: \(message)")
        }
    }
}
