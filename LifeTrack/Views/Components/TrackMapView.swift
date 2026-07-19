import SwiftUI
import MapKit

struct TrackMapView: UIViewRepresentable {
    var points: [TrackPoint]
    var places: [CustomPlace]
    var currentLocation: CLLocation?
    var cameraRequest: MapCameraRequest?
    var style: TrackMapStyle = .standard
    var onLongPress: (CLLocationCoordinate2D) -> Void

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.pointOfInterestFilter = .includingAll
        map.showsCompass = true
        map.showsScale = true
        let recognizer = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPressed(_:)))
        map.addGestureRecognizer(recognizer)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })
        context.coordinator.overlayStyles.removeAll()

        let coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        addTrackOverlays(to: map, coordinates: coordinates, coordinator: context.coordinator)
        addEndpointAnnotations(to: map, coordinates: coordinates)
        for place in places where place.isAlwaysVisible {
            let annotation = MKPointAnnotation()
            annotation.coordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
            annotation.title = place.shortName
            annotation.subtitle = place.category.displayName
            map.addAnnotation(annotation)
            map.addOverlay(MKCircle(center: annotation.coordinate, radius: place.radius))
        }
        if !context.coordinator.hasSetInitialRegion,
           let coordinate = coordinates.last ?? currentLocation?.coordinate {
            map.setRegion(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1_000, longitudinalMeters: 1_000), animated: false)
            context.coordinator.hasSetInitialRegion = true
        }
        applyCameraRequestIfNeeded(to: map, coordinates: coordinates, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func addTrackOverlays(to map: MKMapView, coordinates: [CLLocationCoordinate2D], coordinator: Coordinator) {
        guard coordinates.count > 1 else { return }
        switch style {
        case .standard:
            addPolyline(coordinates, color: .systemBlue, lineWidth: 5, to: map, coordinator: coordinator)
        case .vivid:
            addPolyline(coordinates, color: UIColor.systemCyan.withAlphaComponent(0.25), lineWidth: 12, to: map, coordinator: coordinator)
            for index in 1..<coordinates.count {
                let segment = [coordinates[index - 1], coordinates[index]]
                let color = UIColor(points[index].activityType.trackColor)
                addPolyline(segment, color: color, lineWidth: 5, to: map, coordinator: coordinator)
            }
        }
    }

    private func addPolyline(_ coordinates: [CLLocationCoordinate2D], color: UIColor, lineWidth: CGFloat, to map: MKMapView, coordinator: Coordinator) {
        let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
        coordinator.overlayStyles[ObjectIdentifier(line)] = TrackOverlayStyle(color: color, lineWidth: lineWidth)
        map.addOverlay(line)
    }

    private func addEndpointAnnotations(to map: MKMapView, coordinates: [CLLocationCoordinate2D]) {
        guard style == .vivid, let first = coordinates.first, let last = coordinates.last else { return }
        let start = TrackEndpointAnnotation(kind: .start, coordinate: first)
        let finish = TrackEndpointAnnotation(kind: .finish, coordinate: last)
        map.addAnnotations([start, finish])
    }

    private func applyCameraRequestIfNeeded(to map: MKMapView, coordinates: [CLLocationCoordinate2D], coordinator: Coordinator) {
        guard let cameraRequest, coordinator.lastCameraRequestID != cameraRequest.id else { return }
        coordinator.lastCameraRequestID = cameraRequest.id
        switch cameraRequest.target {
        case .currentLocation:
            guard let coordinate = currentLocation?.coordinate else { return }
            map.setRegion(MKCoordinateRegion(center: coordinate, latitudinalMeters: 700, longitudinalMeters: 700), animated: true)
        case .route:
            setVisibleRoute(on: map, coordinates: coordinates)
        }
    }

    private func setVisibleRoute(on map: MKMapView, coordinates: [CLLocationCoordinate2D]) {
        guard coordinates.count > 1 else {
            if let coordinate = coordinates.last ?? currentLocation?.coordinate {
                map.setRegion(MKCoordinateRegion(center: coordinate, latitudinalMeters: 700, longitudinalMeters: 700), animated: true)
            }
            return
        }
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        map.setVisibleMapRect(polyline.boundingMapRect,
                              edgePadding: UIEdgeInsets(top: 56, left: 36, bottom: 56, right: 36),
                              animated: true)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: TrackMapView
        var hasSetInitialRegion = false
        var lastCameraRequestID: UUID?
        fileprivate var overlayStyles: [ObjectIdentifier: TrackOverlayStyle] = [:]

        init(_ parent: TrackMapView) { self.parent = parent }

        @objc func longPressed(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began, let map = recognizer.view as? MKMapView else { return }
            parent.onLongPress(map.convert(recognizer.location(in: map), toCoordinateFrom: map))
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? MKPolyline {
                let style = overlayStyles[ObjectIdentifier(line)] ?? TrackOverlayStyle(color: .systemBlue, lineWidth: 5)
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = style.color
                renderer.lineWidth = style.lineWidth
                renderer.lineJoin = .round
                renderer.lineCap = .round
                return renderer
            }
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.strokeColor = .systemTeal
                renderer.fillColor = UIColor.systemTeal.withAlphaComponent(0.12)
                renderer.lineWidth = 1
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let endpoint = annotation as? TrackEndpointAnnotation else { return nil }
            let identifier = "TrackEndpointAnnotation"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.glyphImage = UIImage(systemName: endpoint.kind.symbolName)
            view.markerTintColor = endpoint.kind.tintColor
            view.glyphTintColor = .white
            view.displayPriority = .required
            return view
        }
    }
}

struct MapCameraRequest: Equatable {
    let id = UUID()
    let target: Target

    enum Target: Equatable {
        case currentLocation
        case route
    }
}

enum TrackMapStyle {
    case standard
    case vivid
}

private struct TrackOverlayStyle {
    let color: UIColor
    let lineWidth: CGFloat
}

private final class TrackEndpointAnnotation: NSObject, MKAnnotation {
    enum Kind {
        case start
        case finish

        var title: String {
            switch self {
            case .start: "起点"
            case .finish: "终点"
            }
        }

        var symbolName: String {
            switch self {
            case .start: "play.fill"
            case .finish: "flag.checkered"
            }
        }

        var tintColor: UIColor {
            switch self {
            case .start: .systemGreen
            case .finish: .systemRed
            }
        }
    }

    let kind: Kind
    let coordinate: CLLocationCoordinate2D
    var title: String? { kind.title }

    init(kind: Kind, coordinate: CLLocationCoordinate2D) {
        self.kind = kind
        self.coordinate = coordinate
    }
}

private extension ActivityType {
    var trackColor: Color {
        switch self {
        case .walking: .green
        case .running: .orange
        case .cycling: .cyan
        case .automotive: .purple
        case .stationary: .gray
        case .unknown: .blue
        }
    }
}
