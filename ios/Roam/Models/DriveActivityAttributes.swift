import ActivityKit
import Foundation

/// The small, privacy-safe state shown while a manually started drive is in
/// progress. It is shared by the app and the Live Activity extension.
struct DriveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let speedMilesPerHour: Int
        let distanceMiles: Double
        let eventCount: Int
        let status: String
    }

    /// The Lock Screen and Dynamic Island render this with the system timer
    /// style, so elapsed time stays accurate without continuous updates.
    let startedAt: Date
}
