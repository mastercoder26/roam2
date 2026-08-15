import Foundation

/// A passive data-quality assessment. It never identifies handheld use and
/// never blocks a drive; the only actionable result is a gentle prompt to
/// secure the phone when it is safe to do so.
enum PhonePlacementAssessment: String, Codable, Hashable {
    case stable
    case needsAdjustment
    case inconclusive
    case unavailable
}

/// One motion-tick input supplied by the recording session. The high-confidence
/// flag must come from `PhoneMovementDetector`, not from a raw acceleration
/// threshold, so small movement and road texture cannot create a placement
/// warning.
struct PhonePlacementObservation: Hashable {
    let timestamp: Date
    let vehicleSpeedMetersPerSecond: Double
    let hasRecentAcceptedGPS: Bool
    let motionDataAvailable: Bool
    let highConfidenceHandlingEpisode: Bool

    init(
        timestamp: Date,
        vehicleSpeedMetersPerSecond: Double,
        hasRecentAcceptedGPS: Bool,
        motionDataAvailable: Bool,
        highConfidenceHandlingEpisode: Bool
    ) {
        self.timestamp = timestamp
        self.vehicleSpeedMetersPerSecond = vehicleSpeedMetersPerSecond
        self.hasRecentAcceptedGPS = hasRecentAcceptedGPS
        self.motionDataAvailable = motionDataAvailable
        self.highConfidenceHandlingEpisode = highConfidenceHandlingEpisode
    }
}

/// Stateful, first-minute placement assessment for a manually started drive.
/// It only counts contiguous observation while fresh accepted GPS says the
/// vehicle is moving and Core Motion is available. Two well-separated, already
/// high-confidence handling episodes are required before it suggests that the
/// sensor placement may be unstable.
struct PhonePlacementAnalyzer {
    static let assessmentWindow: TimeInterval = 60
    static let minimumUsableObservation: TimeInterval = 15
    static let maximumObservationGap: TimeInterval = 2
    static let episodeSeparation: TimeInterval = 8

    private(set) var startedAt: Date
    private var usableObservationDuration: TimeInterval = 0
    private var lastUsableObservationAt: Date?
    private var hasSeenMotionData = false
    private var episodeTimestamps: [Date] = []

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    /// Starts a fresh manual-drive window. A recording session can reuse this
    /// analyzer safely without carrying an old warning into a new drive.
    mutating func reset(startedAt: Date) {
        self.startedAt = startedAt
        usableObservationDuration = 0
        lastUsableObservationAt = nil
        hasSeenMotionData = false
        episodeTimestamps.removeAll(keepingCapacity: true)
    }

    var assessment: PhonePlacementAssessment {
        guard hasSeenMotionData else { return .unavailable }
        guard usableObservationDuration >= Self.minimumUsableObservation else {
            return .inconclusive
        }
        return episodeTimestamps.count >= 2 ? .needsAdjustment : .stable
    }

    var measuredDrivingObservation: TimeInterval { usableObservationDuration }
    var highConfidenceEpisodeCount: Int { episodeTimestamps.count }

    /// Ingest every available motion tick during a manual drive. Inputs outside
    /// the first minute, without recent GPS, or below driving speed do not earn
    /// observation time or episode evidence.
    @discardableResult
    mutating func ingest(_ observation: PhonePlacementObservation) -> PhonePlacementAssessment {
        guard observation.timestamp >= startedAt,
              observation.timestamp.timeIntervalSince(startedAt) < Self.assessmentWindow else {
            return assessment
        }

        if observation.motionDataAvailable {
            hasSeenMotionData = true
        }

        guard observation.motionDataAvailable,
              observation.hasRecentAcceptedGPS,
              observation.vehicleSpeedMetersPerSecond >= PhoneMovementDetector.minimumDrivingSpeedMetersPerSecond else {
            lastUsableObservationAt = nil
            return assessment
        }

        if let lastUsableObservationAt {
            let elapsed = observation.timestamp.timeIntervalSince(lastUsableObservationAt)
            if elapsed > 0, elapsed <= Self.maximumObservationGap {
                usableObservationDuration += elapsed
            }
        }
        lastUsableObservationAt = observation.timestamp

        if observation.highConfidenceHandlingEpisode,
           episodeTimestamps.last.map({
               observation.timestamp.timeIntervalSince($0) >= Self.episodeSeparation
           }) ?? true {
            episodeTimestamps.append(observation.timestamp)
        }

        return assessment
    }

    /// Ends the passive assessment without changing it. This makes an early
    /// manual stop explicitly return inconclusive instead of a false stable
    /// result.
    func finish(at _: Date) -> PhonePlacementAssessment {
        assessment
    }
}
