import Foundation

@main
struct DepartureComparisonChecks {
    static func main() {
        let calendar = chicagoCalendar()
        windowChecks(calendar: calendar)
        rankingChecks(calendar: calendar)
        print("DepartureComparison checks passed")
    }

    private static func windowChecks(calendar: Calendar) {
        let selected = date(2026, 3, 8, 1, 30, calendar: calendar)
        let now = date(2026, 3, 8, 0, 15, calendar: calendar)
        let windows = DepartureComparisonWindowBuilder.makeCandidates(
            selectedDeparture: selected,
            now: now,
            calendar: calendar
        )
        expect(windows.map(\.id) == ["earlier", "selected", "later"], "window IDs should stay stable")
        expect(windows[1].departureLocalMinutes == 90, "selected local minutes should reflect local clock time")
        expect(windows[2].departureLocalMinutes == 210, "spring-forward addition should recompute local minutes after the skipped hour")

        let lateNow = date(2026, 3, 8, 4, 45, calendar: calendar)
        let pastWindows = DepartureComparisonWindowBuilder.makeCandidates(
            selectedDeparture: selected,
            now: lateNow,
            calendar: calendar
        )
        let formatter = ISO8601DateFormatter()
        let replacement = formatter.date(from: pastWindows[0].departureTime)!
        expect(replacement > lateNow, "a past earlier window should become the next future hourly slot")

        let midnight = date(2026, 1, 4, 0, 20, calendar: calendar)
        let midnightWindows = DepartureComparisonWindowBuilder.makeCandidates(
            selectedDeparture: midnight,
            now: date(2026, 1, 3, 21, 0, calendar: calendar),
            calendar: calendar
        )
        expect(midnightWindows[0].departureLocalMinutes == 1_400, "earlier window should retain its previous-day local clock minutes")
        expect(midnightWindows[1].departureLocalMinutes == 20, "midnight local minute calculation should remain valid")

        let overlappingReplacement = DepartureComparisonWindowBuilder.makeCandidates(
            selectedDeparture: date(2026, 1, 3, 11, 0, calendar: calendar),
            now: date(2026, 1, 3, 10, 30, calendar: calendar),
            calendar: calendar
        )
        let replacementTimes = overlappingReplacement.map(\.departureTime)
        expect(
            Set(replacementTimes).count == replacementTimes.count,
            "a replaced past window must not duplicate the selected or later comparison time"
        )
    }

    private static func rankingChecks(calendar: Calendar) {
        let calm = result(id: "earlier", route: route(traffic: 0.10, afterDark: 0.0, weather: 0.05), calendar: calendar)
        let busy = result(id: "selected", route: route(traffic: 0.80, afterDark: 0.6, weather: 0.4), calendar: calendar)
        let wet = result(id: "later", route: route(traffic: 0.20, afterDark: 0.1, weather: 0.9), calendar: calendar)
        expect(
            DepartureComparisonRanking.calmestCandidateID(in: [calm, busy, wet]) == "earlier",
            "calmest ranking should combine traffic, after-dark, and weather measurements"
        )

        let unavailable = result(
            id: "later",
            route: route(traffic: 0.05, afterDark: 0, weather: 0, weatherAvailable: false),
            calendar: calendar
        )
        expect(
            DepartureComparisonRanking.calmestCandidateID(in: [calm, busy, unavailable]) == nil,
            "missing weather must leave calmest availability honest"
        )
    }

    private static func result(id: String, route: ScoredRoute, calendar: Calendar) -> DepartureComparisonCandidateResult {
        let formatter = ISO8601DateFormatter()
        return DepartureComparisonCandidateResult(
            id: id,
            departureTime: formatter.string(from: date(2026, 1, 5, 9, 0, calendar: calendar)),
            departureLocalMinutes: 540,
            route: route,
            error: nil
        )
    }

    private static func route(
        traffic: Double,
        afterDark: Double,
        weather: Double,
        weatherAvailable: Bool = true
    ) -> ScoredRoute {
        let demands = [
            RouteDemand(id: "traffic", intensity: traffic, level: traffic > 0.6 ? .high : .low, evidence: "Traffic timing measured.", available: true),
            RouteDemand(id: "afterDark", intensity: afterDark, level: afterDark > 0.6 ? .high : .low, evidence: "Local after-dark timing measured.", available: true),
            RouteDemand(id: "weatherVisibility", intensity: weather, level: weather > 0.6 ? .high : .low, evidence: "Weather measured.", available: weatherAvailable),
        ]
        return ScoredRoute(
            score: 4,
            uncalibratedScore: nil,
            label: .moderate,
            reasons: [],
            breakdown: DifficultyBreakdown(
                speed: nil, merges: nil, turns: nil, traffic: traffic,
                length: nil, fatigue: nil, weather: weather, road: nil,
                highway: 0, maneuvers: 0, navDensity: 0, effort: 0
            ),
            contributions: nil,
            uncertainty: nil,
            hotspots: nil,
            conditions: RouteConditions(
                weather: WeatherConditions(
                    available: weatherAvailable,
                    condition: "Clear",
                    severity: weather,
                    precipIntensity: 0,
                    snowRisk: 0,
                    windSeverity: 0,
                    lowVisibilityRisk: 0,
                    icyRisk: 0,
                    temperatureF: 70,
                    windGustMph: 0,
                    visibilityMiles: 10
                ),
                road: RoadConditions(
                    available: false,
                    avgLanes: 0,
                    narrowRoadShare: 0,
                    majorRoadShare: 0,
                    unpavedShare: 0,
                    roadSizeScore: 0,
                    constructionZones: 0,
                    dominantRoadClass: ""
                ),
                turns: TurnExposure(available: false, unprotectedLeftTurns: 0, protectedLeftTurns: 0, unprotectedTurnShare: 0),
                sources: weatherAvailable ? ["open-meteo"] : []
            ),
            modelVersion: nil,
            distanceMeters: 5_000,
            durationSeconds: 600,
            staticDurationSeconds: 540,
            trafficDelaySeconds: 60,
            polyline: "\(traffic)-\(afterDark)-\(weather)-\(weatherAvailable)",
            bounds: RouteBounds(
                southwest: Coordinate(latitude: 30, longitude: -97),
                northeast: Coordinate(latitude: 30.1, longitude: -96.9)
            ),
            scoreDelta: nil,
            routeDemands: demands
        )
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func chicagoCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("DepartureComparison check failed: \(message)") }
    }
}
