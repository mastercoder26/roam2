import Foundation

struct DriveLocationSample {
    let timestamp: Date
    let speedMetersPerSecond: Double
    let courseDegrees: Double?
    let courseAccuracyDegrees: Double?
    let horizontalAccuracyMeters: Double
}

struct DriveMotionSample {
    let timestamp: Date
    /// Gravity-free horizontal acceleration in g, transformed into a vertical-Z reference frame.
    let horizontalAccelerationG: Double
    /// Rotation rate in radians per second. Vehicle acceleration alone is not
    /// enough to call something phone handling, so this is kept alongside the
    /// acceleration signal for the short evidence window below.
    let rotationRateRadiansPerSecond: Double

    init(
        timestamp: Date,
        horizontalAccelerationG: Double,
        rotationRateRadiansPerSecond: Double = 0
    ) {
        self.timestamp = timestamp
        self.horizontalAccelerationG = horizontalAccelerationG
        self.rotationRateRadiansPerSecond = rotationRateRadiansPerSecond
    }
}

/// Filters Core Motion into a deliberately cautious phone-handling signal.
/// Road texture, braking, and one-off sensor spikes can all create horizontal
/// acceleration, so this requires a short sustained pattern with meaningful
/// device rotation while the vehicle is moving. It is not a distraction
/// detector; it only produces a coaching event for a clearly abrupt movement.
struct PhoneMovementDetector {
    static let minimumDrivingSpeedMetersPerSecond = 4.0
    static let evidenceWindow: TimeInterval = 0.40
    static let sustainedAccelerationThresholdG = 0.32
    static let sustainedRotationThresholdRadiansPerSecond = 0.75
    static let peakAccelerationThresholdG = 0.65
    static let peakRotationThresholdRadiansPerSecond = 1.20
    static let minimumEvidenceSampleCount = 3
    static let resetAccelerationThresholdG = 0.18
    static let resetRotationThresholdRadiansPerSecond = 0.40

    private var evidence: [DriveMotionSample] = []
    private var isLatched = false

    mutating func ingest(
        _ sample: DriveMotionSample,
        vehicleSpeedMetersPerSecond: Double,
        hasRecentAcceptedGPS: Bool
    ) -> Bool {
        guard hasRecentAcceptedGPS,
              vehicleSpeedMetersPerSecond >= Self.minimumDrivingSpeedMetersPerSecond else {
            reset()
            return false
        }

        if isLatched {
            if sample.horizontalAccelerationG < Self.resetAccelerationThresholdG,
               sample.rotationRateRadiansPerSecond < Self.resetRotationThresholdRadiansPerSecond {
                reset()
            }
            return false
        }

        evidence.append(sample)
        evidence.removeAll {
            sample.timestamp.timeIntervalSince($0.timestamp) > Self.evidenceWindow
        }

        let sustainedSamples = evidence.filter {
            $0.horizontalAccelerationG >= Self.sustainedAccelerationThresholdG &&
                $0.rotationRateRadiansPerSecond >= Self.sustainedRotationThresholdRadiansPerSecond
        }
        guard sustainedSamples.count >= Self.minimumEvidenceSampleCount else {
            return false
        }

        let evidenceDuration = (sustainedSamples.last?.timestamp ?? sample.timestamp)
            .timeIntervalSince(sustainedSamples.first?.timestamp ?? sample.timestamp)
        guard evidenceDuration >= 0.08 else { return false }

        let hasAbruptPeak = sustainedSamples.contains {
            $0.horizontalAccelerationG >= Self.peakAccelerationThresholdG &&
                $0.rotationRateRadiansPerSecond >= Self.peakRotationThresholdRadiansPerSecond
        }
        guard hasAbruptPeak else { return false }

        // Do not let the same continuous shake become a stream of events. The
        // detector must see a quiet sample before it can arm again.
        isLatched = true
        return true
    }

    mutating func reset() {
        evidence.removeAll(keepingCapacity: true)
        isLatched = false
    }
}

enum DrivingEventSource: String, Codable {
    case gpsSpeed = "GPS speed"
    case fused = "GPS + motion"
    case deviceMotion = "Device motion"
}

struct DetectedDrivingEvent {
    let kind: DrivingEventKind
    let source: DrivingEventSource
}

enum DriveScoreConfidence: String, Codable {
    case low
    case medium
    case high

    var title: String {
        switch self {
        case .low: "Preliminary"
        case .medium: "Useful sample"
        case .high: "Strong sample"
        }
    }
}

struct DriveDataQuality: Codable {
    let acceptedLocationSamples: Int
    let rejectedLocationSamples: Int
    let motionSamples: Int
    let confidence: DriveScoreConfidence
    /// Final advisory-only result from the first minute of a manual drive.
    /// No raw motion samples or episode timings are retained in saved history.
    let placementQuality: PhonePlacementAssessment?
    /// True when location authorization was withdrawn while the drive was
    /// recording, so GPS stopped partway through.
    ///
    /// Distance after that point is not measured, which makes the saved
    /// distance an undercount rather than a reading. Optional so drives written
    /// before this field existed still decode, matching `placementQuality`.
    let locationInterruptedMidDrive: Bool?
    /// True when the app was suspended in the background during the drive, so
    /// no location updates arrived for a long stretch while authorization was
    /// still granted.
    ///
    /// Deliberately distinct from `locationInterruptedMidDrive`: authorization
    /// was never withdrawn here, and reporting a suspension as revoked access
    /// would name the wrong cause. Optional so drives written before this field
    /// existed still decode.
    let recordingSuspendedInBackground: Bool?

    init(
        acceptedLocationSamples: Int,
        rejectedLocationSamples: Int,
        motionSamples: Int,
        confidence: DriveScoreConfidence,
        placementQuality: PhonePlacementAssessment? = nil,
        locationInterruptedMidDrive: Bool? = nil,
        recordingSuspendedInBackground: Bool? = nil
    ) {
        self.acceptedLocationSamples = acceptedLocationSamples
        self.rejectedLocationSamples = rejectedLocationSamples
        self.motionSamples = motionSamples
        self.confidence = confidence
        self.placementQuality = placementQuality
        self.locationInterruptedMidDrive = locationInterruptedMidDrive
        self.recordingSuspendedInBackground = recordingSuspendedInBackground
    }

    var summary: String {
        // Say this before anything about confidence: when GPS stopped partway
        // through, the recorded distance is an undercount, so describing the
        // data as "sufficient" or "sustained" would misrepresent it.
        if locationInterruptedMidDrive == true {
            return "Location access was turned off during this drive, so the distance recorded after that point is missing."
        }
        // Same reasoning, different cause: access was never withdrawn, the app
        // simply stopped receiving updates while it was in the background.
        if recordingSuspendedInBackground == true {
            return "Roam was suspended in the background for part of this drive, so the distance covered while the phone was locked is missing. Allow location access \"Always\" to record a locked-phone drive."
        }
        switch confidence {
        case .low:
            return "More time and movement data will make the next score more reliable."
        case .medium:
            return "GPS and motion data were sufficient for a useful coaching score."
        case .high:
            return "This score is based on sustained GPS and motion data."
        }
    }
}

enum DriveScoringEngine {
    static let maximumLocationAccuracyMeters = 35.0
    static let maximumCourseAccuracyDegrees = 25.0
    static let minimumSampleGap = 0.5
    static let maximumSampleGap = 5.0
    static let hardBrakeThreshold = -3.2
    static let rapidAccelerationThreshold = 2.8
    static let sharpCornerDegreesPerSecond = 28.0
    static let highMotionThresholdG = PhoneMovementDetector.peakAccelerationThresholdG

    // Confidence gates. These are stated against *usable trace* time, not
    // wall-clock time: a suspended app, a tunnel, or an urban canyon all keep
    // accruing wall-clock seconds while measuring nothing.
    static let highConfidenceUsableTraceDuration: TimeInterval = 300
    static let highConfidenceDistanceMiles = 2.0
    static let highConfidenceAcceptedSamples = 24
    static let highConfidenceMotionSamples = 1_200
    static let mediumConfidenceUsableTraceDuration: TimeInterval = 90
    static let mediumConfidenceDistanceMiles = 0.5
    static let mediumConfidenceAcceptedSamples = 8
    static let mediumConfidenceMotionSamples = 240
    /// When most delivered fixes had to be thrown away, the trace is too sparse
    /// to describe as anything but preliminary, however long the drive ran.
    static let minimumAcceptedLocationSampleShare = 0.5

    static func accepts(_ sample: DriveLocationSample) -> Bool {
        sample.horizontalAccuracyMeters > 0 &&
            sample.horizontalAccuracyMeters <= maximumLocationAccuracyMeters &&
            sample.speedMetersPerSecond >= 0
    }

    static func isPlausibleTransition(
        previous: DriveLocationSample,
        current: DriveLocationSample,
        distanceMeters: Double
    ) -> Bool {
        guard accepts(previous), accepts(current), distanceMeters >= 0 else { return false }
        let elapsed = current.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed >= minimumSampleGap, elapsed <= maximumSampleGap else { return false }

        // GPS can occasionally jump hundreds of meters despite a nominally good
        // horizontal accuracy. Allow a generous 2.4× speed envelope plus a
        // margin, while rejecting impossible distance leaps.
        let maximumExpectedDistance = max(previous.speedMetersPerSecond, current.speedMetersPerSecond) * elapsed * 2.4 + 80
        return distanceMeters <= maximumExpectedDistance
    }

    static func detectEvents(
        previous: DriveLocationSample,
        current: DriveLocationSample,
        nearbyMotionG: Double?
    ) -> [DetectedDrivingEvent] {
        guard accepts(previous), accepts(current) else { return [] }

        let elapsed = current.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed >= minimumSampleGap, elapsed <= maximumSampleGap else { return [] }

        let acceleration = (current.speedMetersPerSecond - previous.speedMetersPerSecond) / elapsed
        let motionCorroborates = (nearbyMotionG ?? 0) >= 0.18
        let source: DrivingEventSource = motionCorroborates ? .fused : .gpsSpeed
        var events: [DetectedDrivingEvent] = []

        // GPS-derived longitudinal acceleration is our primary maneuver signal.
        // Motion corroboration raises provenance, but GPS remains usable when a
        // phone is loosely mounted or motion sampling is unavailable.
        if previous.speedMetersPerSecond >= 4, acceleration <= hardBrakeThreshold {
            events.append(DetectedDrivingEvent(kind: .hardBrake, source: source))
        } else if current.speedMetersPerSecond >= 4, acceleration >= rapidAccelerationThreshold {
            events.append(DetectedDrivingEvent(kind: .rapidAcceleration, source: source))
        }

        if current.speedMetersPerSecond >= 6,
           let previousCourse = previous.courseDegrees,
           let currentCourse = current.courseDegrees,
           let previousCourseAccuracy = previous.courseAccuracyDegrees,
           let currentCourseAccuracy = current.courseAccuracyDegrees,
           previousCourseAccuracy <= maximumCourseAccuracyDegrees,
           currentCourseAccuracy <= maximumCourseAccuracyDegrees {
            let courseRate = abs(normalizedAngle(currentCourse - previousCourse)) / elapsed
            if courseRate >= sharpCornerDegreesPerSecond {
                events.append(DetectedDrivingEvent(kind: .sharpCorner, source: source))
            }
        }

        return events
    }

    /// Returns a robust short-window motion value for GPS-event provenance.
    /// A median prevents one sensor spike from making a GPS-derived braking or
    /// acceleration event look motion-confirmed.
    static func corroboratingMotionG(
        from samples: [DriveMotionSample],
        near timestamp: Date,
        window: TimeInterval = 0.35
    ) -> Double? {
        let values = samples
            .filter { abs($0.timestamp.timeIntervalSince(timestamp)) <= window }
            .map(\.horizontalAccelerationG)
            .sorted()
        guard values.count >= 3 else { return nil }
        return values[values.count / 2]
    }

    static func shouldFlagPhoneMovement(_ horizontalAccelerationG: Double) -> Bool {
        horizontalAccelerationG >= highMotionThresholdG
    }

    /// Share of delivered location fixes that survived the accuracy and
    /// plausibility filters. `nil` when no fix was ever delivered — that is a
    /// motion-only drive, not a starved one, and the sample-share gate below
    /// must not judge it.
    static func acceptedLocationSampleShare(
        acceptedLocationSamples: Int,
        rejectedLocationSamples: Int
    ) -> Double? {
        let delivered = max(0, acceptedLocationSamples) + max(0, rejectedLocationSamples)
        guard delivered > 0 else { return nil }
        return Double(max(0, acceptedLocationSamples)) / Double(delivered)
    }

    /// The honest confidence label. `usableTraceDuration` is the measured time
    /// covered by continuous, plausible GPS (`DriveTraceQuality.usableDuration`),
    /// never the drive's wall-clock length.
    static func confidence(
        usableTraceDuration: TimeInterval,
        distanceMiles: Double,
        acceptedLocationSamples: Int,
        rejectedLocationSamples: Int,
        motionSamples: Int
    ) -> DriveScoreConfidence {
        if let share = acceptedLocationSampleShare(
            acceptedLocationSamples: acceptedLocationSamples,
            rejectedLocationSamples: rejectedLocationSamples
        ), share < minimumAcceptedLocationSampleShare {
            return .low
        }

        if usableTraceDuration >= highConfidenceUsableTraceDuration,
           distanceMiles >= highConfidenceDistanceMiles,
           acceptedLocationSamples >= highConfidenceAcceptedSamples,
           motionSamples >= highConfidenceMotionSamples {
            return .high
        }
        if usableTraceDuration >= mediumConfidenceUsableTraceDuration,
           distanceMiles >= mediumConfidenceDistanceMiles,
           acceptedLocationSamples >= mediumConfidenceAcceptedSamples,
           motionSamples >= mediumConfidenceMotionSamples {
            return .medium
        }
        return .low
    }

    /// - Parameter usableTraceDuration: Measured continuous-trace time from
    ///   `DriveExperienceEngine`. Omitted only by callers that have no trace to
    ///   measure, where wall-clock duration is the sole available proxy.
    static func score(
        duration: TimeInterval,
        distanceMeters: Double,
        events: [DrivingEvent],
        acceptedLocationSamples: Int,
        rejectedLocationSamples: Int,
        motionSamples: Int,
        usableTraceDuration: TimeInterval? = nil
    ) -> (score: Int, quality: DriveDataQuality) {
        let distanceMiles = distanceMeters / 1_609.344
        // Use a 3-mile floor so a single event in a brief trip does not turn
        // into a misleadingly severe grade. The confidence label handles the
        // remaining uncertainty explicitly.
        let normalizedMiles = max(3, distanceMiles)
        let perTenMiles = 10 / normalizedMiles

        let hardBrakes = Double(events.filter { $0.kind == .hardBrake }.count) * perTenMiles
        let rapidAcceleration = Double(events.filter { $0.kind == .rapidAcceleration }.count) * perTenMiles
        let sharpCorners = Double(events.filter { $0.kind == .sharpCorner }.count) * perTenMiles
        let phoneMovement = Double(events.filter { $0.kind == .phoneMovement }.count) * perTenMiles

        let penalty = min(
            55,
            hardBrakes * 3.5 +
                rapidAcceleration * 2.5 +
                sharpCorners * 2.25 +
                phoneMovement * 0.75
        )

        // A trace can never be longer than the drive that produced it, and a
        // caller without a measured trace falls back to wall-clock time.
        let measuredTraceDuration = usableTraceDuration
            .map { max(0, min($0, max(0, duration))) } ?? duration

        return (
            score: max(20, Int((100 - penalty).rounded())),
            quality: DriveDataQuality(
                acceptedLocationSamples: acceptedLocationSamples,
                rejectedLocationSamples: rejectedLocationSamples,
                motionSamples: motionSamples,
                confidence: confidence(
                    usableTraceDuration: measuredTraceDuration,
                    distanceMiles: distanceMiles,
                    acceptedLocationSamples: acceptedLocationSamples,
                    rejectedLocationSamples: rejectedLocationSamples,
                    motionSamples: motionSamples
                )
            )
        )
    }

    private static func normalizedAngle(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped > 180 ? wrapped - 360 : (wrapped < -180 ? wrapped + 360 : wrapped)
    }
}
