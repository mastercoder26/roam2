import Foundation

/// A stable local snapshot used by the UI to cache route-choice assessments.
/// It contains only route identities and saved-drive identities. It never
/// serializes route geometry, addresses, or any driving history.
struct RouteChoiceRankingCacheKey: Hashable {
    let routeIDs: [String]
    let savedDriveIDs: [UUID]

    init(primaryRoute: ScoredRoute, alternateRoutes: [ScoredRoute], recordedDrives: [RecordedDrive]) {
        routeIDs = [primaryRoute.id] + alternateRoutes.map(\.id)
        savedDriveIDs = recordedDrives.map(\.id).sorted { $0.uuidString < $1.uuidString }
    }
}

enum RouteChoiceBadge: String, Codable, Hashable {
    case bestFit
    case lowestDifficulty

    var title: String {
        switch self {
        case .bestFit:
            return "Best fit for your recorded experience"
        case .lowestDifficulty:
            return "Lowest route difficulty"
        }
    }
}

/// One route and the local evidence used to place it in the route-choice list.
struct RankedRouteChoice: Identifiable {
    let route: ScoredRoute
    let assessment: DriverReadinessAssessment
    /// Preserves backend order whenever all meaningful comparison values tie.
    let originalIndex: Int
    let rank: Int
    let meaningfulGapCount: Int
    let badges: [RouteChoiceBadge]

    var id: String { route.id }
}

/// A complete, immutable ordering for a primary route and its alternates.
/// `initialSelectedRouteID` deliberately remains the primary route even when
/// an alternate ranks better, so showing a recommendation never changes what
/// the driver was already reviewing.
struct RouteChoiceRanking {
    let choices: [RankedRouteChoice]
    let initialSelectedRouteID: String
    let bestFitRouteID: String?
    let lowestDifficultyRouteID: String?
    let comparisonLimitedByHistory: Bool

    func choice(for routeID: String) -> RankedRouteChoice? {
        choices.first { $0.route.id == routeID }
    }

    /// Keep a valid user choice across presentation updates. If that route is
    /// no longer returned by the backend, fall back to the original primary.
    func selectedRouteID(preserving requestedRouteID: String?) -> String {
        guard let requestedRouteID,
              choices.contains(where: { $0.route.id == requestedRouteID }) else {
            return initialSelectedRouteID
        }
        return requestedRouteID
    }
}

/// Pure local ranking for route alternatives. It delegates all experience
/// interpretation to `DriverReadinessEngine`, then uses a total ordering so
/// equal routes never jump around between renders.
enum RouteChoiceRankingEngine {
    static func cacheKey(
        primaryRoute: ScoredRoute,
        alternateRoutes: [ScoredRoute],
        recordedDrives: [RecordedDrive]
    ) -> RouteChoiceRankingCacheKey {
        RouteChoiceRankingCacheKey(
            primaryRoute: primaryRoute,
            alternateRoutes: alternateRoutes,
            recordedDrives: recordedDrives
        )
    }

    static func rank(
        primaryRoute: ScoredRoute,
        alternateRoutes: [ScoredRoute],
        recordedDrives: [RecordedDrive],
        configuration: DriverReadinessEngine.Configuration = .init(),
        calendar: Calendar = .current,
        referenceDate: Date = Date()
    ) -> RouteChoiceRanking {
        let routes = [primaryRoute] + alternateRoutes
        let assessed = routes.enumerated().map { index, route in
            let assessment = DriverReadinessEngine.assess(
                route: route,
                recordedDrives: recordedDrives,
                configuration: configuration,
                calendar: calendar,
                referenceDate: referenceDate
            )
            return AssessedRouteChoice(
                route: route,
                assessment: assessment,
                originalIndex: index,
                meaningfulGapCount: meaningfulGapCount(for: route, assessment: assessment)
            )
        }

        let hasEnoughHistory = assessed.first?.assessment.profile.hasEnoughRecordedExperience(using: configuration) ?? false
        let ordered = assessed.sorted { lhs, rhs in
            if hasEnoughHistory {
                let lhsReadiness = readinessOrder(lhs.assessment.verdict)
                let rhsReadiness = readinessOrder(rhs.assessment.verdict)
                if lhsReadiness != rhsReadiness {
                    return lhsReadiness < rhsReadiness
                }
                if lhs.meaningfulGapCount != rhs.meaningfulGapCount {
                    return lhs.meaningfulGapCount < rhs.meaningfulGapCount
                }
            }

            let lhsDifficulty = finiteDifficulty(lhs.route.score)
            let rhsDifficulty = finiteDifficulty(rhs.route.score)
            if lhsDifficulty != rhsDifficulty {
                return lhsDifficulty < rhsDifficulty
            }
            if lhs.route.durationSeconds != rhs.route.durationSeconds {
                return lhs.route.durationSeconds < rhs.route.durationSeconds
            }
            return lhs.originalIndex < rhs.originalIndex
        }

        let bestFitRouteID: String?
        if hasEnoughHistory {
            bestFitRouteID = ordered.first(where: {
                $0.assessment.verdict == .looksLikeMatch && hasComparableRouteDemandDetails($0.route)
            })?.route.id
        } else {
            bestFitRouteID = nil
        }
        let lowestDifficultyRouteID = assessed.min(by: isLowerDifficulty)?.route.id

        let choices = ordered.enumerated().map { rank, candidate in
            let badges = badges(
                for: candidate.route.id,
                bestFitRouteID: bestFitRouteID,
                lowestDifficultyRouteID: lowestDifficultyRouteID
            )
            return RankedRouteChoice(
                route: candidate.route,
                assessment: candidate.assessment,
                originalIndex: candidate.originalIndex,
                rank: rank,
                meaningfulGapCount: candidate.meaningfulGapCount,
                badges: badges
            )
        }

        return RouteChoiceRanking(
            choices: choices,
            initialSelectedRouteID: primaryRoute.id,
            bestFitRouteID: bestFitRouteID,
            lowestDifficultyRouteID: lowestDifficultyRouteID,
            comparisonLimitedByHistory: !hasEnoughHistory
        )
    }

    private static func meaningfulGapCount(
        for route: ScoredRoute,
        assessment: DriverReadinessAssessment
    ) -> Int {
        let demandsByID = (route.routeDemands ?? []).keyedByID()
        return assessment.insights.reduce(into: 0) { count, insight in
            switch insight.state {
            case .practiceNeeded:
                count += 1
            case .unmeasured:
                guard let demand = demandsByID[insight.id],
                      demand.available,
                      demand.intensity >= 0.60 else {
                    return
                }
                count += 1
            case .matched, .informational:
                break
            }
        }
    }

    private static func readinessOrder(_ verdict: DriverReadinessVerdict) -> Int {
        switch verdict {
        case .looksLikeMatch: 0
        case .practiceWithAdult: 1
        case .insufficientHistory: 2
        }
    }

    private static func finiteDifficulty(_ score: Double) -> Double {
        score.isFinite ? score : .greatestFiniteMagnitude
    }

    /// A route with no available demand facts can still be listed and sorted,
    /// but it must not receive a personalized best-fit claim.
    private static func hasComparableRouteDemandDetails(_ route: ScoredRoute) -> Bool {
        (route.routeDemands ?? []).contains(where: \.available)
    }

    private static func isLowerDifficulty(_ lhs: AssessedRouteChoice, _ rhs: AssessedRouteChoice) -> Bool {
        let lhsDifficulty = finiteDifficulty(lhs.route.score)
        let rhsDifficulty = finiteDifficulty(rhs.route.score)
        if lhsDifficulty != rhsDifficulty {
            return lhsDifficulty < rhsDifficulty
        }
        if lhs.route.durationSeconds != rhs.route.durationSeconds {
            return lhs.route.durationSeconds < rhs.route.durationSeconds
        }
        return lhs.originalIndex < rhs.originalIndex
    }

    private static func badges(
        for routeID: String,
        bestFitRouteID: String?,
        lowestDifficultyRouteID: String?
    ) -> [RouteChoiceBadge] {
        if routeID == bestFitRouteID {
            // When one route is both the best fit and easiest, use the more
            // helpful readiness statement rather than stacking two badges.
            return [.bestFit]
        }
        if routeID == lowestDifficultyRouteID {
            return [.lowestDifficulty]
        }
        return []
    }
}

private struct AssessedRouteChoice {
    let route: ScoredRoute
    let assessment: DriverReadinessAssessment
    let originalIndex: Int
    let meaningfulGapCount: Int
}
