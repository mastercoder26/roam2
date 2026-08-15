import ActivityKit
import Foundation

/// Owns the short-lived Live Activity for a manually started drive. It never
/// includes a route, address, or raw location data.
@MainActor
final class DriveLiveActivityManager {
    static let shared = DriveLiveActivityManager()

    private var activity: Activity<DriveActivityAttributes>?
    private var lastUpdateAt = Date.distantPast

    /// Prevents a fast start/end sequence from creating an activity after the
    /// manual drive has already finished.
    private var requestedDriveID: UUID?

    private init() {}

    func start(
        startedAt: Date,
        speedMetersPerSecond: Double,
        distanceMeters: Double,
        eventCount: Int,
        status: String
    ) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let driveID = UUID()
        requestedDriveID = driveID

        let content = content(
            speedMetersPerSecond: speedMetersPerSecond,
            distanceMeters: distanceMeters,
            eventCount: eventCount,
            status: status
        )

        Task {
            for existingActivity in Activity<DriveActivityAttributes>.activities {
                await existingActivity.end(nil, dismissalPolicy: .immediate)
            }

            guard requestedDriveID == driveID else { return }

            do {
                let requestedActivity = try Activity.request(
                    attributes: DriveActivityAttributes(startedAt: startedAt),
                    content: content,
                    pushType: nil
                )
                guard requestedDriveID == driveID else {
                    await requestedActivity.end(content, dismissalPolicy: .immediate)
                    return
                }
                activity = requestedActivity
                lastUpdateAt = Date()
            } catch {
                // A Live Activity is a helpful glanceable surface, never a
                // requirement for recording a drive. The drive continues if
                // the system has disabled or declined it.
                activity = nil
            }
        }
    }

    /// Ends any Live Activity the system is still showing from a previous app
    /// launch.
    ///
    /// `end(...)` can only act on the in-memory `activity` handle, which does
    /// not survive termination, and the sweep inside `start(...)` only runs when
    /// a *new* drive begins. So a drive interrupted by a jetsam left a Lock
    /// Screen card reading "Recording this drive" — with frozen speed, distance,
    /// and event counts — until the system's own staleness limit expired it,
    /// telling the user a drive was recording when none was. Called at launch so
    /// the surface matches reality even if the user never starts another drive.
    func endOrphanedActivities() {
        Task {
            for staleActivity in Activity<DriveActivityAttributes>.activities {
                await staleActivity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func update(
        speedMetersPerSecond: Double,
        distanceMeters: Double,
        eventCount: Int,
        status: String,
        force: Bool = false
    ) {
        let now = Date()
        guard force || now.timeIntervalSince(lastUpdateAt) >= 12 else { return }
        guard let activity else { return }

        lastUpdateAt = now
        let content = content(
            speedMetersPerSecond: speedMetersPerSecond,
            distanceMeters: distanceMeters,
            eventCount: eventCount,
            status: status
        )
        Task {
            await activity.update(content)
        }
    }

    func end(
        speedMetersPerSecond: Double,
        distanceMeters: Double,
        eventCount: Int,
        status: String
    ) {
        requestedDriveID = nil
        guard let activity else { return }
        self.activity = nil

        let content = content(
            speedMetersPerSecond: speedMetersPerSecond,
            distanceMeters: distanceMeters,
            eventCount: eventCount,
            status: status
        )
        Task {
            await activity.end(content, dismissalPolicy: .immediate)
        }
    }

    private func content(
        speedMetersPerSecond: Double,
        distanceMeters: Double,
        eventCount: Int,
        status: String
    ) -> ActivityContent<DriveActivityAttributes.ContentState> {
        ActivityContent(
            state: DriveActivityAttributes.ContentState(
                speedMilesPerHour: Int((max(speedMetersPerSecond, 0) * 2.23694).rounded()),
                distanceMiles: max(distanceMeters, 0) / 1_609.344,
                eventCount: max(eventCount, 0),
                status: status
            ),
            staleDate: nil
        )
    }
}
