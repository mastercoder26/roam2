import CarPlay
import Combine
import Foundation

/// A deliberately glanceable CarPlay surface for the same manually started
/// drive that appears in the iPhone app. Starting and ending a drive remain
/// iPhone-only so this display does not encourage interaction while moving.
@MainActor
final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate {
    private let driveSession = DriveSessionManager.shared
    private var dashboard: CPInformationTemplate?
    private var refreshTimer: Timer?
    private var observation: AnyCancellable?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        connect(interfaceController)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        connect(interfaceController)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        disconnect()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController: CPInterfaceController
    ) {
        disconnect()
    }

    private func connect(_ interfaceController: CPInterfaceController) {
        let template = CPInformationTemplate(
            title: "Roam",
            layout: .twoColumn,
            items: dashboardItems,
            actions: []
        )
        dashboard = template
        interfaceController.setRootTemplate(template, animated: false, completion: nil)

        observation = driveSession.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshDashboard()
            }
        }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshDashboard()
            }
        }
    }

    private func disconnect() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        observation = nil
        dashboard = nil
    }

    private func refreshDashboard() {
        dashboard?.title = driveSession.isRecording ? "Drive in progress" : "Roam"
        dashboard?.items = dashboardItems
    }

    private var dashboardItems: [CPInformationItem] {
        guard driveSession.isRecording else {
            return [
                CPInformationItem(title: "Status", detail: "No drive recording"),
                CPInformationItem(title: "Start a drive", detail: "Use the Roam app on iPhone before leaving")
            ]
        }

        return [
            CPInformationItem(title: "Time", detail: driveSession.formattedElapsed),
            CPInformationItem(title: "Distance", detail: String(format: "%.1f mi", driveSession.currentDistanceMiles)),
            CPInformationItem(title: "Speed", detail: "\(driveSession.currentSpeedMilesPerHour) mph"),
            CPInformationItem(title: "Motion", detail: String(format: "%.2f g", driveSession.currentHorizontalAccelerationG)),
            CPInformationItem(title: "Measured events", detail: "\(driveSession.currentEventCount)")
        ]
    }
}
