import CoreLocation
import Combine
import Foundation

enum RoutePlanningOriginState: Equatable {
    case awaitingOrigin
    case locating
    case resolved(String)
    case manualEntry(message: String?)

    /// Destination entry unlocks once the driver has chosen current location
    /// (including while it resolves) or a resolved address exists. Manual entry
    /// must finish before the destination field appears.
    var allowsDestination: Bool {
        switch self {
        case .awaitingOrigin, .manualEntry:
            return false
        case .locating, .resolved:
            return true
        }
    }
}

/// How usable a single Core Location fix is as a starting point. Core Location
/// can succeed with a fix far too coarse to describe a street address, and it
/// reports that success through `didUpdateLocations`, never through
/// `didFailWithError` — so the quality has to be judged here.
enum RoutePlanningLocationFixQuality: Equatable {
    /// Good enough to fill the starting address with no caveat.
    case precise
    /// Usable, but the address it resolves to may be the wrong block.
    case degraded
    /// Invalid, or too vague to describe a starting point at all.
    case unusable
}

/// The coarse-fix policy, kept free of Core Location state so it can be
/// checked on its own.
enum RoutePlanningLocationFixPolicy {
    /// A fix at or under this horizontal accuracy fills the field silently.
    static let preferredAccuracyMeters: CLLocationAccuracy = 150
    /// Above this, a fix says so little about where the driver is that using
    /// it would be worse than asking for the address.
    static let maximumUsableAccuracyMeters: CLLocationAccuracy = 1_000
    /// How long "Finding current location" may run before Roam either uses the
    /// best coarse fix it has, or hands the driver back to manual entry.
    static let locationTimeout: TimeInterval = 12

    static let timeoutMessage = "Roam couldn't get an accurate location in time. Enter a starting address instead."

    static func quality(ofAccuracy horizontalAccuracy: CLLocationAccuracy) -> RoutePlanningLocationFixQuality {
        guard horizontalAccuracy >= 0, horizontalAccuracy.isFinite else { return .unusable }
        if horizontalAccuracy <= preferredAccuracyMeters { return .precise }
        if horizontalAccuracy <= maximumUsableAccuracyMeters { return .degraded }
        return .unusable
    }

    static func accuracyNotice(forAccuracy horizontalAccuracy: CLLocationAccuracy) -> String? {
        guard quality(ofAccuracy: horizontalAccuracy) == .degraded else { return nil }
        let meters = Int(horizontalAccuracy.rounded())
        return "This location is only accurate to about \(meters) m, so the address may be off. Check it, or enter a starting address yourself."
    }
}

@MainActor
final class RoutePlanningLocationCoordinator: NSObject, ObservableObject {
    @Published private(set) var state: RoutePlanningOriginState = .awaitingOrigin
    /// Set when the resolved address came from a coarse fix. Shown next to the
    /// address so an approximate origin is never presented as an exact one.
    @Published private(set) var accuracyNotice: String?

    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    /// The most accurate coarse fix seen so far. It is used only if nothing
    /// better arrives before the deadline.
    private var bestDegradedFix: CLLocation?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = kCLDistanceFilterNone
    }

    func useCurrentLocation() {
        guard CLLocationManager.locationServicesEnabled() else {
            useManualEntry(message: "Location Services is unavailable. Enter a starting address instead.")
            return
        }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            // The system permission prompt owns the wait here, so the deadline
            // starts only once authorization actually arrives.
            resetPendingFix()
            state = .locating
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            beginLocating()
        case .denied, .restricted:
            useManualEntry(message: "Location access is off. Enter a starting address instead.")
        @unknown default:
            useManualEntry(message: "We couldn't access your location. Enter a starting address instead.")
        }
    }

    func useManualEntry(message: String? = nil) {
        stopLocating()
        accuracyNotice = nil
        state = .manualEntry(message: message)
    }

    private func beginLocating() {
        resetPendingFix()
        state = .locating
        locationManager.startUpdatingLocation()
        startTimeout()
    }

    private func startTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            let timeout = RoutePlanningLocationFixPolicy.locationTimeout
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.handleTimeout()
        }
    }

    private func handleTimeout() async {
        guard case .locating = state else { return }
        guard let fallback = bestDegradedFix else {
            useManualEntry(message: RoutePlanningLocationFixPolicy.timeoutMessage)
            return
        }
        await accept(fallback)
    }

    private func resetPendingFix() {
        timeoutTask?.cancel()
        timeoutTask = nil
        bestDegradedFix = nil
        accuracyNotice = nil
    }

    private func stopLocating() {
        timeoutTask?.cancel()
        timeoutTask = nil
        bestDegradedFix = nil
        locationManager.stopUpdatingLocation()
    }

    fileprivate func handle(_ locations: [CLLocation]) async {
        guard case .locating = state else { return }
        guard let candidate = locations
            .filter({ RoutePlanningLocationFixPolicy.quality(ofAccuracy: $0.horizontalAccuracy) != .unusable })
            .min(by: { $0.horizontalAccuracy < $1.horizontalAccuracy }) else {
            return
        }

        switch RoutePlanningLocationFixPolicy.quality(ofAccuracy: candidate.horizontalAccuracy) {
        case .precise:
            await accept(candidate)
        case .degraded:
            // Keep waiting for something better; the deadline will use this.
            if let best = bestDegradedFix, best.horizontalAccuracy <= candidate.horizontalAccuracy {
                return
            }
            bestDegradedFix = candidate
        case .unusable:
            return
        }
    }

    private func accept(_ location: CLLocation) async {
        let notice = RoutePlanningLocationFixPolicy.accuracyNotice(forAccuracy: location.horizontalAccuracy)
        stopLocating()
        await resolve(location, notice: notice)
    }

    private func resolve(_ location: CLLocation, notice: String?) async {
        do {
            let placemark = try await geocoder.reverseGeocodeLocation(location).first
            guard let address = Self.address(from: placemark) else {
                useManualEntry(message: "We couldn't turn that location into an address. Enter one instead.")
                return
            }
            accuracyNotice = notice
            state = .resolved(address)
        } catch {
            useManualEntry(message: "We couldn't confirm your address. Enter it manually instead.")
        }
    }

    static func address(from placemark: CLPlacemark?) -> String? {
        guard let placemark else { return nil }
        let street = [placemark.subThoroughfare, placemark.thoroughfare]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let locality = [placemark.locality, placemark.administrativeArea, placemark.postalCode]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        let parts = [street, locality, placemark.country ?? ""].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

extension RoutePlanningLocationCoordinator: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self, case .locating = self.state else { return }
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                self.beginLocating()
            case .denied, .restricted:
                self.useManualEntry(message: "Location access is off. Enter a starting address instead.")
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            await self?.handle(locations)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.useManualEntry(message: "We couldn't get a current location. Enter a starting address instead.")
        }
    }
}
