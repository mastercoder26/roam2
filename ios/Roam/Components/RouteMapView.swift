import MapKit
import SwiftUI

/// MapKit caches the renderer and annotation view it created for an overlay,
/// so a theme switch has to repaint them in place. Re-adding the overlay would
/// re-run the directions request and refit the camera.
extension MKMapView {
    func repaintThemedOverlays(stroke: UIColor) {
        for overlay in overlays {
            guard let renderer = renderer(for: overlay) as? MKPolylineRenderer else { continue }
            renderer.strokeColor = stroke
            renderer.setNeedsDisplay()
        }
    }
}

struct RouteMapView: UIViewRepresentable {
    @ObservedObject private var theme = ThemeManager.shared
    let polyline: String
    let bounds: RouteBounds
    var routeColor: UIColor = AppDesign.UIKitColor.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var interfaceStyle: UIUserInterfaceStyle {
        colorScheme == .dark ? .dark : .light
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.overrideUserInterfaceStyle = interfaceStyle
        mapView.isRotateEnabled = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsCompass = false
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        mapView.overrideUserInterfaceStyle = interfaceStyle
        mapView.repaintThemedOverlays(stroke: routeColor)
        context.coordinator.routeColor = routeColor
        context.coordinator.reduceMotion = reduceMotion
        context.coordinator.update(mapView: mapView, polyline: polyline, bounds: bounds)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var renderedKey: String?
        var routeColor: UIColor = AppDesign.UIKitColor.accent
        var reduceMotion = false

        func update(mapView: MKMapView, polyline: String, bounds: RouteBounds) {
            let renderKey = makeRenderKey(polyline: polyline, bounds: bounds)
            guard renderedKey != renderKey else { return }
            renderedKey = renderKey

            CATransaction.begin()
            if reduceMotion {
                CATransaction.setDisableActions(true)
            } else {
                CATransaction.setAnimationDuration(AppAnimation.mapDuration)
                CATransaction.setAnimationTimingFunction(
                    CAMediaTimingFunction(controlPoints: 0.77, 0, 0.175, 1)
                )
            }

            mapView.removeOverlays(mapView.overlays)

            guard let routePolyline = PolylineDecoder.mkPolyline(from: polyline) else {
                CATransaction.commit()
                return
            }
            mapView.addOverlay(routePolyline)

            let region = region(for: bounds, polyline: polyline)
            mapView.setVisibleMapRect(
                region,
                edgePadding: UIEdgeInsets(top: 32, left: 24, bottom: 32, right: 24),
                animated: !reduceMotion
            )
            CATransaction.commit()
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = routeColor
                renderer.lineWidth = 4.5
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        private func region(for bounds: RouteBounds, polyline: String) -> MKMapRect {
            let sw = bounds.mapRect.southwest
            let ne = bounds.mapRect.northeast

            let minLat = min(sw.latitude, ne.latitude)
            let maxLat = max(sw.latitude, ne.latitude)
            let minLng = min(sw.longitude, ne.longitude)
            let maxLng = max(sw.longitude, ne.longitude)

            let topLeft = MKMapPoint(CLLocationCoordinate2D(latitude: maxLat, longitude: minLng))
            let bottomRight = MKMapPoint(CLLocationCoordinate2D(latitude: minLat, longitude: maxLng))
            var rect = MKMapRect(
                x: topLeft.x,
                y: topLeft.y,
                width: bottomRight.x - topLeft.x,
                height: bottomRight.y - topLeft.y
            )

            if rect.isNull || rect.size.width == 0 || rect.size.height == 0 {
                let coords = PolylineDecoder.decode(polyline)
                rect = coords.reduce(MKMapRect.null) { partial, coordinate in
                    let point = MKMapPoint(coordinate)
                    let pointRect = MKMapRect(x: point.x, y: point.y, width: 0, height: 0)
                    return partial.isNull ? pointRect : partial.union(pointRect)
                }
            }

            return rect.isNull ? MKMapRect.world : rect
        }

        private func makeRenderKey(polyline: String, bounds: RouteBounds) -> String {
            let resolvedColor = routeColor.resolvedColor(with: .current)
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            let colorKey: String
            if resolvedColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
                colorKey = "\(red),\(green),\(blue),\(alpha)"
            } else {
                colorKey = resolvedColor.description
            }
            return [
                polyline,
                String(bounds.southwest.latitude),
                String(bounds.southwest.longitude),
                String(bounds.northeast.latitude),
                String(bounds.northeast.longitude),
                colorKey,
            ].joined(separator: "|")
        }
    }
}

// MARK: - Polyline decoding
enum PolylineDecoder {
    /// Decodes a Google-encoded polyline string into coordinates.
    static func decode(_ encoded: String) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        var index = encoded.startIndex
        var latitude: Int32 = 0
        var longitude: Int32 = 0

        while index < encoded.endIndex {
            guard let latResult = decodeComponent(from: encoded, index: &index) else { break }
            latitude += latResult

            guard let lngResult = decodeComponent(from: encoded, index: &index) else { break }
            longitude += lngResult

            coordinates.append(
                CLLocationCoordinate2D(
                    latitude: Double(latitude) / 1e5,
                    longitude: Double(longitude) / 1e5
                )
            )
        }

        return coordinates
    }

    static func mkPolyline(from encoded: String) -> MKPolyline? {
        let coords = decode(encoded)
        guard !coords.isEmpty else { return nil }
        return MKPolyline(coordinates: coords, count: coords.count)
    }

    private static func decodeComponent(from encoded: String, index: inout String.Index) -> Int32? {
        var result: Int32 = 0
        var shift: Int32 = 0
        var byte: Int32

        repeat {
            guard index < encoded.endIndex else { return nil }
            let scalar = encoded[index].asciiValue.map(Int32.init) ?? 0
            index = encoded.index(after: index)
            byte = scalar - 63
            result |= (byte & 0x1F) << shift
            shift += 5
        } while byte >= 0x20

        let delta = (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
        return delta
    }
}

#Preview {
    RouteMapView(
        polyline: "_p~iF~ps|U_ulLnnqC_mqNvxq`@",
        bounds: RouteBounds(
            southwest: Coordinate(latitude: 38.5, longitude: -120.2),
            northeast: Coordinate(latitude: 40.7, longitude: -120.95)
        )
    )
    .frame(height: 220)
    .clipShape(RoundedRectangle(cornerRadius: AppDesign.cornerRadius, style: .continuous))
}

/// A locally recorded route with replay annotations. A moment is shown only
/// when its timestamp falls inside a verified continuous GPS segment.
struct RecordedDriveMapView: UIViewRepresentable {
    @ObservedObject private var theme = ThemeManager.shared
    let route: [DriveRoutePoint]
    let moments: [DriveReplayMoment]
    var selectedEventID: UUID?
    var onSelectMoment: (DriveReplayMoment) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var interfaceStyle: UIUserInterfaceStyle {
        colorScheme == .dark ? .dark : .light
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = interfaceStyle
        map.isRotateEnabled = false
        map.showsCompass = false
        map.pointOfInterestFilter = .excludingAll
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.overrideUserInterfaceStyle = interfaceStyle
        context.coordinator.onSelectMoment = onSelectMoment
        context.coordinator.reduceMotion = reduceMotion
        map.repaintThemedOverlays(stroke: AppDesign.UIKitColor.accent)
        context.coordinator.repaintMarkers(in: map)
        context.coordinator.update(
            map: map,
            route: route,
            moments: moments,
            selectedEventID: selectedEventID
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelectMoment: onSelectMoment) }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onSelectMoment: (DriveReplayMoment) -> Void
        private var renderedKey = ""
        private var selectedEventID: UUID?
        private var annotationsByID: [UUID: DriveReplayAnnotation] = [:]
        var reduceMotion = false

        init(onSelectMoment: @escaping (DriveReplayMoment) -> Void) {
            self.onSelectMoment = onSelectMoment
        }

        func update(
            map: MKMapView,
            route: [DriveRoutePoint],
            moments: [DriveReplayMoment],
            selectedEventID: UUID?
        ) {
            let key = route.map(\.timestamp).description + moments.map(\.id).description
            if key != renderedKey {
                renderedKey = key
                map.removeOverlays(map.overlays)
                map.removeAnnotations(map.annotations)
                annotationsByID = [:]

                let polylines = continuousPolylines(from: route)
                guard !polylines.isEmpty else { return }
                polylines.forEach { map.addOverlay($0) }
                for moment in moments {
                    guard let coordinate = moment.coordinate?.clLocationCoordinate else { continue }
                    let annotation = DriveReplayAnnotation(moment: moment)
                    annotation.coordinate = coordinate
                    annotationsByID[moment.id] = annotation
                    map.addAnnotation(annotation)
                }
                let rect = polylines.reduce(MKMapRect.null) { partial, polyline in
                    partial.isNull ? polyline.boundingMapRect : partial.union(polyline.boundingMapRect)
                }
                map.setVisibleMapRect(
                    rect,
                    edgePadding: UIEdgeInsets(top: 36, left: 28, bottom: 36, right: 28),
                    animated: false
                )
            }

            guard selectedEventID != self.selectedEventID else { return }
            self.selectedEventID = selectedEventID
            updateSelection(in: map)
        }

        /// Repaints existing markers for the active theme. `updateSelection`
        /// only runs when the selection itself changes.
        func repaintMarkers(in map: MKMapView) {
            for annotation in map.annotations {
                guard let annotation = annotation as? DriveReplayAnnotation,
                      let marker = map.view(for: annotation) as? MKMarkerAnnotationView else { continue }
                marker.markerTintColor = annotation.moment.id == selectedEventID
                    ? AppDesign.UIKitColor.accent
                    : AppDesign.UIKitColor.safety
            }
        }

        /// Never draw a synthetic line across a gap in accepted GPS data. The
        /// same trace segmentation also powers replay interpolation.
        private func continuousPolylines(from route: [DriveRoutePoint]) -> [MKPolyline] {
            let segments = DriveExperienceEngine.validTraceSegments(for: route)
            guard !segments.isEmpty else { return [] }

            var groups: [[CLLocationCoordinate2D]] = []
            var lastEndIndex: Int?
            for segment in segments {
                if lastEndIndex == segment.startIndex, !groups.isEmpty {
                    groups[groups.count - 1].append(segment.end.coordinate.clLocationCoordinate)
                } else {
                    groups.append([
                        segment.start.coordinate.clLocationCoordinate,
                        segment.end.coordinate.clLocationCoordinate,
                    ])
                }
                lastEndIndex = segment.endIndex
            }

            return groups.compactMap { coordinates in
                guard coordinates.count >= 2 else { return nil }
                return MKPolyline(coordinates: coordinates, count: coordinates.count)
            }
        }

        private func updateSelection(in map: MKMapView) {
            for annotation in map.annotations {
                guard let annotation = annotation as? DriveReplayAnnotation,
                      let marker = map.view(for: annotation) as? MKMarkerAnnotationView else { continue }
                marker.markerTintColor = annotation.moment.id == selectedEventID
                    ? AppDesign.UIKitColor.accent
                    : AppDesign.UIKitColor.safety
                marker.displayPriority = annotation.moment.id == selectedEventID
                    ? .required
                    : .defaultHigh
            }

            guard let selectedEventID,
                  let annotation = annotationsByID[selectedEventID] else { return }
            map.selectAnnotation(annotation, animated: !reduceMotion)
            CATransaction.begin()
            if reduceMotion {
                CATransaction.setDisableActions(true)
            } else {
                CATransaction.setAnimationDuration(AppAnimation.mapDuration)
                CATransaction.setAnimationTimingFunction(
                    CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1)
                )
            }
            map.setCenter(annotation.coordinate, animated: !reduceMotion)
            CATransaction.commit()
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = AppDesign.UIKitColor.accent
            renderer.lineWidth = 5
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? DriveReplayAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "drive-event") as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "drive-event")
            view.annotation = annotation
            view.canShowCallout = true
            view.markerTintColor = annotation.moment.id == selectedEventID ? AppDesign.UIKitColor.accent : AppDesign.UIKitColor.safety
            view.displayPriority = annotation.moment.id == selectedEventID ? .required : .defaultHigh
            view.glyphImage = UIImage(systemName: annotation.moment.kind.symbol)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? DriveReplayAnnotation else { return }
            onSelectMoment(annotation.moment)
        }
    }
}

private final class DriveReplayAnnotation: MKPointAnnotation {
    let moment: DriveReplayMoment

    init(moment: DriveReplayMoment) {
        self.moment = moment
        super.init()
        title = moment.kind.title
        subtitle = "Tap to review this moment"
    }
}

/// A lightweight, visual-only Apple Maps preview used while planning a route.
/// It never calls Roam's backend or creates a route-difficulty score. When
/// both endpoints are available, MapKit draws its own automobile route so the
/// user can sanity-check the route before opting into analysis.
struct RoutePlanningMapSummary: Equatable {
    let distanceMeters: CLLocationDistance
    let expectedTravelTime: TimeInterval

    var displayText: String {
        "\(distanceText) · \(durationText)"
    }

    var accessibilityLabel: String {
        "Apple Maps preview, \(distanceText), estimated \(durationText)"
    }

    private var distanceText: String {
        let miles = distanceMeters / 1_609.344
        if miles < 0.1 {
            return "less than 0.1 mi"
        }
        return String(format: "%.1f mi", miles)
    }

    private var durationText: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = expectedTravelTime >= 3_600 ? [.hour, .minute] : [.minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: expectedTravelTime) ?? "0 min"
    }
}

struct RoutePlanningMapPreview: UIViewRepresentable {
    @ObservedObject private var theme = ThemeManager.shared
    let origin: String
    let destination: String
    let usesCurrentLocation: Bool
    let showsCurrentLocation: Bool
    @Binding var summary: RoutePlanningMapSummary?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var interfaceStyle: UIUserInterfaceStyle {
        colorScheme == .dark ? .dark : .light
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.mapType = .standard
        map.overrideUserInterfaceStyle = interfaceStyle
        map.showsUserLocation = false
        map.showsCompass = false
        map.showsScale = false
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.pointOfInterestFilter = .excludingAll
        map.setRegion(Coordinator.fallbackRegion, animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        map.overrideUserInterfaceStyle = interfaceStyle
        context.coordinator.reduceMotion = reduceMotion
        map.repaintThemedOverlays(stroke: AppDesign.UIKitColor.accent)
        context.coordinator.repaintMarkers(in: map)
        let summaryBinding = $summary
        context.coordinator.onSummaryChange = { value in
            DispatchQueue.main.async {
                guard summaryBinding.wrappedValue != value else { return }
                summaryBinding.wrappedValue = value
            }
        }
        context.coordinator.update(
            map: map,
            origin: origin,
            destination: destination,
            usesCurrentLocation: usesCurrentLocation,
            showsCurrentLocation: showsCurrentLocation
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        static let fallbackRegion = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
            span: MKCoordinateSpan(latitudeDelta: 33, longitudeDelta: 42)
        )

        var reduceMotion = false
        var onSummaryChange: (RoutePlanningMapSummary?) -> Void = { _ in }

        private var renderedRequest: RouteRequest?
        private var routeTask: Task<Void, Never>?
        private var hasFocusedUserLocation = false
        private var isShowingRoute = false

        deinit {
            routeTask?.cancel()
        }

        func update(
            map: MKMapView,
            origin: String,
            destination: String,
            usesCurrentLocation: Bool,
            showsCurrentLocation: Bool
        ) {
            if map.showsUserLocation != showsCurrentLocation {
                map.showsUserLocation = showsCurrentLocation
                hasFocusedUserLocation = false
            }
            let request = RouteRequest(
                origin: origin,
                destination: destination,
                usesCurrentLocation: usesCurrentLocation,
                showsCurrentLocation: showsCurrentLocation
            )
            guard request != renderedRequest else { return }
            renderedRequest = request
            routeTask?.cancel()
            isShowingRoute = false
            clearRoute(in: map)
            onSummaryChange(nil)

            switch request.previewStage {
            case .locationPrompt:
                return
            case .startingPoint where request.usesCurrentLocation:
                // MKMapView already renders the user's Apple Maps location dot.
                // Do not fabricate a coordinate until Core Location supplies one.
                return
            case .route where request.usesCurrentLocation && !request.showsCurrentLocation:
                // A shared route can prefer the current location before the
                // person has chosen it. Do not request or reveal it yet.
                return
            case .startingPoint, .route:
                break
            }

            routeTask = Task { @MainActor [weak self, weak map] in
                do {
                    try await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled,
                          let self,
                          let map,
                          self.renderedRequest == request else { return }

                    let sourceItem = request.usesCurrentLocation
                        ? MKMapItem.forCurrentLocation()
                        : try await Self.mapItem(for: request.origin, near: map.region)
                    guard !Task.isCancelled, self.renderedRequest == request else { return }

                    guard request.previewStage == .route else {
                        self.renderStartingPoint(sourceItem, in: map)
                        return
                    }

                    let destinationItem = try await Self.mapItem(for: request.destination, near: map.region)
                    guard !Task.isCancelled, self.renderedRequest == request else { return }

                    let directionsRequest = MKDirections.Request()
                    directionsRequest.source = sourceItem
                    directionsRequest.destination = destinationItem
                    directionsRequest.transportType = .automobile
                    let response = try await MKDirections(request: directionsRequest).calculate()
                    guard !Task.isCancelled,
                          self.renderedRequest == request,
                          let route = response.routes.first else { return }

                    self.render(route, source: sourceItem, destination: destinationItem, in: map)
                } catch is CancellationError {
                    return
                } catch {
                    // A visual preview is optional. The planning form remains
                    // usable if MapKit cannot resolve an address or route.
                    guard let self, self.renderedRequest == request else { return }
                    self.onSummaryChange(nil)
                }
            }
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard mapView.showsUserLocation,
                  !hasFocusedUserLocation,
                  !isShowingRoute,
                  let location = userLocation.location,
                  location.horizontalAccuracy >= 0 else { return }
            hasFocusedUserLocation = true
            mapView.setRegion(
                MKCoordinateRegion(
                    center: location.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)
                ),
                animated: false
            )
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = AppDesign.UIKitColor.accent
            renderer.lineWidth = 5
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? RoutePlanningAnnotation else { return nil }
            let identifier = "route-planning-\(annotation.kind.rawValue)"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.canShowCallout = false
            view.markerTintColor = annotation.kind == .origin ? AppDesign.UIKitColor.accent : AppDesign.UIKitColor.cardSurface
            view.glyphImage = UIImage(systemName: annotation.kind == .origin ? "circle.inset.filled" : "mappin")
            view.displayPriority = .required
            return view
        }

        /// Repaints existing pins for the active theme without re-running the
        /// directions request that placed them.
        func repaintMarkers(in map: MKMapView) {
            for annotation in map.annotations {
                guard let annotation = annotation as? RoutePlanningAnnotation,
                      let marker = map.view(for: annotation) as? MKMarkerAnnotationView else { continue }
                marker.markerTintColor = annotation.kind == .origin
                    ? AppDesign.UIKitColor.accent
                    : AppDesign.UIKitColor.cardSurface
            }
        }

        private static func mapItem(
            for address: String,
            near region: MKCoordinateRegion
        ) async throws -> MKMapItem {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = address
            request.region = region
            request.resultTypes = .address
            let response = try await MKLocalSearch(request: request).start()
            guard let item = response.mapItems.first else {
                throw RoutePlanningMapError.addressNotFound
            }
            return item
        }

        private func clearRoute(in map: MKMapView) {
            map.removeOverlays(map.overlays)
            let routeAnnotations = map.annotations.filter { !($0 is MKUserLocation) }
            map.removeAnnotations(routeAnnotations)
        }

        private func render(
            _ route: MKRoute,
            source: MKMapItem,
            destination: MKMapItem,
            in map: MKMapView
        ) {
            clearRoute(in: map)
            isShowingRoute = true
            map.addOverlay(route.polyline)
            let annotations = [
                (source.placemark.coordinate, RoutePlanningAnnotation.Kind.origin),
                (destination.placemark.coordinate, RoutePlanningAnnotation.Kind.destination),
            ].compactMap { coordinate, kind -> RoutePlanningAnnotation? in
                guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
                return RoutePlanningAnnotation(coordinate: coordinate, kind: kind)
            }
            map.addAnnotations(annotations)
            onSummaryChange(
                RoutePlanningMapSummary(
                    distanceMeters: route.distance,
                    expectedTravelTime: route.expectedTravelTime
                )
            )

            CATransaction.begin()
            if reduceMotion {
                CATransaction.setDisableActions(true)
            } else {
                CATransaction.setAnimationDuration(AppAnimation.mapDuration)
                CATransaction.setAnimationTimingFunction(
                    CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1)
                )
            }
            map.setVisibleMapRect(
                route.polyline.boundingMapRect,
                edgePadding: UIEdgeInsets(top: 36, left: 28, bottom: 44, right: 28),
                animated: !reduceMotion
            )
            CATransaction.commit()
        }

        private func renderStartingPoint(_ item: MKMapItem, in map: MKMapView) {
            clearRoute(in: map)
            isShowingRoute = false

            let coordinate = item.placemark.coordinate
            guard CLLocationCoordinate2DIsValid(coordinate) else { return }
            map.addAnnotation(RoutePlanningAnnotation(coordinate: coordinate, kind: .origin))

            CATransaction.begin()
            if reduceMotion {
                CATransaction.setDisableActions(true)
            } else {
                CATransaction.setAnimationDuration(AppAnimation.mapDuration)
                CATransaction.setAnimationTimingFunction(
                    CAMediaTimingFunction(controlPoints: 0.42, 0, 0.58, 1)
                )
            }
            map.setRegion(
                MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)
                ),
                animated: !reduceMotion
            )
            CATransaction.commit()
        }
    }

    private struct RouteRequest: Equatable {
        let origin: String
        let destination: String
        let usesCurrentLocation: Bool
        let showsCurrentLocation: Bool

        var previewStage: RoutePlanningMapPreviewStage {
            RoutePlanningMapPreviewStage(
                origin: origin,
                destination: destination,
                usesCurrentLocation: usesCurrentLocation
            )
        }
    }

    private enum RoutePlanningMapError: Error {
        case addressNotFound
    }
}

private final class RoutePlanningAnnotation: MKPointAnnotation {
    enum Kind: String {
        case origin
        case destination
    }

    let kind: Kind

    init(coordinate: CLLocationCoordinate2D, kind: Kind) {
        self.kind = kind
        super.init()
        self.coordinate = coordinate
    }
}
