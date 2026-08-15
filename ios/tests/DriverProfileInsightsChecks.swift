import CoreLocation
import Foundation

@main
struct DriverProfileInsightsChecks {
    static func main() {
        let calendar = utcCalendar()
        let reference = date(2026, 7, 28, 12, 0, calendar: calendar)

        checkEmptyInputHasNoEvidenceAndNoNaN(reference: reference, calendar: calendar)
        checkKnownDrivesProduceExpectedMilesAndCounts(reference: reference, calendar: calendar)
        checkMilestoneProgressIsAlwaysBoundedAndFinite(reference: reference, calendar: calendar)
        checkSmoothDriveStreakCountsAndResets(reference: reference, calendar: calendar)
        checkWeeklyCurrentAndPreviousMilesAreSafe(reference: reference, calendar: calendar)

        print("DriverProfileInsightsEngine checks passed")
    }

    // MARK: - Checks

    private static func checkEmptyInputHasNoEvidenceAndNoNaN(reference: Date, calendar: Calendar) {
        for stage in DriverProfile.Stage.allCases {
            let insights = DriverProfileInsightsEngine.makeInsights(
                from: [],
                stage: stage,
                referenceDate: reference,
                calendar: calendar
            )
            expect(!insights.hasEvidence, "empty history must never claim evidence exists")
            expect(insights.qualifyingDriveCount == 0, "no drives means no qualifying drives")
            expect(insights.drivingDayCount == 0, "no drives means no driving days")
            expect(insights.measuredMiles == 0, "empty history must not fabricate mileage")
            expect(insights.performanceScore == nil, "empty history must not fabricate a score")
            expect(insights.lastDriveDate == nil, "empty history has no last drive date")
            expect(insights.smoothDriveStreak == 0, "empty history has no streak")
            expect(insights.currentWeekMiles == 0, "empty history has no current-week miles")
            expect(insights.previousWeekMiles == 0, "empty history has no previous-week miles")
            expect(!insights.milestones.isEmpty, "each stage should still surface real, zero-progress milestones")
            assertNoNaN(in: insights, context: "empty history, stage \(stage.rawValue)")
        }
    }

    private static func checkKnownDrivesProduceExpectedMilesAndCounts(reference: Date, calendar: Calendar) {
        let driveOne = qualifyingDrive(
            startedAt: reference.addingTimeInterval(-3 * 86_400),
            pointCount: 60,
            latitudeStepDegrees: 0.0003,
            speedMetersPerSecond: 22
        )
        let driveTwo = qualifyingDrive(
            startedAt: reference.addingTimeInterval(-2 * 86_400),
            pointCount: 60,
            latitudeStepDegrees: 0.0003,
            speedMetersPerSecond: 22
        )
        let driveThree = qualifyingDrive(
            startedAt: reference.addingTimeInterval(-1 * 86_400),
            pointCount: 60,
            latitudeStepDegrees: 0.0003,
            speedMetersPerSecond: 22
        )
        let drives = [driveOne, driveTwo, driveThree]
        let expectedMiles = drives.reduce(0.0) { $0 + milesFromCoordinates(of: $1.route) }

        let insights = DriverProfileInsightsEngine.makeInsights(
            from: drives,
            stage: .provisional,
            referenceDate: reference,
            calendar: calendar
        )

        expect(insights.hasEvidence, "three qualifying drives must show as real evidence")
        expect(insights.qualifyingDriveCount == 3, "all three drives should qualify")
        expect(insights.drivingDayCount == 3, "three distinct calendar days should be counted")
        expect(
            abs(insights.measuredMiles - expectedMiles) < 0.01,
            "measured miles should match the sum of the drives' own continuous trace distance"
        )
        expect(insights.analyzedDriveCount == 3, "all three drives had usable route analysis")
        expect(insights.pendingAnalysisCount == 0, "no drive was left pending analysis")
    }

    private static func checkMilestoneProgressIsAlwaysBoundedAndFinite(reference: Date, calendar: Calendar) {
        var drives: [RecordedDrive] = []
        for offset in 0..<12 {
            drives.append(
                qualifyingDrive(
                    startedAt: reference.addingTimeInterval(TimeInterval(-offset - 1) * 86_400),
                    pointCount: 200,
                    latitudeStepDegrees: 0.002,
                    speedMetersPerSecond: 30
                )
            )
        }

        for stage in DriverProfile.Stage.allCases {
            let insights = DriverProfileInsightsEngine.makeInsights(
                from: drives,
                stage: stage,
                referenceDate: reference,
                calendar: calendar
            )
            expect(
                (3...5).contains(insights.milestones.count),
                "each stage should present between 3 and 5 milestones"
            )
            for milestone in insights.milestones {
                expect(milestone.progress.isFinite, "milestone progress must never be NaN or infinite")
                expect(
                    (0...1).contains(milestone.progress),
                    "milestone progress must be clamped to 0...1"
                )
                expect(
                    milestone.isComplete == (milestone.progress >= 1),
                    "isComplete must agree with a clamped progress of 1"
                )
            }
            let uniqueIDs = Set(insights.milestones.map(\.id))
            expect(uniqueIDs.count == insights.milestones.count, "milestone ids must be unique within a stage")
        }
    }

    private static func checkSmoothDriveStreakCountsAndResets(reference: Date, calendar: Calendar) {
        // Chronological order, oldest first: clean, clean, eventful, clean.
        // The streak walks backward from the most recent drive, so it should
        // count the two most recent clean drives and stop at the eventful one.
        let oldestClean = qualifyingDrive(
            startedAt: reference.addingTimeInterval(-4 * 86_400),
            pointCount: 60,
            latitudeStepDegrees: 0.0003,
            speedMetersPerSecond: 22
        )
        let eventfulDrive = qualifyingDrive(
            startedAt: reference.addingTimeInterval(-3 * 86_400),
            pointCount: 60,
            latitudeStepDegrees: 0.0003,
            speedMetersPerSecond: 22,
            hardBrakeCount: 1
        )
        let recentCleanOne = qualifyingDrive(
            startedAt: reference.addingTimeInterval(-2 * 86_400),
            pointCount: 60,
            latitudeStepDegrees: 0.0003,
            speedMetersPerSecond: 22
        )
        let recentCleanTwo = qualifyingDrive(
            startedAt: reference.addingTimeInterval(-1 * 86_400),
            pointCount: 60,
            latitudeStepDegrees: 0.0003,
            speedMetersPerSecond: 22
        )
        let drives = [oldestClean, eventfulDrive, recentCleanOne, recentCleanTwo]

        let insights = DriverProfileInsightsEngine.makeInsights(
            from: drives,
            stage: .licensed,
            referenceDate: reference,
            calendar: calendar
        )
        expect(
            insights.smoothDriveStreak == 2,
            "the streak should count only the two most recent event-free drives"
        )

        let allClean = DriverProfileInsightsEngine.makeInsights(
            from: [oldestClean, recentCleanOne, recentCleanTwo],
            stage: .licensed,
            referenceDate: reference,
            calendar: calendar
        )
        expect(
            allClean.smoothDriveStreak == 3,
            "an entirely event-free history should count every qualifying drive"
        )
    }

    private static func checkWeeklyCurrentAndPreviousMilesAreSafe(reference: Date, calendar: Calendar) {
        let noHistory = DriverProfileInsightsEngine.makeInsights(
            from: [],
            stage: .permit,
            referenceDate: reference,
            calendar: calendar
        )
        expect(
            noHistory.currentWeekMiles == 0 && noHistory.previousWeekMiles == 0,
            "an empty week bucket list must resolve to zero, not crash or produce NaN"
        )
        expect(noHistory.weeklyMiles.count >= 0, "the weekly bucket list itself must never trap")

        let thisWeekDrive = qualifyingDrive(
            startedAt: reference,
            pointCount: 60,
            latitudeStepDegrees: 0.0003,
            speedMetersPerSecond: 22
        )
        let lastWeekDrive = qualifyingDrive(
            startedAt: reference.addingTimeInterval(-8 * 86_400),
            pointCount: 60,
            latitudeStepDegrees: 0.0003,
            speedMetersPerSecond: 22
        )
        let insights = DriverProfileInsightsEngine.makeInsights(
            from: [thisWeekDrive, lastWeekDrive],
            stage: .permit,
            referenceDate: reference,
            calendar: calendar
        )
        if let lastBucket = insights.weeklyMiles.last {
            expect(
                insights.currentWeekMiles == lastBucket.measuredMiles,
                "current-week miles must mirror the most recent weekly bucket"
            )
        }
        if insights.weeklyMiles.count >= 2 {
            let secondToLast = insights.weeklyMiles[insights.weeklyMiles.count - 2]
            expect(
                insights.previousWeekMiles == secondToLast.measuredMiles,
                "previous-week miles must mirror the second-to-last weekly bucket"
            )
        }
        expect(insights.currentWeekMiles.isFinite, "current-week miles must never be NaN")
        expect(insights.previousWeekMiles.isFinite, "previous-week miles must never be NaN")
    }

    // MARK: - Fixtures

    private static func qualifyingDrive(
        startedAt: Date,
        pointCount: Int,
        latitudeStepDegrees: Double,
        speedMetersPerSecond: Double,
        hardBrakeCount: Int = 0
    ) -> RecordedDrive {
        let route = (0..<pointCount).map { index in
            DriveRoutePoint(
                timestamp: startedAt.addingTimeInterval(TimeInterval(index) * 2),
                coordinate: DriveCoordinate(
                    CLLocationCoordinate2D(
                        latitude: 30 + Double(index) * latitudeStepDegrees,
                        longitude: -97
                    )
                ),
                speedMetersPerSecond: speedMetersPerSecond
            )
        }
        let events = (0..<hardBrakeCount).map { _ in
            DrivingEvent(
                kind: .hardBrake,
                timestamp: startedAt.addingTimeInterval(4),
                source: .fused
            )
        }
        return RecordedDrive(
            startedAt: startedAt,
            score: DrivingScore(
                score: 88,
                duration: TimeInterval(pointCount) * 2,
                distanceMeters: milesFromCoordinates(of: route) * 1_609.344,
                topSpeedMetersPerSecond: speedMetersPerSecond,
                events: events,
                motionSamples: pointCount * 10,
                dataQuality: DriveDataQuality(
                    acceptedLocationSamples: pointCount,
                    rejectedLocationSamples: 0,
                    motionSamples: pointCount * 10,
                    confidence: .high
                )
            ),
            route: route,
            recordingTimeZoneIdentifier: "UTC",
            routeAnalysis: DriveRouteAnalysis.available(
                difficultyScore: 4,
                label: .moderate,
                highlights: ["Measured route demand"],
                analyzedAt: startedAt
            )
        )
    }

    /// Mirrors `DriveExperienceEngine`'s own continuous-trace distance
    /// calculation (consecutive-point `CLLocation` distance) so the test can
    /// assert against an independently derived expectation rather than
    /// echoing back whatever the engine happens to compute.
    private static func milesFromCoordinates(of route: [DriveRoutePoint]) -> Double {
        guard route.count > 1 else { return 0 }
        var meters = 0.0
        for index in 1..<route.count {
            let previous = CLLocation(
                latitude: route[index - 1].coordinate.latitude,
                longitude: route[index - 1].coordinate.longitude
            )
            let current = CLLocation(
                latitude: route[index].coordinate.latitude,
                longitude: route[index].coordinate.longitude
            )
            meters += previous.distance(from: current)
        }
        return meters / 1_609.344
    }

    private static func assertNoNaN(in insights: DriverProfileInsights, context: String) {
        let values: [(String, Double)] = [
            ("measuredMiles", insights.measuredMiles),
            ("afterDarkMiles", insights.afterDarkMiles),
            ("milesAt45Plus", insights.milesAt45Plus),
            ("longestDriveMinutes", insights.longestDriveMinutes),
            ("longestContinuousMiles", insights.longestContinuousMiles),
            ("currentWeekMiles", insights.currentWeekMiles),
            ("previousWeekMiles", insights.previousWeekMiles)
        ]
        for (name, value) in values {
            expect(value.isFinite, "\(name) must be finite in \(context)")
        }
        let optionalValues: [(String, Double?)] = [
            ("recentAverageScore", insights.recentAverageScore),
            ("averageDifficulty", insights.averageDifficulty),
            ("hardBrakesPerTenMiles", insights.hardBrakesPerTenMiles),
            ("sharpCornersPerTenMiles", insights.sharpCornersPerTenMiles)
        ]
        for (name, value) in optionalValues {
            if let value {
                expect(value.isFinite, "\(name) must be finite when present in \(context)")
            }
        }
        for milestone in insights.milestones {
            expect(milestone.progress.isFinite, "milestone progress must be finite in \(context)")
        }
    }

    // MARK: - Helpers

    private static func date(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("DriverProfileInsightsEngine check failed: \(message)") }
    }
}
