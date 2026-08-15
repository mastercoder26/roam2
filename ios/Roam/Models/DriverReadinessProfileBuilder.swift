import Foundation

/// Aggregates qualifying on-device drives into the factual exposure profile
/// consumed by readiness policy. It does not decide a verdict or write UI copy.
enum DriverReadinessProfileBuilder {
    static func qualifyingDrives(
        from recordedDrives: [RecordedDrive],
        configuration: DriverReadinessEngine.Configuration,
        calendar: Calendar
    ) -> [HistoryDrive] {
        recordedDrives.compactMap { drive in
            guard DriverReadinessEngine.qualifies(
                drive,
                configuration: configuration,
                calendar: calendar
            ) else {
                return nil
            }
            return HistoryDrive(
                drive: drive,
                summary: DriveExperienceEngine.summary(for: drive, calendar: calendar)
            )
        }
    }

    static func makeProfile(
        qualifyingDrives: [HistoryDrive],
        configuration: DriverReadinessEngine.Configuration,
        calendar: Calendar,
        referenceDate: Date
    ) -> DriverReadinessProfile {
        var total = ExposureAccumulator()
        var night = ExposureAccumulator()
        var fast45 = ExposureAccumulator()
        var fast55 = ExposureAccumulator()
        var fast60 = ExposureAccumulator()
        var fast65 = ExposureAccumulator()
        var sustained = ExposureAccumulator()
        var scoreAccumulator = WeightedScoreAccumulator()
        var behaviorAccumulator = BehaviorAccumulator()
        var tagged: [String: [TaggedPracticeEvidence]] = [:]

        for history in qualifyingDrives {
            let drive = history.drive
            let summary = history.summary
            let date = drive.startedAt
            let localDayKey = dayKey(for: drive, calendar: calendar)
            let miles = summary.measuredMiles
            let duration = summary.traceQuality.usableDuration

            total.add(
                miles: miles,
                duration: duration,
                date: date,
                localDayKey: localDayKey,
                episodeDuration: summary.traceQuality.longestContinuousDuration,
                episodeMiles: summary.traceQuality.longestContinuousDistanceMeters / 1_609.344
            )
            if summary.lightingExposure.afterDarkMiles > 0 {
                night.add(
                    miles: summary.lightingExposure.afterDarkMiles,
                    duration: summary.lightingExposure.afterDarkDuration,
                    date: date,
                    localDayKey: localDayKey
                )
            }
            if summary.speedExposure.milesAt45Plus > 0 {
                fast45.add(
                    miles: summary.speedExposure.milesAt45Plus,
                    duration: summary.speedExposure.longest45PlusDuration,
                    date: date,
                    localDayKey: localDayKey,
                    episodeDuration: summary.speedExposure.longest45PlusDuration,
                    episodeMiles: summary.speedExposure.longest45PlusDistanceMiles
                )
            }
            if summary.speedExposure.milesAt55Plus > 0 {
                fast55.add(
                    miles: summary.speedExposure.milesAt55Plus,
                    duration: summary.speedExposure.longest55PlusDuration,
                    date: date,
                    localDayKey: localDayKey,
                    episodeDuration: summary.speedExposure.longest55PlusDuration,
                    episodeMiles: summary.speedExposure.longest55PlusDistanceMiles
                )
            }
            if summary.speedExposure.milesAt60Plus > 0 {
                fast60.add(
                    miles: summary.speedExposure.milesAt60Plus,
                    duration: summary.speedExposure.longest60PlusDuration,
                    date: date,
                    localDayKey: localDayKey,
                    episodeDuration: summary.speedExposure.longest60PlusDuration,
                    episodeMiles: summary.speedExposure.longest60PlusDistanceMiles
                )
            }
            if summary.speedExposure.milesAt65Plus > 0 {
                fast65.add(
                    miles: summary.speedExposure.milesAt65Plus,
                    duration: 0,
                    date: date,
                    localDayKey: localDayKey
                )
            }
            sustained.add(
                miles: miles,
                duration: summary.traceQuality.longestContinuousDuration,
                date: date,
                localDayKey: localDayKey,
                episodeDuration: summary.traceQuality.longestContinuousDuration,
                episodeMiles: summary.traceQuality.longestContinuousDistanceMeters / 1_609.344
            )
            scoreAccumulator.add(
                score: Double(drive.score.score),
                miles: miles,
                date: date,
                referenceDate: referenceDate,
                recentWindowDays: configuration.recentWindowDays
            )
            behaviorAccumulator.add(
                summary: summary,
                score: Double(drive.score.score),
                miles: miles,
                date: date,
                referenceDate: referenceDate,
                recentWindowDays: configuration.recentWindowDays
            )

            guard drive.plannedRouteContext?.recordedRouteMatched == true else { continue }
            // Legacy Boolean-only tags are intentionally not treated as proof
            // of a demand. New records need mapped demand coverage.
            for exposure in drive.plannedRouteContext?.verifiedDemandExposures ?? [] {
                guard exposure.coveredShare >= configuration.practiceCoverageThreshold else { continue }
                tagged[exposure.demandID, default: []].append(
                    TaggedPracticeEvidence(
                        driveID: drive.id,
                        demandIntensity: exposure.demandIntensity,
                        coveredShare: exposure.coveredShare,
                        routeShare: exposure.routeShare,
                        recordedAt: exposure.recordedAt
                    )
                )
            }
        }

        let totalExposure = total.makeExposure(referenceDate: referenceDate, configuration: configuration)
        let nightExposure = night.makeExposure(referenceDate: referenceDate, configuration: configuration)
        let fast45Exposure = fast45.makeExposure(referenceDate: referenceDate, configuration: configuration)
        let fast55Exposure = fast55.makeExposure(referenceDate: referenceDate, configuration: configuration)
        let fast60Exposure = fast60.makeExposure(referenceDate: referenceDate, configuration: configuration)
        let fast65Exposure = fast65.makeExposure(referenceDate: referenceDate, configuration: configuration)
        let sustainedExposure = sustained.makeExposure(referenceDate: referenceDate, configuration: configuration)
        let taggedCounts = tagged.mapValues { entries in
            Set(entries.map(\.driveID)).count
        }

        return DriverReadinessProfile(
            qualifyingDriveCount: qualifyingDrives.count,
            qualifyingDriveDayCount: totalExposure.distinctDayCount,
            totalMiles: totalExposure.miles,
            reliableTraceMiles: totalExposure.miles,
            recentQualifyingDriveCount: totalExposure.recentSessionCount,
            recentReliableTraceMiles: totalExposure.recentMiles,
            effectiveReliableTraceMiles: totalExposure.effectiveMiles,
            totalContinuousDuration: totalExposure.duration,
            nightMiles: nightExposure.miles,
            highSpeedMiles: fast45Exposure.miles,
            highestSpeedMiles: fast55Exposure.miles,
            longestDriveDuration: sustainedExposure.longestEpisodeDuration,
            averageDrivingScore: scoreAccumulator.average,
            recentAverageDrivingScore: scoreAccumulator.recentAverage,
            taggedExposureCounts: taggedCounts,
            nightExposure: nightExposure,
            fastRoad45Exposure: fast45Exposure,
            fastRoad55Exposure: fast55Exposure,
            fastRoad60Exposure: fast60Exposure,
            fastRoad65Exposure: fast65Exposure,
            sustainedExposure: sustainedExposure,
            behavior: behaviorAccumulator.makeProfile(),
            taggedPracticeEvidence: tagged
        )
    }

    /// Group each drive by the local calendar day in effect when that drive was
    /// recorded. A later trip across time zones cannot silently rewrite the
    /// three-day history baseline.
    private static func dayKey(for drive: RecordedDrive, calendar: Calendar) -> String {
        let driveCalendar = DriveExperienceEngine.calendar(for: drive, base: calendar)
        let components = driveCalendar.dateComponents([.year, .month, .day], from: drive.startedAt)
        return [
            driveCalendar.timeZone.identifier,
            String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        ].joined(separator: "|")
    }
}
