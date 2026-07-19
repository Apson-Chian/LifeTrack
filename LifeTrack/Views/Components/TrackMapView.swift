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

        let displaySegments = displaySegments(for: points, coordinator: context.coordinator, map: map)
        let displayCoordinates = displaySegments.flatMap(\.coordinates)
        addTrackOverlays(to: map, segments: displaySegments, coordinator: context.coordinator)
        addEndpointAnnotations(to: map, coordinates: displayCoordinates)
        for place in places where place.isAlwaysVisible {
            let annotation = MKPointAnnotation()
            annotation.coordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
            annotation.title = place.shortName
            annotation.subtitle = place.category.displayName
            map.addAnnotation(annotation)
            map.addOverlay(MKCircle(center: annotation.coordinate, radius: place.radius))
        }
        if !context.coordinator.hasSetInitialRegion,
           let coordinate = displayCoordinates.last ?? currentLocation?.coordinate {
            map.setRegion(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1_000, longitudinalMeters: 1_000), animated: false)
            context.coordinator.hasSetInitialRegion = true
        }
        applyCameraRequestIfNeeded(to: map, coordinates: displayCoordinates, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func configureMapAppearance(_ map: MKMapView) {
        switch style {
        case .standard:
            map.overrideUserInterfaceStyle = .unspecified
            map.tintColor = .systemBlue
        case .vivid, .photoDots:
            map.overrideUserInterfaceStyle = .dark
            map.tintColor = UIColor(red: 0.45, green: 0.78, blue: 1.0, alpha: 1)
        }
    }

    fileprivate func updateTrackOnly(on map: MKMapView, coordinator: Coordinator) {
        let segments = displaySegments(for: points, coordinator: coordinator, map: map)
        addTrackOverlays(to: map, segments: segments, coordinator: coordinator)
    }

    private func displaySegments(for points: [TrackMapPoint], coordinator: Coordinator, map: MKMapView) -> [TrackDisplaySegment] {
        let rawSegments = TrackDisplaySegment.build(from: points)
        guard style == .vivid else { return rawSegments }
        for segment in rawSegments where segment.shouldSnapToRoad {
            coordinator.requestRoadMatch(for: segment, on: map)
        }
        return rawSegments.map { segment in
            guard let snapped = coordinator.roadMatchedCoordinates[segment.routeKey], snapped.count > 1 else { return segment }
            return TrackDisplaySegment(id: segment.id,
                                       activityType: segment.activityType,
                                       source: segment.source,
                                       coordinates: snapped,
                                       startTimestamp: segment.startTimestamp,
                                       endTimestamp: segment.endTimestamp,
                                       distance: segment.distance,
                                       averageSpeed: segment.averageSpeed)
        }
    }

    private func addTrackOverlays(to map: MKMapView, segments: [TrackDisplaySegment], coordinator: Coordinator) {
        let coordinates = segments.flatMap(\.coordinates)
        guard !segments.isEmpty, coordinates.count > 1 else { return }
        switch style {
        case .standard:
            for segment in segments where segment.coordinates.count > 1 {
                addPolyline(segment.coordinates, color: UIColor(segment.activityType.trackColor), lineWidth: 5, to: map, coordinator: coordinator)
            }
        case .vivid:
            map.addOverlay(TrackDarkOverlay(coordinates: coordinates), level: .aboveRoads)
            for segment in segments where segment.coordinates.count > 1 {
                let color = UIColor(segment.activityType.trackColor)
                addPolyline(segment.coordinates, color: color.withAlphaComponent(0.24), lineWidth: 12, to: map, coordinator: coordinator)
                addPolyline(segment.coordinates, color: color.withAlphaComponent(0.82), lineWidth: 3, to: map, coordinator: coordinator)
            }
            map.addOverlay(TrackGlowOverlay(segments: segments), level: .aboveRoads)
        case .photoDots:
            map.addOverlay(TrackDarkOverlay(coordinates: coordinates, opacity: 0.24), level: .aboveRoads)
            map.addOverlay(TrackGlowOverlay(segments: segments, interpolatesBetweenPoints: false, presentation: .photoDots), level: .aboveRoads)
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
        fileprivate var roadMatchedCoordinates: [String: [CLLocationCoordinate2D]] = [:]
        private var pendingRoadRequests: Set<String> = []
        private let maximumRoadMatchedSegments = 24
        private let maximumConcurrentRoadRequests = 4

        init(_ parent: TrackMapView) { self.parent = parent }

        fileprivate func requestRoadMatch(for segment: TrackDisplaySegment, on map: MKMapView) {
            guard let start = segment.coordinates.first,
                  let end = segment.coordinates.last,
                  roadMatchedCoordinates[segment.routeKey] == nil,
                  !pendingRoadRequests.contains(segment.routeKey),
                  roadMatchedCoordinates.count < maximumRoadMatchedSegments,
                  pendingRoadRequests.count < maximumConcurrentRoadRequests else { return }

            pendingRoadRequests.insert(segment.routeKey)
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
            request.transportType = segment.activityType.mapKitTransportType

            MKDirections(request: request).calculate { [weak self, weak map] response, _ in
                guard let self else { return }
                let coordinates = response?.routes.first?.polyline.coordinates
                DispatchQueue.main.async {
                    self.pendingRoadRequests.remove(segment.routeKey)
                    guard let coordinates, coordinates.count > 1 else { return }
                    self.roadMatchedCoordinates[segment.routeKey] = coordinates
                    if let map {
                        map.removeOverlays(map.overlays.filter { $0 is MKPolyline || $0 is TrackGlowOverlay || $0 is TrackDarkOverlay })
                        self.overlayStyles.removeAll()
                        self.parent.updateTrackOnly(on: map, coordinator: self)
                    }
                }
            }
        }

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
    let segmentID: Int
    let horizontalAccuracy: Double
    let speed: Double?
    let source: TrackMapPointSource

    init(coordinate: CLLocationCoordinate2D, timestamp: Date = .now, activityType: ActivityType = .unknown, segmentID: Int = 0, horizontalAccuracy: Double = 12, speed: Double? = nil, source: TrackMapPointSource = .sample) {
        self.coordinate = coordinate
        self.timestamp = timestamp
        self.activityType = activityType
        self.segmentID = segmentID
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.source = source
    }

    init(_ point: TrackPoint) {
        self.coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        self.timestamp = point.timestamp
        self.activityType = point.activityType
        self.segmentID = 0
        self.horizontalAccuracy = point.horizontalAccuracy
        self.speed = point.speed >= 0 ? point.speed : nil
        self.source = .recorded
    }
}

enum TrackMapPointSource {
    case recorded
    case sample
    case photo
}

private extension TrackMapPoint {
    var isReliable: Bool {
        switch source {
        case .sample, .photo:
            return true
        case .recorded:
            return horizontalAccuracy >= 0 && horizontalAccuracy <= 100
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
    case photoDots
}

private struct TrackOverlayStyle {
    let color: UIColor
    let lineWidth: CGFloat
}

private struct TrackDisplaySegment: Identifiable {
    let id: Int
    let activityType: ActivityType
    let source: TrackMapPointSource
    let coordinates: [CLLocationCoordinate2D]
    let startTimestamp: Date
    let endTimestamp: Date
    let distance: CLLocationDistance
    let averageSpeed: Double

    var shouldSnapToRoad: Bool {
        source == .recorded
            && coordinates.count == 2
            && distance >= 80
            && distance <= 1_600
            && endTimestamp.timeIntervalSince(startTimestamp) >= 6
    }

    var routeKey: String {
        guard let first = coordinates.first, let last = coordinates.last else { return "\(id)" }
        return "\(id)-\(activityType.rawValue)-\(first.latitude.roundedKey),\(first.longitude.roundedKey)-\(last.latitude.roundedKey),\(last.longitude.roundedKey)"
    }

    static func build(from points: [TrackMapPoint]) -> [TrackDisplaySegment] {
        guard points.count > 1 else { return [] }
        var segments: [TrackDisplaySegment] = []
        var nextID = 0

        var previousPoint: TrackMapPoint?
        for current in points {
            guard current.isReliable else {
                previousPoint = nil
                continue
            }
            guard let previous = previousPoint else {
                previousPoint = current
                continue
            }
            guard previous.segmentID == current.segmentID else {
                previousPoint = current
                continue
            }

            let distance = previous.coordinate.distance(to: current.coordinate)
            let interval = current.timestamp.timeIntervalSince(previous.timestamp)
            guard interval >= 0 else {
                previousPoint = current
                continue
            }

            if distance < Self.minimumDistance(for: current.activityType),
               interval < Self.minimumInterval(for: current.activityType) {
                continue
            }

            let effectiveInterval = max(interval, 1)
            let averageSpeed = distance / effectiveInterval
            if current.source == .photo {
                segments.append(TrackDisplaySegment(id: nextID,
                                                    activityType: current.activityType,
                                                    source: current.source,
                                                    coordinates: [previous.coordinate, current.coordinate],
                                                    startTimestamp: previous.timestamp,
                                                    endTimestamp: current.timestamp,
                                                    distance: distance,
                                                    averageSpeed: averageSpeed))
                nextID += 1
                previousPoint = current
                continue
            }

            guard distance <= Self.maximumDistance(for: current.activityType),
                  averageSpeed <= Self.maximumSpeed(for: current.activityType) else {
                previousPoint = current
                continue
            }

            segments.append(TrackDisplaySegment(id: nextID,
                                                activityType: current.activityType,
                                                source: current.source,
                                                coordinates: [previous.coordinate, current.coordinate],
                                                startTimestamp: previous.timestamp,
                                                endTimestamp: current.timestamp,
                                                distance: distance,
                                                averageSpeed: averageSpeed))
            nextID += 1
            previousPoint = current
        }

        return segments
    }

    private static func minimumDistance(for activity: ActivityType) -> CLLocationDistance {
        switch activity {
        case .stationary: 25
        case .walking: 6
        case .running: 8
        case .cycling: 12
        case .automotive: 20
        case .unknown: 8
        }
    }

    private static func minimumInterval(for activity: ActivityType) -> TimeInterval {
        switch activity {
        case .stationary: 30
        case .walking: 4
        case .running: 2
        case .cycling: 4
        case .automotive: 6
        case .unknown: 4
        }
    }

    private static func maximumDistance(for activity: ActivityType) -> CLLocationDistance {
        switch activity {
        case .walking, .running: 450
        case .cycling: 900
        case .automotive: 1_800
        case .stationary: 120
        case .unknown: 900
        }
    }

    private static func maximumSpeed(for activity: ActivityType) -> Double {
        switch activity {
        case .walking: 3.2
        case .running: 6.5
        case .cycling: 14
        case .automotive: 55
        case .stationary: 1.2
        case .unknown: 25
        }
    }
}

private final class TrackDarkOverlay: NSObject, MKOverlay {
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect
    let opacity: CGFloat

    init(coordinates: [CLLocationCoordinate2D], opacity: CGFloat = 0.58) {
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        self.boundingMapRect = polyline.boundingMapRect.insetBy(dx: -polyline.boundingMapRect.width, dy: -polyline.boundingMapRect.height)
        self.coordinate = MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
        self.opacity = opacity
    }
}

private final class TrackDarkRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? TrackDarkOverlay else { return }
        let rect = self.rect(for: mapRect)
        context.setFillColor(UIColor(red: 0.0, green: 0.02, blue: 0.07, alpha: overlay.opacity).cgColor)
        context.fill(rect)
    }
}

private final class TrackGlowOverlay: NSObject, MKOverlay {
    enum Presentation {
        case track
        case photoDots
    }

    let points: [TrackMapPoint]
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect
    let presentation: Presentation

    init(segments: [TrackDisplaySegment], interpolatesBetweenPoints: Bool = true, presentation: Presentation = .track) {
        self.points = Self.densified(segments, interpolatesBetweenPoints: interpolatesBetweenPoints)
        let coordinates = self.points.map(\.coordinate)
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        self.boundingMapRect = polyline.boundingMapRect
        self.coordinate = MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
        self.presentation = presentation
    }

    private static func densified(_ segments: [TrackDisplaySegment], interpolatesBetweenPoints: Bool) -> [TrackMapPoint] {
        var result: [TrackMapPoint] = []
        for segment in segments {
            guard segment.coordinates.count > 1 else { continue }
            for index in 1..<segment.coordinates.count {
                let previous = segment.coordinates[index - 1]
                let current = segment.coordinates[index]
                result.append(TrackMapPoint(coordinate: previous,
                                            activityType: segment.activityType,
                                            segmentID: segment.id,
                                            source: segment.source))
                guard interpolatesBetweenPoints else {
                    if index == segment.coordinates.count - 1 {
                        result.append(TrackMapPoint(coordinate: current,
                                                    activityType: segment.activityType,
                                                    segmentID: segment.id,
                                                    source: segment.source))
                    }
                    continue
                }
                let distance = previous.distance(to: current)
                let steps = min(max(Int(distance / 36), 0), 80)
                guard steps > 0 else { continue }
                for step in 1...steps {
                    let progress = Double(step) / Double(steps + 1)
                    let latitude = previous.latitude + (current.latitude - previous.latitude) * progress
                    let longitude = previous.longitude + (current.longitude - previous.longitude) * progress
                    result.append(TrackMapPoint(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                                                activityType: segment.activityType,
                                                segmentID: segment.id,
                                                source: segment.source))
                }
            }
        }
        return result
    }
}

private final class TrackGlowRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? TrackGlowOverlay else { return }
        let visible = mapRect
        let style = glowStyle(for: overlay.presentation, zoomScale: zoomScale)

        context.saveGState()
        context.setBlendMode(.plusLighter)

        if overlay.presentation == .photoDots {
            drawPhotoDots(overlay.points, visible: visible, zoomScale: zoomScale, in: context)
            context.restoreGState()
            return
        }

        for (index, point) in overlay.points.enumerated() {
            let mapPoint = MKMapPoint(point.coordinate)
            guard visible.contains(mapPoint) else { continue }
            let screenPoint = self.point(for: mapPoint)
            let pulse = CGFloat((index % 5)) * style.pulse
            let radius = style.radius + pulse
            let color = overlay.presentation == .photoDots ? style.color : UIColor(point.activityType.trackColor)
            drawGlowDot(at: screenPoint,
                        radius: radius,
                        color: color,
                        alphaScale: style.alphaScale,
                        outerScale: style.outerScale,
                        middleScale: style.middleScale,
                        coreScale: style.coreScale,
                        in: context)
        }

        context.restoreGState()
    }

    private func drawPhotoDots(_ points: [TrackMapPoint], visible: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let scale = max(CGFloat(zoomScale), 0.0001)
        let zoomOut = max(0, min(1, (1 / sqrt(scale) - 0.62) / 1.8))
        let shouldCluster = zoomOut > 0.16

        if shouldCluster {
            let cellSize = 18 + zoomOut * 18
            var buckets: [PhotoDotBucket: PhotoDotCluster] = [:]

            for point in points {
                let mapPoint = MKMapPoint(point.coordinate)
                guard visible.contains(mapPoint) else { continue }
                let screenPoint = self.point(for: mapPoint)
                let key = PhotoDotBucket(x: Int(screenPoint.x / cellSize), y: Int(screenPoint.y / cellSize))
                buckets[key, default: PhotoDotCluster()].add(screenPoint)
            }

            for cluster in buckets.values {
                let strength = min(CGFloat(cluster.count), 18)
                let radius = 1.25 + zoomOut * 1.15 + log2(strength + 1) * 0.36
                let alpha = 1.0 + min(0.44, log2(strength + 1) * 0.08)
                drawGlowDot(at: cluster.center,
                            radius: radius,
                            color: UIColor(red: 0.39, green: 0.96, blue: 0.80, alpha: 1),
                            alphaScale: alpha,
                            outerScale: 4.8 + zoomOut * 2.6,
                            middleScale: 1.55 + zoomOut * 0.62,
                            coreScale: 0.36,
                            in: context)
            }
            return
        }

        let style = glowStyle(for: .photoDots, zoomScale: zoomScale)
        for (index, point) in points.enumerated() {
            let mapPoint = MKMapPoint(point.coordinate)
            guard visible.contains(mapPoint) else { continue }
            let screenPoint = self.point(for: mapPoint)
            let pulse = CGFloat((index % 5)) * style.pulse
            drawGlowDot(at: screenPoint,
                        radius: style.radius + pulse,
                        color: style.color,
                        alphaScale: style.alphaScale,
                        outerScale: style.outerScale,
                        middleScale: style.middleScale,
                        coreScale: style.coreScale,
                        in: context)
        }
    }

    private func glowStyle(for presentation: TrackGlowOverlay.Presentation, zoomScale: MKZoomScale) -> (radius: CGFloat, pulse: CGFloat, alphaScale: CGFloat, outerScale: CGFloat, middleScale: CGFloat, coreScale: CGFloat, color: UIColor) {
        switch presentation {
        case .track:
            return (max(1.4, min(3.4, 3.2 / sqrt(zoomScale))), 0.18, 1, 3.6, 1.7, 0.55, .systemBlue)
        case .photoDots:
            let scale = max(CGFloat(zoomScale), 0.0001)
            let zoomOutBoost = max(0, min(1, (1 / sqrt(scale) - 0.65) / 1.65))
            let radius = 1.05 + zoomOutBoost * 1.05
            let outerScale = 3.8 + zoomOutBoost * 2.4
            let middleScale = 1.45 + zoomOutBoost * 0.55
            let alpha = 1.0 + zoomOutBoost * 0.24
            return (radius, 0.08, alpha, outerScale, middleScale, 0.42, UIColor(red: 0.39, green: 0.96, blue: 0.80, alpha: 1))
        }
    }

    private func drawGlowDot(at point: CGPoint, radius: CGFloat, color: UIColor, alphaScale: CGFloat, outerScale: CGFloat, middleScale: CGFloat, coreScale: CGFloat, in context: CGContext) {
        let outerRect = CGRect(x: point.x - radius * outerScale,
                               y: point.y - radius * outerScale,
                               width: radius * outerScale * 2,
                               height: radius * outerScale * 2)
        context.setFillColor(color.withAlphaComponent(min(0.20, 0.10 * alphaScale)).cgColor)
        context.fillEllipse(in: outerRect)

        let middleRect = CGRect(x: point.x - radius * middleScale,
                                y: point.y - radius * middleScale,
                                width: radius * middleScale * 2,
                                height: radius * middleScale * 2)
        context.setFillColor(color.withAlphaComponent(min(0.46, 0.28 * alphaScale)).cgColor)
        context.fillEllipse(in: middleRect)

        let coreRect = CGRect(x: point.x - radius * coreScale,
                              y: point.y - radius * coreScale,
                              width: radius * coreScale * 2,
                              height: radius * coreScale * 2)
        context.setFillColor(color.withAlphaComponent(min(1.0, 0.95 * alphaScale)).cgColor)
        context.fillEllipse(in: coreRect)
    }
}

private struct PhotoDotBucket: Hashable {
    let x: Int
    let y: Int
}

private struct PhotoDotCluster {
    private(set) var count = 0
    private var sumX: CGFloat = 0
    private var sumY: CGFloat = 0

    var center: CGPoint {
        guard count > 0 else { return .zero }
        return CGPoint(x: sumX / CGFloat(count), y: sumY / CGFloat(count))
    }

    mutating func add(_ point: CGPoint) {
        count += 1
        sumX += point.x
        sumY += point.y
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

extension ActivityType {
    var trackColor: Color {
        switch self {
        case .walking: Color(red: 0.35, green: 1.0, blue: 0.72)
        case .running: Color(red: 1.0, green: 0.72, blue: 0.28)
        case .cycling: Color(red: 0.38, green: 0.78, blue: 1.0)
        case .automotive: Color(red: 0.78, green: 0.58, blue: 1.0)
        case .stationary: .gray
        case .unknown: Color(red: 0.68, green: 0.82, blue: 1.0)
        }
    }

    var mapKitTransportType: MKDirectionsTransportType {
        switch self {
        case .walking, .running, .stationary:
            return .walking
        case .cycling, .automotive, .unknown:
            return .automobile
        }
    }
}

private extension CLLocationCoordinate2D {
    func distance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude).distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }
}

private extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coordinates = Array(repeating: CLLocationCoordinate2D(), count: pointCount)
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
}

private extension Double {
    var roundedKey: String {
        String(format: "%.5f", self)
    }
}
