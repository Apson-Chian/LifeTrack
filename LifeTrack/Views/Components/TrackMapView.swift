import SwiftUI
import MapKit

struct TrackMapView: UIViewRepresentable {
    var points: [TrackMapPoint]
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
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
        let recognizer = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.longPressed(_:)))
        map.addGestureRecognizer(recognizer)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        configureMapAppearance(map)
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })
        context.coordinator.overlayStyles.removeAll()

        let coordinates = points.map(\.coordinate)
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

    private func configureMapAppearance(_ map: MKMapView) {
        switch style {
        case .standard:
            map.overrideUserInterfaceStyle = .unspecified
            map.tintColor = .systemBlue
        case .vivid:
            map.overrideUserInterfaceStyle = .dark
            map.tintColor = UIColor(red: 0.45, green: 0.78, blue: 1.0, alpha: 1)
        }
    }

    private func addTrackOverlays(to map: MKMapView, coordinates: [CLLocationCoordinate2D], coordinator: Coordinator) {
        guard coordinates.count > 1 else { return }
        switch style {
        case .standard:
            addPolyline(coordinates, color: .systemBlue, lineWidth: 5, to: map, coordinator: coordinator)
        case .vivid:
            map.addOverlay(TrackDarkOverlay(coordinates: coordinates), level: .aboveRoads)
            for index in 1..<coordinates.count {
                guard coordinates[index - 1].distance(to: coordinates[index]) < 1_800 else { continue }
                let segment = [coordinates[index - 1], coordinates[index]]
                addPolyline(segment, color: UIColor(red: 0.37, green: 0.52, blue: 1.0, alpha: 0.24), lineWidth: 10, to: map, coordinator: coordinator)
                let color = UIColor(points[index].activityType.trackColor).withAlphaComponent(0.58)
                addPolyline(segment, color: color, lineWidth: 2.5, to: map, coordinator: coordinator)
            }
            map.addOverlay(TrackGlowOverlay(points: points), level: .aboveRoads)
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
        switch cameraRequest.target {
        case .currentLocation:
            guard let coordinate = currentLocation?.coordinate else { return }
            coordinator.lastCameraRequestID = cameraRequest.id
            map.setRegion(MKCoordinateRegion(center: coordinate, latitudinalMeters: 700, longitudinalMeters: 700), animated: true)
        case .route:
            coordinator.lastCameraRequestID = cameraRequest.id
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
            if let glow = overlay as? TrackGlowOverlay {
                return TrackGlowRenderer(overlay: glow)
            }
            if let dark = overlay as? TrackDarkOverlay {
                return TrackDarkRenderer(overlay: dark)
            }
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

struct TrackMapPoint {
    let coordinate: CLLocationCoordinate2D
    let timestamp: Date
    let activityType: ActivityType

    init(coordinate: CLLocationCoordinate2D, timestamp: Date = .now, activityType: ActivityType = .unknown) {
        self.coordinate = coordinate
        self.timestamp = timestamp
        self.activityType = activityType
    }

    init(_ point: TrackPoint) {
        self.coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        self.timestamp = point.timestamp
        self.activityType = point.activityType
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

private final class TrackDarkOverlay: NSObject, MKOverlay {
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect

    init(coordinates: [CLLocationCoordinate2D]) {
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        self.boundingMapRect = polyline.boundingMapRect.insetBy(dx: -polyline.boundingMapRect.width, dy: -polyline.boundingMapRect.height)
        self.coordinate = MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
    }
}

private final class TrackDarkRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let rect = self.rect(for: mapRect)
        context.setFillColor(UIColor(red: 0.0, green: 0.02, blue: 0.07, alpha: 0.58).cgColor)
        context.fill(rect)
    }
}

private final class TrackGlowOverlay: NSObject, MKOverlay {
    let points: [TrackMapPoint]
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect

    init(points: [TrackMapPoint]) {
        self.points = Self.densified(points)
        let coordinates = self.points.map(\.coordinate)
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        self.boundingMapRect = polyline.boundingMapRect
        self.coordinate = MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
    }

    private static func densified(_ points: [TrackMapPoint]) -> [TrackMapPoint] {
        guard points.count > 1 else { return points }
        var result: [TrackMapPoint] = []
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            result.append(previous)
            let start = CLLocation(latitude: previous.coordinate.latitude, longitude: previous.coordinate.longitude)
            let end = CLLocation(latitude: current.coordinate.latitude, longitude: current.coordinate.longitude)
            let distance = start.distance(from: end)
            guard distance < 1_800 else { continue }
            let steps = min(max(Int(distance / 42), 0), 80)
            guard steps > 0 else { continue }
            for step in 1...steps {
                let progress = Double(step) / Double(steps + 1)
                let latitude = previous.coordinate.latitude + (current.coordinate.latitude - previous.coordinate.latitude) * progress
                let longitude = previous.coordinate.longitude + (current.coordinate.longitude - previous.coordinate.longitude) * progress
                result.append(TrackMapPoint(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                                            timestamp: current.timestamp,
                                            activityType: current.activityType))
            }
        }
        if let last = points.last {
            result.append(last)
        }
        return result
    }
}

private final class TrackGlowRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? TrackGlowOverlay else { return }
        let visible = mapRect
        let baseRadius = max(1.4, min(3.4, 3.2 / sqrt(zoomScale)))

        context.saveGState()
        context.setBlendMode(.plusLighter)

        for (index, point) in overlay.points.enumerated() {
            let mapPoint = MKMapPoint(point.coordinate)
            guard visible.contains(mapPoint) else { continue }
            let screenPoint = self.point(for: mapPoint)
            let pulse = CGFloat((index % 7)) * 0.18
            let radius = baseRadius + pulse
            let color = UIColor(point.activityType.trackColor)
            drawGlowDot(at: screenPoint, radius: radius, color: color, in: context)
        }

        context.restoreGState()
    }

    private func drawGlowDot(at point: CGPoint, radius: CGFloat, color: UIColor, in context: CGContext) {
        let outerRect = CGRect(x: point.x - radius * 3.1,
                               y: point.y - radius * 3.1,
                               width: radius * 6.2,
                               height: radius * 6.2)
        context.setFillColor(color.withAlphaComponent(0.18).cgColor)
        context.fillEllipse(in: outerRect)

        let middleRect = CGRect(x: point.x - radius * 1.7,
                                y: point.y - radius * 1.7,
                                width: radius * 3.4,
                                height: radius * 3.4)
        context.setFillColor(color.withAlphaComponent(0.42).cgColor)
        context.fillEllipse(in: middleRect)

        let coreRect = CGRect(x: point.x - radius * 0.55,
                              y: point.y - radius * 0.55,
                              width: radius * 1.1,
                              height: radius * 1.1)
        context.setFillColor(UIColor(red: 0.82, green: 0.9, blue: 1.0, alpha: 0.94).cgColor)
        context.fillEllipse(in: coreRect)
    }
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

private extension CLLocationCoordinate2D {
    func distance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude).distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }
}
