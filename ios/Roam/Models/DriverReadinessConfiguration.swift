import CoreLocation
import Foundation

extension DriverReadinessEngine {
    /// Bounds and thresholds for locally measured route-readiness evidence.
    /// Kept injectable so policy can be regression-tested without mutable
    /// global state or a live device session.
    struct Configuration {
        let minimumQualifyingDuration: TimeInterval
        let minimumQualifyingMiles: Double
        let minimumHistoryDriveCount: Int
        let minimumHistoryDayCount: Int
        let minimumHistoryMiles: Double
        let minimumHistoryTraceDuration: TimeInterval
        let minimumRecentQualityMiles: Double
        let minimumRecentHistoryMiles: Double
        let minimumRecentHistoryDriveCount: Int
        let recentWindowDays: Double
        let staleExperienceDays: Double
        let experienceHalfLifeDays: Double
        let practiceCoverageThreshold: Double
        let routeFamiliarityDistanceMeters: CLLocationDistance
        let routeFamiliaritySampleLimit: Int
        let minimumPracticeContiguousShare: Double
        let practiceRouteMatchDistanceMeters: CLLocationDistance
        let minimumPracticeRouteDistanceMeters: CLLocationDistance

        init(
            minimumQualifyingDuration: TimeInterval = 5 * 60,
            minimumQualifyingMiles: Double = 1,
            minimumHistoryDriveCount: Int = 3,
            minimumHistoryDayCount: Int = 3,
            minimumHistoryMiles: Double = 15,
            minimumHistoryTraceDuration: TimeInterval = 45 * 60,
            minimumRecentQualityMiles: Double = 5,
            minimumRecentHistoryMiles: Double = 3,
            minimumRecentHistoryDriveCount: Int = 1,
            recentWindowDays: Double = 90,
            staleExperienceDays: Double = 180,
            experienceHalfLifeDays: Double = 120,
            practiceCoverageThreshold: Double = 0.70,
            routeFamiliarityDistanceMeters: CLLocationDistance = 35,
            routeFamiliaritySampleLimit: Int = 500,
            minimumPracticeContiguousShare: Double = 0.45,
            practiceRouteMatchDistanceMeters: CLLocationDistance = 25,
            minimumPracticeRouteDistanceMeters: CLLocationDistance = 300
        ) {
            self.minimumQualifyingDuration = minimumQualifyingDuration
            self.minimumQualifyingMiles = minimumQualifyingMiles
            self.minimumHistoryDriveCount = max(1, minimumHistoryDriveCount)
            self.minimumHistoryDayCount = max(1, minimumHistoryDayCount)
            self.minimumHistoryMiles = max(0, minimumHistoryMiles)
            self.minimumHistoryTraceDuration = max(0, minimumHistoryTraceDuration)
            self.minimumRecentQualityMiles = max(0, minimumRecentQualityMiles)
            self.minimumRecentHistoryMiles = max(0, minimumRecentHistoryMiles)
            self.minimumRecentHistoryDriveCount = max(1, minimumRecentHistoryDriveCount)
            self.recentWindowDays = max(1, recentWindowDays)
            self.staleExperienceDays = max(recentWindowDays, staleExperienceDays)
            self.experienceHalfLifeDays = max(1, experienceHalfLifeDays)
            self.practiceCoverageThreshold = min(max(practiceCoverageThreshold, 0.5), 0.95)
            self.routeFamiliarityDistanceMeters = min(max(20, routeFamiliarityDistanceMeters), 45)
            self.routeFamiliaritySampleLimit = max(40, routeFamiliaritySampleLimit)
            self.minimumPracticeContiguousShare = min(max(minimumPracticeContiguousShare, 0.2), 0.9)
            self.practiceRouteMatchDistanceMeters = min(max(12, practiceRouteMatchDistanceMeters), 35)
            self.minimumPracticeRouteDistanceMeters = max(150, minimumPracticeRouteDistanceMeters)
        }
    }
}
