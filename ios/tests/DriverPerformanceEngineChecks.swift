import CoreLocation
import Foundation

@main
struct DriverPerformanceEngineChecks {
    static func main() {
        let calendar = utcCalendar()
        let reference = date(2026, 7, 28, 12, 0, calendar: calendar)

        expect(
            DriverPerformanceEngine.makeSummary(from: [], referenceDate: reference, calendar: calendar).score == nil,
            "an overall score should wait for measured, analyzed drives"
        )

        let preliminary = drive(
            startedAt: reference.addingTimeInterval(-3_600),
            score: 100,
            difficulty: 9,
            confidence: .low
        )
        expect(
            DriverPerformanceEngine.makeSummary(from: [preliminary], referenceDate: reference, calendar: calendar).score == nil,
            "preliminary drives must never produce an overall score"
        )

        let easyStrong = drive(
            startedAt: reference.addingTimeInterval(-86_400),
            score: 84,
            difficulty: 2
        )
        let hardStrong = drive(
            startedAt: reference.addingTimeInterval(-86_400),
            score: 84,
            difficulty: 9
        )
        let easySummary = DriverPerformanceEngine.makeSummary(
            from: [easyStrong], referenceDate: reference, calendar: calendar
        )
        let hardSummary = DriverPerformanceEngine.makeSummary(
            from: [hardStrong], referenceDate: reference, calendar: calendar
        )
        expect(
            (hardSummary.score ?? 0) > (easySummary.score ?? 100),
            "the same measured behavior on a harder analyzed route should earn more context-adjusted credit"
        )

        let olderWeak = drive(
            startedAt: reference.addingTimeInterval(-180 * 86_400),
            score: 54,
            difficulty: 6
        )
        let recentStrong = drive(
            startedAt: reference.addingTimeInterval(-86_400),
            score: 92,
            difficulty: 6
        )
        let trendSummary = DriverPerformanceEngine.makeSummary(
            from: [olderWeak, recentStrong], referenceDate: reference, calendar: calendar
        )
        expect(
            (trendSummary.score ?? 0) > 80,
            "recent measured driving should carry more weight than stale history"
        )
        expect(trendSummary.includedDriveCount == 2, "all qualified analyzed drives should contribute")
        expect(
            trendSummary.score.map { (0...100).contains($0) } == true,
            "overall score must remain bounded"
        )

        let missingAnalysis = RecordedDrive(
            startedAt: reference.addingTimeInterval(-86_400),
            score: easyStrong.score,
            route: easyStrong.route
        )
        expect(
            DriverPerformanceEngine.makeSummary(
                from: [missingAnalysis], referenceDate: reference, calendar: calendar
            ).score != nil,
            "an older saved drive should receive a local trace estimate instead of being excluded from the overall score"
        )

        let localEstimate = DriveRouteAnalysisEngine.estimated(from: missingAnalysis, calendar: calendar)
        expect(
            localEstimate?.source == .recordedTrace,
            "historical-drive estimates must be explicitly marked as local trace context"
        )

        let retryAt = reference.addingTimeInterval(-300)
        let retryable = DriveRouteAnalysis.unavailable(
            "Temporary route service outage.",
            retryEligible: true,
            lastAttemptAt: retryAt,
            retryCount: 1
        )
        expect(
            !retryable.shouldRetry(at: retryAt.addingTimeInterval(4 * 60)),
            "automatic analysis retries should respect backoff instead of retrying on every launch"
        )
        expect(
            retryable.shouldRetry(at: retryAt.addingTimeInterval(5 * 60)),
            "a temporary route-service failure should be retried after the persisted backoff"
        )

        let endpoints = DriveRouteAnalysisEngine.endpoints(for: hardStrong)
        expect(endpoints?.origin.latitude == 30, "automatic analysis should begin at the measured start of the usable trace")
        expect(endpoints?.destination.latitude ?? 0 > 30.01, "automatic analysis should end at the measured destination")

        let encodedDrive = try! JSONEncoder().encode(hardStrong)
        let decodedDrive = try! JSONDecoder().decode(RecordedDrive.self, from: encodedDrive)
        expect(
            decodedDrive.routeAnalysis?.difficultyScore == 9,
            "completed route difficulty must persist with its saved drive"
        )

        // A drive with a corrupt, centuries-old `startedAt` underflows the
        // recency weight (`pow(0.5, ageDays / halfLife)`) all the way to
        // 0.0. If it were the only qualifying drive, the old code divided by
        // a zero total weight, producing NaN, and `Int(NaN.rounded())` traps
        // at runtime. This must degrade to "no score" instead of crashing.
        let corruptDateDrive = drive(
            startedAt: .distantPast,
            score: 90,
            difficulty: 3
        )
        let corruptSummary = DriverPerformanceEngine.makeSummary(
            from: [corruptDateDrive], referenceDate: reference, calendar: calendar
        )
        expect(
            corruptSummary.score == nil,
            "a drive whose recency weight underflows to zero must not produce a score instead of crashing"
        )
        expect(
            corruptSummary.includedDriveCount == 0,
            "a drive that contributes no usable weight should not be counted as included"
        )

        // The same drive alongside a normal, currently-weighted one must
        // still score normally — only the fully-zero-weight case degrades.
        let mixedSummary = DriverPerformanceEngine.makeSummary(
            from: [corruptDateDrive, recentStrong], referenceDate: reference, calendar: calendar
        )
        expect(
            mixedSummary.score != nil,
            "one corrupted-date drive should not prevent a score when another drive carries real weight"
        )

        print("DriverPerformanceEngine checks passed")
    }

    private static func drive(
        startedAt: Date,
        score: Int,
        difficulty: Double,
        confidence: DriveScoreConfidence = .high
    ) -> RecordedDrive {
        let route = (0...60).map { index in
            DriveRoutePoint(
                timestamp: startedAt.addingTimeInterval(TimeInterval(index * 2)),
                coordinate: DriveCoordinate(
                    CLLocationCoordinate2D(latitude: 30 + Double(index) * 0.0003, longitude: -97)
                ),
                speedMetersPerSecond: 22
            )
        }
        return RecordedDrive(
            startedAt: startedAt,
            score: DrivingScore(
                score: score,
                duration: 120,
                distanceMeters: 2_000,
                topSpeedMetersPerSecond: 22,
                events: [],
                motionSamples: 1_200,
                dataQuality: DriveDataQuality(
                    acceptedLocationSamples: route.count,
                    rejectedLocationSamples: 0,
                    motionSamples: 1_200,
                    confidence: confidence
                )
            ),
            route: route,
            recordingTimeZoneIdentifier: "UTC",
            routeAnalysis: DriveRouteAnalysis.available(
                difficultyScore: difficulty,
                label: .hard,
                highlights: ["Measured route demand"],
                analyzedAt: startedAt
            )
        )
    }

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
        guard condition() else { fatalError("DriverPerformanceEngine check failed: \(message)") }
    }
}
