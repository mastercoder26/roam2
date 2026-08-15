import CoreLocation
import CoreMotion
import Combine
import Foundation
import UIKit

/// Everything needed to reconstruct a `RecordedDrive` if the app is
/// terminated mid-drive. Deliberately mirrors only measured quantities —
/// recovery never fabricates data the way a live session's normal end-of-drive
/// summarization would not.
private struct InProgressDriveSnapshot: Codable {
    let startedAt: Date
    let recordingTimeZoneIdentifier: String?
    let route: [DriveRoutePoint]
    let events: [DrivingEvent]
    let motionSamples: Int
    let acceptedLocationSamples: Int
    let rejectedLocationSamples: Int
    let distanceMeters: CLLocationDistance
    let topSpeedMetersPerSecond: CLLocationSpeed
    let plannedRouteContext: PlannedRouteContext?
    let lastUpdatedAt: Date
    /// Optional so snapshots written before this field existed still decode —
    /// an undecodable snapshot is a lost drive, not a lost flag.
    let recordingSuspendedInBackground: Bool?
}

@MainActor
final class DriveSessionManager: NSObject, ObservableObject {
    /// The app, CarPlay scene, and Live Activity all reflect this one manual
    /// drive session. Previews and tests can still create isolated instances.
    static let shared = DriveSessionManager()

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var currentSpeedMetersPerSecond: CLLocationSpeed = 0
    @Published private(set) var motionSamples = 0
    @Published private(set) var acceptedLocationSamples = 0
    @Published private(set) var rejectedLocationSamples = 0
    @Published private(set) var currentHorizontalAccelerationG = 0.0
    @Published private(set) var statusMessage = "Ready when you are"
    @Published private(set) var lastScore: DrivingScore?
    @Published private(set) var lastCompletedDrive: RecordedDrive?
    @Published private(set) var recordedDrives: [RecordedDrive] = []
    @Published private(set) var queuedPracticeRoute: PlannedRouteContext?
    @Published private(set) var phonePlacementAssessment: PhonePlacementAssessment = .inconclusive
    /// A distinct presentation event for the root view. The queued context
    /// remains available until the driver explicitly starts or cancels it.
    @Published private(set) var practiceRoutePresentationRequest: UUID?
    /// The most recent `/api/route/difficulty` attempt per drive, kept only
    /// for on-screen debugging when a drive is stuck `.pending` — see
    /// `RouteAnalysisDebugInfo`.
    @Published private(set) var routeAnalysisDebugInfo: [UUID: RouteAnalysisDebugInfo] = [:]

    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionManager()
    private var timer: Timer?
    private var startDate: Date?
    private var previousLocation: CLLocation?
    @Published private(set) var distanceMeters: CLLocationDistance = 0
    private var topSpeed: CLLocationSpeed = 0
    private var events: [DrivingEvent] = []
    private var lastEventAt: [DrivingEventKind: Date] = [:]
    private var recentMotionSamples: [DriveMotionSample] = []
    private var phoneMovementDetector = PhoneMovementDetector()
    private var phonePlacementAnalyzer = PhonePlacementAnalyzer(startedAt: .distantPast)
    private var routePoints: [DriveRoutePoint] = []
    private var latestCoordinate: DriveCoordinate?
    private var latestAcceptedLocationAt: Date?
    private var recordingTimeZoneIdentifier: String?
    private var activePracticeRoute: PlannedRouteContext?
    // The encoded route is deliberately memory-only. Saved drives receive the
    // privacy-safe context plus a local overlap result, never an address,
    // polyline, or other planned-route geometry.
    private var queuedPracticeRoutePolyline: String?
    private var activePracticeRoutePolyline: String?
    private let historyKey = "recorded-drives-v1"
    /// Holds a history blob this build could not decode, so it survives for a
    /// later build to recover instead of being overwritten with an empty list.
    private let quarantinedHistoryKey = "recorded-drives-v1-quarantined"
    /// Set when `loadRecordedDrives` could not read the stored history. While
    /// true, `saveRecordedDrives` refuses to write — an in-memory list that is
    /// empty only because decoding failed must never replace the real one.
    private var isHistoryUnreadable = false
    /// A throttled, incremental snapshot of the drive in progress. Without
    /// this, a background termination (low memory, force quit, or a crash)
    /// mid-drive would lose every sample the driver has already produced —
    /// the worst failure mode for this feature. `endDrive()` removes this key
    /// on a normal finish; only an interrupted session leaves it behind for
    /// `recoverInterruptedDriveIfNeeded()` to find on the next launch.
    private let inProgressDriveKey = "in-progress-drive-v1"
    /// Holds an interrupted-drive snapshot this build could not decode, so it
    /// survives for a later build instead of being erased on first read.
    private let quarantinedInProgressDriveKey = "in-progress-drive-v1-quarantined"
    private var lastProgressPersistAt: Date?
    /// Set when location authorization is withdrawn while recording, so the
    /// saved drive can state that its distance stops short of the real trip.
    private var didLoseLocationMidDrive = false
    /// Set when a long stretch of the drive produced no location updates while
    /// background updates were not permitted — the *When In Use* + locked-phone
    /// case. Deliberately separate from `didLoseLocationMidDrive`: nothing was
    /// revoked, so reporting it as revoked access would name the wrong cause.
    private var didSuspendRecordingInBackground = false
    /// Whether the app was backgrounded at any point during this drive. A long
    /// GPS gap while the app stayed on screen is ordinary starvation, not
    /// suspension, and must not be reported as one.
    private var didEnterBackgroundDuringDrive = false
    private var backgroundEntryObserver: NSObjectProtocol?
    /// A gap shorter than this is ordinary GPS starvation (a tunnel, a parking
    /// garage, a stop at a light). Only a sustained silence is evidence that
    /// the app itself stopped being scheduled.
    private static let backgroundSuspensionGapSeconds: TimeInterval = 60
    private var routeAnalysisTasks: [UUID: Task<Void, Never>] = [:]

    var currentDistanceMiles: Double { distanceMeters / 1_609.344 }
    var currentSpeedMilesPerHour: Int { Int((max(currentSpeedMetersPerSecond, 0) * 2.23694).rounded()) }
    var currentEventCount: Int { events.count }
    var formattedElapsed: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = elapsed >= 3_600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: elapsed) ?? "0m"
    }

    /// Route analysis is gated on a signed-in account, so the session needs to
    /// read auth state. It is injectable only so the checks can drive the
    /// signed-out path without a Clerk session.
    private let authSession: AuthSessionStore

    init(authSession: AuthSessionStore = .shared) {
        self.authSession = authSession
        super.init()
        locationManager.delegate = self
        locationManager.activityType = .automotiveNavigation
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = 5
        locationManager.pausesLocationUpdatesAutomatically = false
        loadRecordedDrives()
        recoverInterruptedDriveIfNeeded()
        resumeRouteAnalysesIfNeeded()
        // Nothing is recording at launch, so any Live Activity still on screen
        // is a leftover from a drive that was terminated before it could end.
        DriveLiveActivityManager.shared.endOrphanedActivities()
        observeBackgroundEntry()
    }

    /// Notes that the app left the screen while a drive was recording. This is
    /// the precondition for calling a later GPS gap a background suspension
    /// rather than ordinary signal loss.
    private func observeBackgroundEntry() {
        backgroundEntryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.didEnterBackgroundDuringDrive = true
            }
        }
    }

    func startDrive() {
        guard !isRecording else { return }

        // Copy the context into the recording before removing it from the
        // pre-drive queue. Starting remains entirely manual; this only tags
        // the resulting local record after the driver chooses to begin.
        activePracticeRoute = queuedPracticeRoute
        activePracticeRoutePolyline = queuedPracticeRoutePolyline
        queuedPracticeRoute = nil
        queuedPracticeRoutePolyline = nil
        // Defensive: a snapshot should never survive to a new drive (endDrive
        // clears it, and startup recovery clears it too), but never let a
        // stale one leak into this drive's saved history if it somehow did.
        UserDefaults.standard.removeObject(forKey: inProgressDriveKey)
        lastProgressPersistAt = nil
        resetCurrentDrive()
        let driveStart = Date()
        recordingTimeZoneIdentifier = TimeZone.autoupdatingCurrent.identifier
        isRecording = true
        startDate = driveStart
        phonePlacementAnalyzer.reset(startedAt: driveStart)
        phonePlacementAssessment = .inconclusive
        lastCompletedDrive = nil
        statusMessage = "Recording this drive"
        startElapsedTimer()
        startMotionUpdates()
        DriveLiveActivityManager.shared.start(
            startedAt: driveStart,
            speedMetersPerSecond: currentSpeedMetersPerSecond,
            distanceMeters: distanceMeters,
            eventCount: events.count,
            status: statusMessage
        )

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways:
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.startUpdatingLocation()
        case .authorizedWhenInUse:
            locationManager.startUpdatingLocation()
            // A manual drive should keep recording after the user locks the
            // phone. iOS presents the additional permission only after the
            // user has already started a drive.
            locationManager.requestAlwaysAuthorization()
        case .denied, .restricted:
            statusMessage = "Location access is off. Motion will still be recorded."
        @unknown default:
            statusMessage = "Waiting for location permission"
        }
    }

    func endDrive() {
        guard isRecording else { return }
        let driveEndedAt = Date()
        let duration = driveEndedAt.timeIntervalSince(startDate ?? driveEndedAt)
        isRecording = false
        timer?.invalidate()
        timer = nil
        motionManager.stopDeviceMotionUpdates()
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
        currentSpeedMetersPerSecond = 0

        defer {
            // A normal end-of-drive path always produces a definitive outcome
            // (saved or discarded) below, so the interrupted-drive snapshot must
            // not stick around to be "recovered" as a duplicate next launch.
            //
            // This clears in `defer` rather than up front because the save path
            // below runs heavy synchronous scoring and summarization first. When
            // the snapshot was dropped before that work, a termination in the
            // gap lost the drive entirely — the snapshot was already gone and
            // the record had not been written yet. Clearing last means the
            // recovery path stays armed until the drive is durably saved.
            UserDefaults.standard.removeObject(forKey: inProgressDriveKey)
            lastProgressPersistAt = nil
            activePracticeRoute = nil
            activePracticeRoutePolyline = nil
            recordingTimeZoneIdentifier = nil
        }

        // Accidental taps and false starts should not clutter history.
        // Elapsed/distance stay visible through the return animation, matching
        // the saved-drive path; startDrive() clears them via resetCurrentDrive().
        guard DriveHistoryPolicy.shouldSave(duration: duration) else {
            _ = phonePlacementAnalyzer.finish(at: driveEndedAt)
            phonePlacementAssessment = .inconclusive
            statusMessage = "Drive under 30s was not saved"
            DriveLiveActivityManager.shared.end(
                speedMetersPerSecond: 0,
                distanceMeters: distanceMeters,
                eventCount: events.count,
                status: "Drive discarded"
            )
            return
        }

        noteTrailingLocationGap(endedAt: driveEndedAt)
        let result = DriveScoringEngine.score(
            duration: duration,
            distanceMeters: distanceMeters,
            events: events,
            acceptedLocationSamples: acceptedLocationSamples,
            rejectedLocationSamples: rejectedLocationSamples,
            motionSamples: motionSamples,
            usableTraceDuration: usableTraceDuration(for: routePoints)
        )
        let finalPlacementQuality = phonePlacementAnalyzer.finish(at: driveEndedAt)
        phonePlacementAssessment = finalPlacementQuality
        let dataQuality = DriveDataQuality(
            acceptedLocationSamples: result.quality.acceptedLocationSamples,
            rejectedLocationSamples: result.quality.rejectedLocationSamples,
            motionSamples: result.quality.motionSamples,
            confidence: result.quality.confidence,
            placementQuality: finalPlacementQuality,
            locationInterruptedMidDrive: didLoseLocationMidDrive ? true : nil,
            recordingSuspendedInBackground: didSuspendRecordingInBackground ? true : nil
        )
        let score = DrivingScore(
            score: result.score,
            duration: duration,
            distanceMeters: distanceMeters,
            topSpeedMetersPerSecond: topSpeed,
            events: events,
            motionSamples: motionSamples,
            dataQuality: dataQuality
        )
        lastScore = score
        let practiceCoverage = activePracticeRoute.flatMap { context in
            activePracticeRoutePolyline.map {
                DriverReadinessEngine.practiceRouteCoverage(
                    plannedPolyline: $0,
                    recordedRoute: routePoints,
                    demands: context.routeDemands
                )
            }
        }
        let driveStartedAt = startDate ?? Date()
        let coverageSummary = practiceCoverage.map {
            PracticeRouteCoverageSummary(coverage: $0, recordedAt: driveEndedAt)
        }
        let routeMatched = coverageSummary?.isVerifiedRoutePractice ?? false
        let contextBeforeDebrief = activePracticeRoute.map { context in
            PlannedRouteContext(
                id: context.id,
                createdAt: context.createdAt,
                routeDemands: context.routeDemands,
                recordedRouteMatched: routeMatched,
                // Demand-specific evidence is retained only when enough of a
                // directionally aligned route was measured.
                verifiedDemandExposures: routeMatched
                    ? coverageSummary?.verifiedDemandExposures()
                    : nil,
                practicePlan: context.practicePlan,
                coverageSummary: coverageSummary
            )
        }
        let unsummarizedDrive = RecordedDrive(
            startedAt: driveStartedAt,
            score: score,
            route: routePoints,
            recordingTimeZoneIdentifier: recordingTimeZoneIdentifier,
            plannedRouteContext: contextBeforeDebrief
        )
        let initialRouteAnalysis: DriveRouteAnalysis = DriveRouteAnalysisEngine.endpoints(for: unsummarizedDrive) == nil
            ? .unavailable("Route difficulty needs a longer continuous GPS trace from start to destination.")
            : .pending
        let summarizedDrive = RecordedDrive(
            id: unsummarizedDrive.id,
            startedAt: driveStartedAt,
            score: score,
            route: routePoints,
            recordingTimeZoneIdentifier: recordingTimeZoneIdentifier,
            experienceSummary: DriveExperienceEngine.summarize(drive: unsummarizedDrive),
            plannedRouteContext: contextBeforeDebrief,
            routeAnalysis: initialRouteAnalysis
        )
        let profileBefore = DriverReadinessEngine.profile(from: recordedDrives)
        let profileAfter = DriverReadinessEngine.profile(from: [summarizedDrive] + recordedDrives)
        let debrief = contextBeforeDebrief?.practicePlan.map { plan in
            PracticePlanEngine.makeDebrief(
                plan: plan,
                savedDrive: summarizedDrive,
                coverage: coverageSummary,
                profileBefore: profileBefore,
                profileAfter: profileAfter,
                createdAt: driveEndedAt
            )
        }
        let persistedPracticeRoute = contextBeforeDebrief.map { context in
            PlannedRouteContext(
                id: context.id,
                createdAt: context.createdAt,
                routeDemands: context.routeDemands,
                recordedRouteMatched: context.recordedRouteMatched,
                verifiedDemandExposures: context.verifiedDemandExposures,
                practicePlan: context.practicePlan,
                coverageSummary: context.coverageSummary,
                debrief: debrief
            )
        }
        let drive = RecordedDrive(
            id: summarizedDrive.id,
            startedAt: summarizedDrive.startedAt,
            score: summarizedDrive.score,
            route: summarizedDrive.route,
            recordingTimeZoneIdentifier: summarizedDrive.recordingTimeZoneIdentifier,
            experienceSummary: summarizedDrive.experienceSummary,
            plannedRouteContext: persistedPracticeRoute,
            routeAnalysis: initialRouteAnalysis
        )
        let practiceRouteWasVerified = persistedPracticeRoute?.recordedRouteMatched
        recordedDrives = Array(([drive] + recordedDrives).prefix(50))
        saveRecordedDrives()
        requestDriveHistorySync()
        lastCompletedDrive = drive
        if didSuspendRecordingInBackground {
            statusMessage = "Drive saved. Roam was suspended in the background for part of it, so some distance is missing."
        } else if initialRouteAnalysis.status == .pending {
            statusMessage = DriveStatusMessageEngine.analyzing
        } else if finalPlacementQuality == .needsAdjustment {
            statusMessage = "Drive saved. Secure the phone when it is safe before your next drive."
        } else if motionSamples == 0 {
            statusMessage = "No motion samples received."
        } else if practiceRouteWasVerified == true {
            statusMessage = "Drive saved. Route overlap verified."
        } else if practiceRouteWasVerified == false {
            statusMessage = "Drive saved. Route overlap unverified."
        } else {
            statusMessage = "Drive saved on this device"
        }
        DriveLiveActivityManager.shared.end(
            speedMetersPerSecond: 0,
            distanceMeters: distanceMeters,
            eventCount: events.count,
            status: "Drive saved"
        )
        if initialRouteAnalysis.status == .pending {
            beginAutomaticRouteAnalysis(for: drive)
        }
    }

    /// Removes a saved drive from on-device history. No-ops when the id is absent.
    func deleteDrive(id: UUID) {
        let next = DriveHistoryPolicy.removing(id: id, from: recordedDrives)
        guard next.count != recordedDrives.count else { return }
        recordedDrives = next
        saveRecordedDrives()
        if lastCompletedDrive?.id == id {
            lastCompletedDrive = nil
            lastScore = nil
        }
        // Deleting a drive whose route analysis is still in flight should not
        // leave a network request running only to be discarded by
        // `replaceSavedDrive`'s existence guard when it completes.
        routeAnalysisTasks[id]?.cancel()
        routeAnalysisTasks[id] = nil
        requestDriveHistorySync()
    }

    /// Analyzes only the start and destination of a completed drive after its
    /// local record is safely persisted. Any unavailable network or provider
    /// result is recorded as analysis context; it never removes the drive.
    private func beginAutomaticRouteAnalysis(for drive: RecordedDrive) {
        guard routeAnalysisTasks[drive.id] == nil,
              let currentAnalysis = drive.routeAnalysis else {
            return
        }
        guard currentAnalysis.shouldRetry() else {
            // No task is in flight and no retry is left, so a drive still
            // marked `.pending` here — killed mid-request, or out of retries —
            // has nothing that can ever complete it. Resolve it rather than
            // leaving the UI spinning "Analyzing route" indefinitely.
            if currentAnalysis.isStalled() {
                replaceSavedDrive(
                    id: drive.id,
                    routeAnalysis: .unavailable(
                        "Route difficulty could not be analyzed for this drive. The drive and its coaching score are still saved."
                    )
                )
            }
            return
        }
        guard let endpoints = DriveRouteAnalysisEngine.endpoints(for: drive) else {
            replaceSavedDrive(
                id: drive.id,
                routeAnalysis: .unavailable("Route difficulty needs a longer continuous GPS trace from start to destination.")
            )
            return
        }

        // Route analysis proxies a metered upstream API, so the backend only
        // serves signed-in accounts. Signing in later should analyze this
        // drive, so the attempt stays retry-eligible rather than being spent.
        guard authSession.isSignedIn else {
            routeAnalysisDebugInfo[drive.id] = RouteAnalysisDebugInfo(
                endpointPath: "api/route/difficulty",
                attemptedAt: Date(),
                durationSeconds: 0,
                retryCount: currentAnalysis.retryCount ?? 0,
                outcome: .other("Not attempted: no signed-in account")
            )
            replaceSavedDrive(
                id: drive.id,
                routeAnalysis: .unavailable(
                    "Sign in to analyze this route's difficulty. The drive and its coaching score are still saved.",
                    retryEligible: true,
                    lastAttemptAt: currentAnalysis.lastAttemptAt,
                    retryCount: currentAnalysis.retryCount ?? 0
                )
            )
            return
        }

        let attemptedAnalysis = currentAnalysis.recordingAttempt()
        replaceSavedDrive(id: drive.id, routeAnalysis: attemptedAnalysis)

        let attemptStartedAt = Date()
        let task = Task { [weak self] in
            defer { self?.routeAnalysisTasks[drive.id] = nil }
            guard let self else { return }

            do {
                let response = try await self.authSession.performAuthenticated { token in
                    try await APIClient().analyzeRoute(
                        origin: endpoints.origin,
                        destination: endpoints.destination,
                        accessToken: token,
                        includeAlternates: false,
                        continuousDriveMinutes: drive.score.duration / 60
                    )
                }
                guard !Task.isCancelled else { return }
                self.routeAnalysisDebugInfo[drive.id] = RouteAnalysisDebugInfo(
                    endpointPath: "api/route/difficulty",
                    attemptedAt: attemptStartedAt,
                    durationSeconds: Date().timeIntervalSince(attemptStartedAt),
                    retryCount: attemptedAnalysis.retryCount ?? 1,
                    outcome: .success
                )
                self.replaceSavedDrive(
                    id: drive.id,
                    routeAnalysis: DriveRouteAnalysisEngine.result(from: response.primaryRoute)
                )
            } catch {
                guard !Task.isCancelled else { return }
                self.routeAnalysisDebugInfo[drive.id] = RouteAnalysisDebugInfo(
                    endpointPath: "api/route/difficulty",
                    attemptedAt: attemptStartedAt,
                    durationSeconds: Date().timeIntervalSince(attemptStartedAt),
                    retryCount: attemptedAnalysis.retryCount ?? 1,
                    outcome: RouteAnalysisDebugInfo.outcome(for: error)
                )
                self.replaceSavedDrive(
                    id: drive.id,
                    routeAnalysis: .unavailable(
                        "Route difficulty could not be analyzed right now. The drive and its coaching score are still saved.",
                        retryEligible: true,
                        lastAttemptAt: attemptedAnalysis.lastAttemptAt,
                        retryCount: attemptedAnalysis.retryCount ?? 1
                    )
                )
            }
        }
        routeAnalysisTasks[drive.id] = task
    }

    private func replaceSavedDrive(id: UUID, routeAnalysis: DriveRouteAnalysis) {
        guard recordedDrives.contains(where: { $0.id == id }) else { return }
        let updatedDrives = recordedDrives.map { drive in
            drive.id == id ? drive.replacingRouteAnalysis(with: routeAnalysis) : drive
        }
        recordedDrives = updatedDrives
        if lastCompletedDrive?.id == id {
            lastCompletedDrive = updatedDrives.first(where: { $0.id == id })
            // The banner was set to "Analyzing route difficulty" when the drive
            // was saved and nothing else retires it, so without this it reads
            // as analyzing forever — long after the request succeeded or
            // failed. Only that exact text is replaced: a banner about a
            // background suspension or phone placement still matters more.
            if statusMessage == DriveStatusMessageEngine.analyzing,
               let resolved = DriveStatusMessageEngine.resolvedMessage(for: routeAnalysis) {
                statusMessage = resolved
            }
        }
        saveRecordedDrives()
        requestDriveHistorySync()
    }

    /// Applies a server merge without changing the on-disk shape of the
    /// existing recorded-drive blob. Sync owns the remote confirmation marker;
    /// this manager remains the local source of truth for the actual drives.
    func applySyncedRecordedDrives(_ drives: [RecordedDrive]) {
        guard !isHistoryUnreadable else { return }
        recordedDrives = drives
        if let lastCompletedDrive {
            self.lastCompletedDrive = drives.first(where: { $0.id == lastCompletedDrive.id })
        }
        saveRecordedDrives()
    }

    private func requestDriveHistorySync() {
        DriveHistorySyncService.shared.sync(
            localDrives: recordedDrives,
            applyLocalDrives: { [weak self] drives in
                self?.applySyncedRecordedDrives(drives)
            }
        )
    }

    /// Queues a locally generated route context for the next manually started
    /// drive. The route geometry stays in memory solely to verify GPS overlap
    /// when the drive ends; this deliberately never calls `startDrive()`.
    func queuePlannedPracticeRoute(_ route: ScoredRoute, practicePlan: PracticePlan? = nil) {
        guard !isRecording else { return }
        queuedPracticeRoute = PlannedRouteContext(
            routeDemands: route.routeDemands ?? [],
            practicePlan: practicePlan
        )
        queuedPracticeRoutePolyline = route.polyline
        practiceRoutePresentationRequest = UUID()
    }

    /// Cancels a pre-drive route tag without affecting any saved drive.
    func clearPlannedPracticeRoute() {
        guard !isRecording else { return }
        queuedPracticeRoute = nil
        queuedPracticeRoutePolyline = nil
        practiceRoutePresentationRequest = nil
    }

    private func resetCurrentDrive() {
        startDate = nil
        elapsed = 0
        currentSpeedMetersPerSecond = 0
        motionSamples = 0
        acceptedLocationSamples = 0
        rejectedLocationSamples = 0
        currentHorizontalAccelerationG = 0
        previousLocation = nil
        didLoseLocationMidDrive = false
        didSuspendRecordingInBackground = false
        didEnterBackgroundDuringDrive = false
        distanceMeters = 0
        topSpeed = 0
        events = []
        lastEventAt = [:]
        recentMotionSamples = []
        phoneMovementDetector.reset()
        phonePlacementAnalyzer.reset(startedAt: .distantPast)
        phonePlacementAssessment = .inconclusive
        routePoints = []
        latestCoordinate = nil
        latestAcceptedLocationAt = nil
        recordingTimeZoneIdentifier = nil
    }

    private func startElapsedTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let startDate = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(startDate)
                self.publishLiveDriveSnapshot()
                // Persist from the clock, not only from accepted GPS samples and
                // coaching events. A motion-only drive (location denied, phone
                // cradled so no handling episode fires) previously wrote nothing
                // at all, so a mid-drive termination lost it completely — or,
                // worse, left a single early snapshot that recovered a 50-minute
                // trip as a 2-minute, 0-mile record. `persistInProgressSnapshot`
                // throttles itself to once per 10s, so this stays cheap.
                self.persistInProgressSnapshot()
            }
        }
    }

    private func startMotionUpdates() {
        guard motionManager.isDeviceMotionAvailable else {
            statusMessage = "Motion data is unavailable on this device"
            phonePlacementAssessment = .unavailable
            return
        }

        motionManager.deviceMotionUpdateInterval = 1.0 / 20.0
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let self, let motion, self.isRecording else { return }
            self.record(motion: motion)
        }
    }

    private func record(motion: CMDeviceMotion) {
        motionSamples += 1

        // `userAcceleration` removes gravity. Transform it into a vertical-Z
        // reference frame before measuring horizontal force so phone orientation
        // does not change the reading.
        let acceleration = motion.userAcceleration
        let matrix = motion.attitude.rotationMatrix
        let worldX = matrix.m11 * acceleration.x + matrix.m12 * acceleration.y + matrix.m13 * acceleration.z
        let worldY = matrix.m21 * acceleration.x + matrix.m22 * acceleration.y + matrix.m23 * acceleration.z
        let horizontalG = hypot(worldX, worldY)
        currentHorizontalAccelerationG = horizontalG
        let rotation = motion.rotationRate
        let rotationRate = sqrt(
            rotation.x * rotation.x +
                rotation.y * rotation.y +
                rotation.z * rotation.z
        )
        let timestamp = Date()
        let motionSample = DriveMotionSample(
            timestamp: timestamp,
            horizontalAccelerationG: horizontalG,
            rotationRateRadiansPerSecond: rotationRate
        )

        recentMotionSamples.append(motionSample)
        recentMotionSamples.removeAll { timestamp.timeIntervalSince($0.timestamp) > 2 }

        let hasFreshAcceptedGPS = latestAcceptedLocationAt.map {
            abs(timestamp.timeIntervalSince($0)) <= 2
        } ?? false
        let handlingEpisode = phoneMovementDetector.ingest(
            motionSample,
            vehicleSpeedMetersPerSecond: currentSpeedMetersPerSecond,
            hasRecentAcceptedGPS: hasFreshAcceptedGPS
        )
        phonePlacementAssessment = phonePlacementAnalyzer.ingest(
            PhonePlacementObservation(
                timestamp: timestamp,
                vehicleSpeedMetersPerSecond: currentSpeedMetersPerSecond,
                hasRecentAcceptedGPS: hasFreshAcceptedGPS,
                motionDataAvailable: true,
                highConfidenceHandlingEpisode: handlingEpisode
            )
        )

        if handlingEpisode {
            addEvent(
                .phoneMovement,
                timestamp: timestamp,
                coordinate: latestCoordinate,
                source: .deviceMotion,
                cooldown: 10
            )
        }
    }

    private func record(location: CLLocation) {
        let sample = DriveLocationSample(
            timestamp: location.timestamp,
            speedMetersPerSecond: location.speed,
            courseDegrees: location.course >= 0 ? location.course : nil,
            courseAccuracyDegrees: location.courseAccuracy >= 0 ? location.courseAccuracy : nil,
            horizontalAccuracyMeters: location.horizontalAccuracy
        )

        guard DriveScoringEngine.accepts(sample) else {
            rejectedLocationSamples += 1
            return
        }

        acceptedLocationSamples += 1
        let speed = max(location.speed, 0)
        currentSpeedMetersPerSecond = speed
        topSpeed = max(topSpeed, speed)
        let routePoint = DriveRoutePoint(timestamp: location.timestamp, coordinate: DriveCoordinate(location.coordinate), speedMetersPerSecond: speed)

        if let previousLocation {
            let time = location.timestamp.timeIntervalSince(previousLocation.timestamp)
            if time >= DriveScoringEngine.minimumSampleGap, time <= DriveScoringEngine.maximumSampleGap {
                let previousSample = DriveLocationSample(
                    timestamp: previousLocation.timestamp,
                    speedMetersPerSecond: previousLocation.speed,
                    courseDegrees: previousLocation.course >= 0 ? previousLocation.course : nil,
                    courseAccuracyDegrees: previousLocation.courseAccuracy >= 0 ? previousLocation.courseAccuracy : nil,
                    horizontalAccuracyMeters: previousLocation.horizontalAccuracy
                )
                let distance = location.distance(from: previousLocation)
                guard DriveScoringEngine.isPlausibleTransition(
                    previous: previousSample,
                    current: sample,
                    distanceMeters: distance
                ) else {
                    rejectedLocationSamples += 1
                    return
                }
                distanceMeters += distance
                appendRoutePoint(routePoint)
                let nearbyMotion = DriveScoringEngine.corroboratingMotionG(
                    from: recentMotionSamples,
                    near: location.timestamp
                )
                for event in DriveScoringEngine.detectEvents(
                    previous: previousSample,
                    current: sample,
                    nearbyMotionG: nearbyMotion
                ) {
                    let cooldown: TimeInterval = event.kind == .sharpCorner ? 5 : 4
                    addEvent(event.kind, timestamp: location.timestamp, coordinate: routePoint.coordinate, source: event.source, cooldown: cooldown)
                }
            } else if time > DriveScoringEngine.maximumSampleGap {
                // Resume the route after a long background gap without drawing
                // a synthetic straight line or deriving a false acceleration.
                noteLocationGap(seconds: time)
                appendRoutePoint(routePoint)
            }
        } else {
            appendRoutePoint(routePoint)
        }

        previousLocation = location
        latestCoordinate = routePoint.coordinate
        latestAcceptedLocationAt = location.timestamp
        publishLiveDriveSnapshot()
        persistInProgressSnapshot()
    }

    /// Records that a stretch of the drive produced no location fixes. Without
    /// this a *When In Use* drive with a locked phone saved as 45 minutes and
    /// 0.2 miles with nothing at all to explain the missing distance.
    private func noteLocationGap(seconds: TimeInterval) {
        guard seconds >= Self.backgroundSuspensionGapSeconds,
              didEnterBackgroundDuringDrive,
              !locationManager.allowsBackgroundLocationUpdates else { return }
        didSuspendRecordingInBackground = true
    }

    /// The trailing silence between the last accepted fix and the end of the
    /// drive. A phone locked at minute 1 and unlocked only to stop recording
    /// never delivers the fix that would otherwise close the gap.
    private func noteTrailingLocationGap(endedAt: Date) {
        guard let latestAcceptedLocationAt else { return }
        noteLocationGap(seconds: endedAt.timeIntervalSince(latestAcceptedLocationAt))
    }

    /// Continuous, plausible trace time — the same measure
    /// `DriveTraceQuality.usableDuration` reports. Confidence is stated against
    /// this rather than the drive's wall-clock length.
    private func usableTraceDuration(for route: [DriveRoutePoint]) -> TimeInterval {
        DriveExperienceEngine.validTraceSegments(for: route)
            .reduce(0) { $0 + $1.duration }
    }

    private func appendRoutePoint(_ point: DriveRoutePoint) {
        // One point per ~5 m from CLLocation plus a time-based escape hatch is
        // enough to draw a faithful route without unbounded storage.
        if let last = routePoints.last,
           point.timestamp.timeIntervalSince(last.timestamp) < 1,
           CLLocation(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)
                .distance(from: CLLocation(latitude: point.coordinate.latitude, longitude: point.coordinate.longitude)) < 5 {
            return
        }
        routePoints.append(point)
    }

    private func addEvent(_ kind: DrivingEventKind, timestamp: Date, coordinate: DriveCoordinate?, source: DrivingEventSource, cooldown: TimeInterval) {
        if let lastEvent = lastEventAt[kind], timestamp.timeIntervalSince(lastEvent) < cooldown { return }
        lastEventAt[kind] = timestamp
        events.append(DrivingEvent(kind: kind, timestamp: timestamp, source: source, coordinate: coordinate))
        publishLiveDriveSnapshot(force: true)
        // Force past the normal throttle so a coaching event is never the
        // thing lost if the app is killed a moment later.
        persistInProgressSnapshot(force: true)
    }

    private func publishLiveDriveSnapshot(force: Bool = false) {
        guard isRecording else { return }
        DriveLiveActivityManager.shared.update(
            speedMetersPerSecond: currentSpeedMetersPerSecond,
            distanceMeters: distanceMeters,
            eventCount: events.count,
            status: statusMessage,
            force: force
        )
    }

    private func loadRecordedDrives() {
        guard let data = UserDefaults.standard.data(forKey: historyKey) else { return }
        do {
            recordedDrives = try JSONDecoder().decode([RecordedDrive].self, from: data)
        } catch {
            // Decoding `[RecordedDrive]` is all-or-nothing, so one unreadable
            // element — or one added non-optional field in a new build — used to
            // present as "no history". The next save then wrote that empty list
            // straight over an intact blob, permanently destroying every drive.
            // Keep the original bytes, refuse to write over them, and say so.
            UserDefaults.standard.set(data, forKey: quarantinedHistoryKey)
            isHistoryUnreadable = true
            recordedDrives = []
            statusMessage = "Saved drives could not be opened in this version. They are kept on the device and are not being overwritten."
            return
        }
        backfillHistoricalRouteAnalysis()
    }

    /// Older drives are assessed locally from their saved trace. This gives
    /// existing history a transparent score contribution without uploading past
    /// endpoints simply because the app was updated.
    private func backfillHistoricalRouteAnalysis() {
        let updated = recordedDrives.map { drive -> RecordedDrive in
            guard drive.routeAnalysis == nil,
                  let localEstimate = DriveRouteAnalysisEngine.estimated(from: drive) else {
                return drive
            }
            return drive.replacingRouteAnalysis(with: localEstimate)
        }
        guard zip(recordedDrives, updated).contains(where: { $0.routeAnalysis != $1.routeAnalysis }) else { return }
        recordedDrives = updated
        saveRecordedDrives()
    }

    /// Restarts analyses that outlived their request — a drive left `.pending`
    /// by a terminated app, or one whose retry became due. Called at launch and
    /// again on every foreground: waiting for a full relaunch was the
    /// difference between "retries when you next open the app" and "stays on
    /// Analyzing until the app is force-quit".
    func resumeRouteAnalysesIfNeeded() {
        for drive in recordedDrives where drive.routeAnalysis?.shouldRetry() == true
            || drive.routeAnalysis?.isStalled() == true {
            beginAutomaticRouteAnalysis(for: drive)
        }
    }

    private func saveRecordedDrives() {
        // Never overwrite a history this build could not read. `recordedDrives`
        // is empty in that case only because decoding failed, and writing it
        // back would destroy every stored drive irreversibly.
        guard !isHistoryUnreadable else { return }
        guard let data = try? JSONEncoder().encode(recordedDrives) else { return }
        UserDefaults.standard.set(data, forKey: historyKey)
    }

    /// Writes a throttled, incremental snapshot of the drive in progress so a
    /// background termination loses at most a few seconds of the newest
    /// samples instead of the entire session. Silent encoding failure is
    /// intentional here — a snapshot write is a best-effort safety net, not a
    /// requirement for `endDrive()`'s own, authoritative save path.
    private func persistInProgressSnapshot(force: Bool = false) {
        guard isRecording, let startDate else { return }
        let now = Date()
        if !force, let last = lastProgressPersistAt, now.timeIntervalSince(last) < 10 {
            return
        }
        lastProgressPersistAt = now

        let snapshot = InProgressDriveSnapshot(
            startedAt: startDate,
            recordingTimeZoneIdentifier: recordingTimeZoneIdentifier,
            route: routePoints,
            events: events,
            motionSamples: motionSamples,
            acceptedLocationSamples: acceptedLocationSamples,
            rejectedLocationSamples: rejectedLocationSamples,
            distanceMeters: distanceMeters,
            topSpeedMetersPerSecond: topSpeed,
            plannedRouteContext: activePracticeRoute,
            lastUpdatedAt: now,
            recordingSuspendedInBackground: didSuspendRecordingInBackground ? true : nil
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: inProgressDriveKey)
    }

    /// Recovers a drive that never reached `endDrive()` because the app was
    /// terminated while recording. This is the difference between silently
    /// losing an entire drive and saving everything measured up to the last
    /// persisted snapshot. Recovery reuses the same scoring and summarization
    /// path as a normal end-of-drive save; it never fabricates a duration or
    /// distance beyond what was actually recorded, and a placement assessment
    /// is not available because the drive never reached a normal `finish`.
    private func recoverInterruptedDriveIfNeeded() {
        guard let data = UserDefaults.standard.data(forKey: inProgressDriveKey) else { return }
        // Decode before clearing. Removing the key first meant any decode
        // failure — a new build adding a required field, a partial write —
        // destroyed the only copy of the interrupted drive with no retry.
        guard let snapshot = try? JSONDecoder().decode(InProgressDriveSnapshot.self, from: data) else {
            // Keep the bytes for a future build, but move them off the live key
            // so an undecodable payload is not re-read on every launch.
            UserDefaults.standard.set(data, forKey: quarantinedInProgressDriveKey)
            UserDefaults.standard.removeObject(forKey: inProgressDriveKey)
            return
        }
        guard !isHistoryUnreadable else {
            statusMessage = "Recovered drive is waiting, but saved drives could not be opened in this version. Update Roam before recording another drive."
            return
        }
        UserDefaults.standard.removeObject(forKey: inProgressDriveKey)

        let duration = snapshot.lastUpdatedAt.timeIntervalSince(snapshot.startedAt)
        guard duration > 0, DriveHistoryPolicy.shouldSave(duration: duration) else { return }

        let result = DriveScoringEngine.score(
            duration: duration,
            distanceMeters: snapshot.distanceMeters,
            events: snapshot.events,
            acceptedLocationSamples: snapshot.acceptedLocationSamples,
            rejectedLocationSamples: snapshot.rejectedLocationSamples,
            motionSamples: snapshot.motionSamples,
            usableTraceDuration: usableTraceDuration(for: snapshot.route)
        )
        let dataQuality = DriveDataQuality(
            acceptedLocationSamples: result.quality.acceptedLocationSamples,
            rejectedLocationSamples: result.quality.rejectedLocationSamples,
            motionSamples: result.quality.motionSamples,
            confidence: result.quality.confidence,
            placementQuality: nil,
            recordingSuspendedInBackground: snapshot.recordingSuspendedInBackground
        )
        let score = DrivingScore(
            score: result.score,
            duration: duration,
            distanceMeters: snapshot.distanceMeters,
            topSpeedMetersPerSecond: snapshot.topSpeedMetersPerSecond,
            events: snapshot.events,
            motionSamples: snapshot.motionSamples,
            dataQuality: dataQuality
        )
        let unsummarizedDrive = RecordedDrive(
            startedAt: snapshot.startedAt,
            score: score,
            route: snapshot.route,
            recordingTimeZoneIdentifier: snapshot.recordingTimeZoneIdentifier,
            plannedRouteContext: snapshot.plannedRouteContext
        )
        let initialRouteAnalysis: DriveRouteAnalysis = DriveRouteAnalysisEngine.endpoints(for: unsummarizedDrive) == nil
            ? .unavailable("Route difficulty needs a longer continuous GPS trace from start to destination.")
            : .pending
        let recoveredDrive = RecordedDrive(
            id: unsummarizedDrive.id,
            startedAt: snapshot.startedAt,
            score: score,
            route: snapshot.route,
            recordingTimeZoneIdentifier: snapshot.recordingTimeZoneIdentifier,
            experienceSummary: DriveExperienceEngine.summarize(drive: unsummarizedDrive),
            plannedRouteContext: snapshot.plannedRouteContext,
            routeAnalysis: initialRouteAnalysis
        )
        recordedDrives = Array(([recoveredDrive] + recordedDrives).prefix(50))
        saveRecordedDrives()
        lastCompletedDrive = recoveredDrive
        lastScore = score
        statusMessage = "Recovered a drive that was interrupted before it could finish saving normally."
        if initialRouteAnalysis.status == .pending {
            beginAutomaticRouteAnalysis(for: recoveredDrive)
        }
    }
}

extension DriveSessionManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self, self.isRecording else { return }
            switch manager.authorizationStatus {
            case .authorizedAlways:
                manager.allowsBackgroundLocationUpdates = true
                manager.startUpdatingLocation()
                self.statusMessage = "Recording this drive"
            case .authorizedWhenInUse:
                manager.startUpdatingLocation()
                self.statusMessage = "Recording this drive"
            case .denied, .restricted:
                // Authorization was withdrawn mid-drive. Previously this only
                // set a transient status string: location updates were left
                // running, nothing was recorded on the drive, and `endDrive()`
                // overwrote the message with "Drive saved on this device". A
                // 30-mile trip whose GPS was cut at mile 6 saved as a 6-mile
                // drive with a full score and no indication anything was lost.
                manager.stopUpdatingLocation()
                manager.allowsBackgroundLocationUpdates = false
                self.didLoseLocationMidDrive = true
                self.statusMessage = "Location access is off. Motion will still be recorded."
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor [weak self] in
            self?.record(location: location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard self?.isRecording == true else { return }
            self?.statusMessage = "Location update failed. Motion recording continues."
        }
    }
}
