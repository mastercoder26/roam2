import Combine
import Foundation

enum RoutePlanningOriginMode: Equatable {
    case currentLocation
    case manual
}

/// The visible planning step. Keeping this pure means the origin-to-
/// destination progression stays consistent whether the start comes from the
/// current-location flow, manual entry, or a shared Maps route.
enum RoutePlanningStage: Equatable {
    case chooseOrigin
    case chooseDestination
    case readyToAnalyze

    init(origin: String, destination: String) {
        let hasOrigin = !origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasDestination = !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if !hasOrigin {
            self = .chooseOrigin
        } else if !hasDestination {
            self = .chooseDestination
        } else {
            self = .readyToAnalyze
        }
    }
}

/// The visual state for the Apple Maps planning preview. It deliberately
/// follows the same endpoint validation as the form so the map never invents
/// a route before the user has supplied both endpoints.
enum RoutePlanningMapPreviewStage: Equatable {
    /// A neutral Apple Maps viewport shown until a real origin exists. The
    /// map remains mounted so planning always has geographic context.
    case locationPrompt
    case startingPoint
    case route

    init(origin: String, destination: String, usesCurrentLocation: Bool) {
        let hasOrigin = usesCurrentLocation || !origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasDestination = !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if hasOrigin && hasDestination {
            self = .route
        } else if hasOrigin {
            self = .startingPoint
        } else {
            self = .locationPrompt
        }
    }
}

/// Pure presentation decisions for the first route screen. The form remains
/// useful when people enter a destination first, but the next action stays
/// explicit: select or type the origin before analysis can begin.
struct RoutePlanningFormPresentation: Equatable {
    let stage: RoutePlanningStage
    let mapPreviewStage: RoutePlanningMapPreviewStage

    init(origin: String, destination: String, usesCurrentLocation: Bool) {
        stage = RoutePlanningStage(origin: origin, destination: destination)
        mapPreviewStage = RoutePlanningMapPreviewStage(
            origin: origin,
            destination: destination,
            usesCurrentLocation: usesCurrentLocation
        )
    }

    /// Keep both endpoints in view from the first frame. This avoids making a
    /// route look like a one-field task and helps people who know their
    /// destination before deciding where to start.
    var showsDestination: Bool { true }

    /// Location permission is requested only from a deliberate, labelled tap.
    var showsCurrentLocationAction: Bool { stage == .chooseOrigin }
}

struct RouteImportNotice: Equatable {
    let title: String
    let message: String
    let isError: Bool
}

struct RoutePlanningFormState: Equatable {
    var origin: String
    var destination: String
    var originMode: RoutePlanningOriginMode
    var departureTime: Date
    var importedRouteID: UUID?
    var importNotice: RouteImportNotice?

    init(
        origin: String = "",
        destination: String = "",
        originMode: RoutePlanningOriginMode = .manual,
        departureTime: Date = Date().addingTimeInterval(15 * 60),
        importedRouteID: UUID? = nil,
        importNotice: RouteImportNotice? = nil
    ) {
        self.origin = origin
        self.destination = destination
        self.originMode = originMode
        self.departureTime = departureTime
        self.importedRouteID = importedRouteID
        self.importNotice = importNotice
    }
}

enum RoutePlanningFormReducer {
    static func applying(
        _ route: SharedRouteDraft,
        to current: RoutePlanningFormState
    ) -> RoutePlanningFormState {
        guard current.importedRouteID != route.id else { return current }

        let usesCurrentLocation = route.origin == nil
        let extraStopsMessage: String
        if route.waypointCount > 0 {
            extraStopsMessage = " This shared route has \(route.waypointCount) additional stop\(route.waypointCount == 1 ? "" : "s"). Roam will analyze the start and final destination."
        } else {
            extraStopsMessage = ""
        }

        return RoutePlanningFormState(
            origin: route.origin ?? "",
            destination: route.destination,
            originMode: usesCurrentLocation ? .currentLocation : .manual,
            departureTime: current.departureTime,
            importedRouteID: route.id,
            importNotice: RouteImportNotice(
                title: "Imported from \(route.provider.displayName)",
                message: "Review the route, then analyze it. Roam recalculates a driving route from these locations.\(extraStopsMessage)",
                isError: false
            )
        )
    }
}

@MainActor
final class RoutePlanningFormModel: ObservableObject {
    @Published var origin: String
    @Published var destination: String
    @Published var originMode: RoutePlanningOriginMode
    @Published var departureTime: Date
    @Published private(set) var importedRouteID: UUID?
    @Published private(set) var importNotice: RouteImportNotice?

    init(initialState: RoutePlanningFormState = RoutePlanningFormState()) {
        origin = initialState.origin
        destination = initialState.destination
        originMode = initialState.originMode
        departureTime = initialState.departureTime
        importedRouteID = initialState.importedRouteID
        importNotice = initialState.importNotice
    }

    var usesCurrentLocation: Bool {
        get { originMode == .currentLocation }
        set { originMode = newValue ? .currentLocation : .manual }
    }

    func apply(_ route: SharedRouteDraft) {
        let next = RoutePlanningFormReducer.applying(route, to: state)
        apply(next)
    }

    func presentImportError(_ message: String) {
        importNotice = RouteImportNotice(
            title: "Map route could not be imported",
            message: message,
            isError: true
        )
    }

    func clearImportNotice() {
        importNotice = nil
    }

    private var state: RoutePlanningFormState {
        RoutePlanningFormState(
            origin: origin,
            destination: destination,
            originMode: originMode,
            departureTime: departureTime,
            importedRouteID: importedRouteID,
            importNotice: importNotice
        )
    }

    private func apply(_ state: RoutePlanningFormState) {
        origin = state.origin
        destination = state.destination
        originMode = state.originMode
        departureTime = state.departureTime
        importedRouteID = state.importedRouteID
        importNotice = state.importNotice
    }
}
