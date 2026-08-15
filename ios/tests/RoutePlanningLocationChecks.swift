import CoreLocation
import Foundation

@main
struct RoutePlanningLocationChecks {
    static func main() {
        originStateGatesDestinationEntry()
        coarseFixesAreClassifiedHonestly()
        aDegradedFixCarriesAVisibleCaveat()
        theTimeoutMessagePointsAtManualEntry()
        print("Route planning location checks passed")
    }

    private static func originStateGatesDestinationEntry() {
        expect(!RoutePlanningOriginState.awaitingOrigin.allowsDestination, "destination must be hidden before an origin is chosen")
        expect(RoutePlanningOriginState.locating.allowsDestination, "choosing current location should unlock destination while it resolves")
        expect(!RoutePlanningOriginState.manualEntry(message: nil).allowsDestination, "manual entry must be completed before destination is shown")
        expect(RoutePlanningOriginState.resolved("1 Infinite Loop, Cupertino, CA").allowsDestination, "resolved origin must unlock destination")
    }

    private static func coarseFixesAreClassifiedHonestly() {
        typealias Coordinator = RoutePlanningLocationFixPolicy

        expect(Coordinator.quality(ofAccuracy: 12) == .precise, "a normal GPS fix should fill the field with no caveat")
        expect(Coordinator.quality(ofAccuracy: 150) == .precise, "the preferred accuracy bound should be inclusive")
        expect(
            Coordinator.quality(ofAccuracy: 400) == .degraded,
            "a 400 m parking-garage fix must be usable, not silently discarded into a permanent spinner"
        )
        expect(Coordinator.quality(ofAccuracy: 1_000) == .degraded, "the usable accuracy bound should be inclusive")
        expect(Coordinator.quality(ofAccuracy: 4_000) == .unusable, "a fix that vague says nothing about a starting point")
        expect(Coordinator.quality(ofAccuracy: -1) == .unusable, "an invalid accuracy must never be treated as a location")
        expect(
            Coordinator.quality(ofAccuracy: .infinity) == .unusable,
            "a non-finite accuracy must not reach the Int conversion in the caveat text"
        )
    }

    private static func aDegradedFixCarriesAVisibleCaveat() {
        typealias Coordinator = RoutePlanningLocationFixPolicy

        expect(Coordinator.accuracyNotice(forAccuracy: 20) == nil, "an accurate fix should not add noise to the form")
        guard let notice = Coordinator.accuracyNotice(forAccuracy: 400) else {
            fail("a degraded fix must be labelled as approximate rather than presented as exact")
        }
        expect(notice.contains("400 m"), "the caveat should state how approximate the location is")
        expect(
            notice.lowercased().contains("enter"),
            "the caveat should point at manual entry as the way to correct it"
        )
        expect(Coordinator.accuracyNotice(forAccuracy: 4_000) == nil, "an unusable fix is rejected, not captioned")
    }

    private static func theTimeoutMessagePointsAtManualEntry() {
        let message = RoutePlanningLocationFixPolicy.timeoutMessage
        expect(!message.isEmpty, "a timed-out location must explain itself instead of spinning forever")
        expect(
            message.lowercased().contains("starting address"),
            "the timeout message must name the action the driver can take"
        )
        expect(
            RoutePlanningLocationFixPolicy.locationTimeout > 0,
            "the locating deadline must be a real bound"
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fatalError("Route planning location check failed: \(message)")
    }
}
