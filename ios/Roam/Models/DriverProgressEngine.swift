import Foundation

/// One chronological column in the private eight-week measurement chart.
/// `endDate` is exclusive so adjacent buckets cannot double-count a drive.
struct DriverProgressWeek: Identifiable, Hashable {
    let startDate: Date
    let endDate: Date
    let measuredMiles: Double

    var id: Date { startDate }
}

/// Aggregate evidence from qualifying local drives. These quantities describe
/// what the phone actually measured, not a safety grade or a driving rank.
struct DriverProgressSummary: Hashable {
    let validatedMiles: Double
    let qualifyingDriveCount: Int
    let qualifyingDriveDayCount: Int
    let afterDarkMiles: Double
    let milesAt45Plus: Double
    let longestContinuousDuration: TimeInterval
    let longestContinuousDistanceMiles: Double
    let weeklyMeasuredMiles: [DriverProgressWeek]

    var hasRecordedEvidence: Bool { qualifyingDriveCount > 0 }
}

/// Pure local aggregation for the Progress tab. It deliberately reuses the
/// readiness qualification rule so short or low-confidence recordings remain
/// in history without inflating measured experience.
enum DriverProgressEngine {
    static let weeklyBucketCount = 8

    static func makeSummary(
        from recordedDrives: [RecordedDrive],
        referenceDate: Date = Date(),
        calendar: Calendar = .current,
        readinessConfiguration: DriverReadinessEngine.Configuration = .init()
    ) -> DriverProgressSummary {
        let qualifying = recordedDrives.compactMap { drive -> (drive: RecordedDrive, summary: DriveExperienceSummary)? in
            guard drive.startedAt <= referenceDate,
                  DriverReadinessEngine.qualifies(
                    drive,
                    configuration: readinessConfiguration,
                    calendar: calendar
                  ) else {
                return nil
            }
            return (drive, DriveExperienceEngine.summary(for: drive, calendar: calendar))
        }

        let dayKeys = Set(qualifying.map { localDayKey(for: $0.drive, calendar: calendar) })
        let validatedMiles = qualifying.reduce(0) { $0 + $1.summary.measuredMiles }
        let afterDarkMiles = qualifying.reduce(0) { $0 + $1.summary.lightingExposure.afterDarkMiles }
        let milesAt45Plus = qualifying.reduce(0) { $0 + $1.summary.speedExposure.milesAt45Plus }
        let longestDuration = qualifying.map { $0.summary.traceQuality.longestContinuousDuration }.max() ?? 0
        let longestDistance = qualifying.map {
            $0.summary.traceQuality.longestContinuousDistanceMeters / 1_609.344
        }.max() ?? 0

        return DriverProgressSummary(
            validatedMiles: validatedMiles,
            qualifyingDriveCount: qualifying.count,
            qualifyingDriveDayCount: dayKeys.count,
            afterDarkMiles: afterDarkMiles,
            milesAt45Plus: milesAt45Plus,
            longestContinuousDuration: longestDuration,
            longestContinuousDistanceMiles: longestDistance,
            weeklyMeasuredMiles: weeklyBuckets(
                for: qualifying,
                referenceDate: referenceDate,
                calendar: calendar
            )
        )
    }

    private static func weeklyBuckets(
        for qualifying: [(drive: RecordedDrive, summary: DriveExperienceSummary)],
        referenceDate: Date,
        calendar: Calendar
    ) -> [DriverProgressWeek] {
        let currentWeek = calendar.dateInterval(of: .weekOfYear, for: referenceDate)
            ?? DateInterval(start: calendar.startOfDay(for: referenceDate), duration: 7 * 86_400)
        let oldestStart = calendar.date(
            byAdding: .weekOfYear,
            value: -(weeklyBucketCount - 1),
            to: currentWeek.start
        ) ?? currentWeek.start

        return (0..<weeklyBucketCount).compactMap { index in
            guard let start = calendar.date(byAdding: .weekOfYear, value: index, to: oldestStart),
                  let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else {
                return nil
            }
            let miles = qualifying.reduce(0) { partial, item in
                guard item.drive.startedAt >= start, item.drive.startedAt < end else {
                    return partial
                }
                return partial + item.summary.measuredMiles
            }
            return DriverProgressWeek(startDate: start, endDate: end, measuredMiles: miles)
        }
    }

    /// The local day at recording time keeps a later time-zone change from
    /// collapsing separate days of evidence into one UI count.
    private static func localDayKey(for drive: RecordedDrive, calendar: Calendar) -> String {
        let driveCalendar = DriveExperienceEngine.calendar(for: drive, base: calendar)
        let components = driveCalendar.dateComponents([.year, .month, .day], from: drive.startedAt)
        return [
            driveCalendar.timeZone.identifier,
            String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0),
        ].joined(separator: "|")
    }
}
