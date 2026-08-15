import Foundation

/// A single stage-aware goal shown on the Profile tab. Progress always comes
/// from a real, locally measured quantity; there is no simulated advancement.
struct DriverProfileMilestone: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let progress: Double
    let isComplete: Bool
    let symbol: String
}

/// Everything the Profile tab needs to show real, locally measured driver
/// evidence. It is deliberately not a safety score or a legal credential; it
/// only restates quantities the phone actually recorded.
struct DriverProfileInsights: Hashable {
    let hasEvidence: Bool
    let measuredMiles: Double
    let qualifyingDriveCount: Int
    let drivingDayCount: Int
    let afterDarkMiles: Double
    let milesAt45Plus: Double
    let longestDriveMinutes: Double
    let longestContinuousMiles: Double
    let currentWeekMiles: Double
    let previousWeekMiles: Double
    let weeklyMiles: [DriverProgressWeek]
    let performanceScore: Int?
    let recentAverageScore: Double?
    let averageDifficulty: Double?
    let hardBrakesPerTenMiles: Double?
    let sharpCornersPerTenMiles: Double?
    let smoothDriveStreak: Int
    let lastDriveDate: Date?
    let analyzedDriveCount: Int
    let pendingAnalysisCount: Int
    let milestones: [DriverProfileMilestone]
    let stageGuidance: String
}

/// Pure local aggregation for the Profile tab. It composes the existing
/// progress, performance, and readiness engines rather than re-deriving
/// mileage, event, or scoring math, so a single source of truth stays in
/// each of those files.
enum DriverProfileInsightsEngine {
    static func makeInsights(
        from drives: [RecordedDrive],
        stage: DriverProfile.Stage,
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> DriverProfileInsights {
        let progress = DriverProgressEngine.makeSummary(
            from: drives,
            referenceDate: referenceDate,
            calendar: calendar
        )
        let performance = DriverPerformanceEngine.makeSummary(
            from: drives,
            referenceDate: referenceDate,
            calendar: calendar
        )
        let readinessConfiguration = DriverReadinessEngine.Configuration()
        let qualifyingDrives = DriverReadinessProfileBuilder.qualifyingDrives(
            from: drives,
            configuration: readinessConfiguration,
            calendar: calendar
        ).filter { $0.drive.startedAt <= referenceDate }
        let readinessProfile = DriverReadinessProfileBuilder.makeProfile(
            qualifyingDrives: qualifyingDrives,
            configuration: readinessConfiguration,
            calendar: calendar,
            referenceDate: referenceDate
        )
        let behavior = readinessProfile.behavior

        let weeks = progress.weeklyMeasuredMiles
        let currentWeekMiles = weeks.last?.measuredMiles ?? 0
        // Guard the short-history case explicitly: fewer than two buckets
        // means there is no distinct "previous" week yet.
        let previousWeekMiles = weeks.count >= 2 ? weeks[weeks.count - 2].measuredMiles : 0

        // Drawn from qualifying drives only. Sourcing this from every saved
        // drive let a twenty second junk recording report "last drive: today"
        // beside a screen stating there is no measured evidence yet.
        let lastDriveDate = qualifyingDrives
            .map(\.drive.startedAt)
            .max()

        let smoothDriveStreak = smoothStreak(among: qualifyingDrives)

        let longestDriveMinutes = progress.longestContinuousDuration / 60

        let milestones = makeMilestones(
            stage: stage,
            measuredMiles: progress.validatedMiles,
            drivingDayCount: progress.qualifyingDriveDayCount,
            afterDarkMiles: progress.afterDarkMiles,
            milesAt45Plus: progress.milesAt45Plus,
            longestDriveMinutes: longestDriveMinutes,
            smoothDriveStreak: smoothDriveStreak
        )

        return DriverProfileInsights(
            hasEvidence: progress.hasRecordedEvidence,
            measuredMiles: progress.validatedMiles,
            qualifyingDriveCount: progress.qualifyingDriveCount,
            drivingDayCount: progress.qualifyingDriveDayCount,
            afterDarkMiles: progress.afterDarkMiles,
            milesAt45Plus: progress.milesAt45Plus,
            longestDriveMinutes: longestDriveMinutes,
            longestContinuousMiles: progress.longestContinuousDistanceMiles,
            currentWeekMiles: currentWeekMiles,
            previousWeekMiles: previousWeekMiles,
            weeklyMiles: weeks,
            performanceScore: performance.score,
            recentAverageScore: safeOptional(behavior.recentWeightedAverageScore),
            averageDifficulty: safeOptional(performance.averageDifficulty),
            hardBrakesPerTenMiles: safeOptional(behavior.hardBrakesPerTenMiles),
            sharpCornersPerTenMiles: safeOptional(behavior.sharpCornersPerTenMiles),
            smoothDriveStreak: smoothDriveStreak,
            lastDriveDate: lastDriveDate,
            analyzedDriveCount: performance.analyzedDriveCount,
            pendingAnalysisCount: performance.pendingAnalysisCount,
            milestones: milestones,
            stageGuidance: stageGuidance(for: stage, hasEvidence: progress.hasRecordedEvidence)
        )
    }

    /// Counts consecutive most-recent qualifying drives with zero recorded
    /// coaching events, stopping at the first drive that logged one. An
    /// empty history has no streak to report.
    private static func smoothStreak(among qualifyingDrives: [HistoryDrive]) -> Int {
        // Swift's sort is not stable, and a drive recovered after termination
        // can share a start instant with its original. Breaking the tie on id
        // keeps the streak from flipping between runs over identical data.
        let chronological = qualifyingDrives.sorted {
            ($0.drive.startedAt, $0.drive.id.uuidString) > ($1.drive.startedAt, $1.drive.id.uuidString)
        }
        var streak = 0
        for history in chronological {
            guard history.drive.score.events.isEmpty else { break }
            streak += 1
        }
        return streak
    }

    /// NaN and infinite values can only ever originate upstream (a corrupt
    /// saved record); this keeps them from ever reaching the UI layer.
    private static func safeOptional(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func safeRatio(_ value: Double, target: Double) -> Double {
        guard target.isFinite, target > 0, value.isFinite else { return 0 }
        let ratio = value / target
        guard ratio.isFinite else { return 0 }
        return min(max(ratio, 0), 1)
    }

    private static func milestone(
        id: String,
        title: String,
        detail: String,
        symbol: String,
        value: Double,
        target: Double
    ) -> DriverProfileMilestone {
        let progress = safeRatio(value, target: target)
        return DriverProfileMilestone(
            id: id,
            title: title,
            detail: detail,
            progress: progress,
            isComplete: progress >= 1,
            symbol: symbol
        )
    }

    private static func makeMilestones(
        stage: DriverProfile.Stage,
        measuredMiles: Double,
        drivingDayCount: Int,
        afterDarkMiles: Double,
        milesAt45Plus: Double,
        longestDriveMinutes: Double,
        smoothDriveStreak: Int
    ) -> [DriverProfileMilestone] {
        switch stage {
        case .permit:
            return [
                milestone(
                    id: "permit.miles",
                    title: "Supervised miles logged",
                    detail: "\(formattedMiles(measuredMiles)) of 50 measured miles.",
                    symbol: "road.lanes",
                    value: measuredMiles,
                    target: 50
                ),
                milestone(
                    id: "permit.days",
                    title: "Distinct driving days",
                    detail: "\(drivingDayCount) of 15 days behind the wheel.",
                    symbol: "calendar",
                    value: Double(drivingDayCount),
                    target: 15
                ),
                milestone(
                    id: "permit.sustained",
                    title: "One sustained drive",
                    detail: "Longest continuous drive: \(formattedMinutes(longestDriveMinutes)) of 30 minutes.",
                    symbol: "clock.arrow.circlepath",
                    value: longestDriveMinutes,
                    target: 30
                ),
                milestone(
                    id: "permit.afterDark",
                    title: "Early after-dark practice",
                    detail: "\(formattedMiles(afterDarkMiles)) of 5 after-dark miles.",
                    symbol: "moon.stars",
                    value: afterDarkMiles,
                    target: 5
                )
            ]
        case .provisional:
            return [
                milestone(
                    id: "provisional.miles",
                    title: "Independent miles logged",
                    detail: "\(formattedMiles(measuredMiles)) of 150 measured miles.",
                    symbol: "road.lanes",
                    value: measuredMiles,
                    target: 150
                ),
                milestone(
                    id: "provisional.days",
                    title: "Distinct driving days",
                    detail: "\(drivingDayCount) of 30 days behind the wheel.",
                    symbol: "calendar",
                    value: Double(drivingDayCount),
                    target: 30
                ),
                milestone(
                    id: "provisional.afterDark",
                    title: "After-dark experience",
                    detail: "\(formattedMiles(afterDarkMiles)) of 15 after-dark miles.",
                    symbol: "moon.stars",
                    value: afterDarkMiles,
                    target: 15
                ),
                milestone(
                    id: "provisional.highway",
                    title: "Higher-speed road exposure",
                    detail: "\(formattedMiles(milesAt45Plus)) of 40 miles at 45+ mph.",
                    symbol: "speedometer",
                    value: milesAt45Plus,
                    target: 40
                )
            ]
        case .licensed:
            return [
                milestone(
                    id: "licensed.miles",
                    title: "Broad measured experience",
                    detail: "\(formattedMiles(measuredMiles)) of 300 measured miles.",
                    symbol: "road.lanes",
                    value: measuredMiles,
                    target: 300
                ),
                milestone(
                    id: "licensed.highway",
                    title: "Higher-speed road exposure",
                    detail: "\(formattedMiles(milesAt45Plus)) of 100 miles at 45+ mph.",
                    symbol: "speedometer",
                    value: milesAt45Plus,
                    target: 100
                ),
                milestone(
                    id: "licensed.afterDark",
                    title: "After-dark experience",
                    detail: "\(formattedMiles(afterDarkMiles)) of 30 after-dark miles.",
                    symbol: "moon.stars",
                    value: afterDarkMiles,
                    target: 30
                ),
                milestone(
                    id: "licensed.streak",
                    title: "Smooth drive streak",
                    detail: "\(smoothDriveStreak) of 5 recent drives with no coaching events.",
                    symbol: "checkmark.seal",
                    value: Double(smoothDriveStreak),
                    target: 5
                )
            ]
        }
    }

    private static func stageGuidance(for stage: DriverProfile.Stage, hasEvidence: Bool) -> String {
        guard hasEvidence else {
            return "Record a qualifying drive to start building your measured history."
        }
        switch stage {
        case .permit:
            return "These numbers reflect supervised practice recorded on this phone so far."
        case .provisional:
            return "These numbers reflect independent driving recorded on this phone so far."
        case .licensed:
            return "These numbers reflect driving recorded on this phone; they are not a license or safety rating."
        }
    }

    private static func formattedMiles(_ miles: Double) -> String {
        guard miles.isFinite else { return "0" }
        return String(format: "%.1f", max(0, miles))
    }

    private static func formattedMinutes(_ minutes: Double) -> String {
        guard minutes.isFinite else { return "0" }
        return String(format: "%.0f", max(0, minutes))
    }
}
