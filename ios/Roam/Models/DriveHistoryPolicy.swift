import Foundation

/// Persistence rules for on-device drive history. Kept free of UIKit /
/// CoreLocation so standalone checks can cover the boundaries.
enum DriveHistoryPolicy {
    /// Drives shorter than this are discarded when the session ends.
    static let minimumSavedDriveSeconds: TimeInterval = 30

    static func shouldSave(duration: TimeInterval) -> Bool {
        duration >= minimumSavedDriveSeconds
    }

    static func removing<T: Identifiable>(id: UUID, from items: [T]) -> [T] where T.ID == UUID {
        items.filter { $0.id != id }
    }
}
