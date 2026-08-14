import SwiftUI
import MapKit

struct TrackMapView: UIViewRepresentable {
    var points: [TrackMapPoint]
    var places: [CustomPlace]
    var currentLocation: CLLocation?
    var cameraRequest: MapCameraRequest?
    var style: TrackMapStyle = .standard
    var colorMode: TrackColorMode = .speed
    var focusedCoordinate: CLLocationCoordinate2D? = nil
    var photoMoments: [TrackPhotoMoment] = []
    var onPhotoTap: (String) -> Void = { _ in }
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
        let displayCoordinates = displayCoordinates(from: points, segments: displaySegments)
        addTrackOverlays(to: map, points: points, segments: displaySegments, coordinator: context.coordinator)
        addEndpointAnnotations(to: map, coordinates: displayCoordinates)
        for moment in photoMoments {
            map.addAnnotation(TrackPhotoAnnotation(moment: moment))
        }
        if let focusedCoordinate {
            let annotation = MKPointAnnotation()
            annotation.coordinate = focusedCoordinate
            annotation.title = "时间轴节点"
            map.addAnnotation(annotation)
        }
        for place in places where place.isAlwaysVisible {
            let annotation = MKPointAnnotation()
            annotation.coordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
            annotation.title = place.shortName
            annotation.subtitle = place.category.displayName
            map.addAnnotation(annotation)
            map.addOverlay(MKCircle(center: annotation.coordinate, radius: place.radius))
        }
        if !context.coordinator.hasSetInitialRegion {
            if !displayCoordinates.isEmpty {
                let fitPolyline = MKPolyline(coordinates: displayCoordinates, count: displayCoordinates.count)
                map.setVisibleMapRect(fitPolyline.boundingMapRect,
                                      edgePadding: UIEdgeInsets(top: 48, left: 36, bottom: 56, right: 36),
                                      animated: false)
            } else if let coordinate = currentLocation?.coordinate {
                map.setRegion(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1_000, longitudinalMeters: 1_000), animated: false)
            }
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
            map.pointOfInterestFilter = .includingAll
            // 使用真实感地形，让轨迹更有层次
            if let standard = map.preferredConfiguration as? MKStandardMapConfiguration {
                standard.elevationStyle = .realistic
            }
        case .vivid:
            map.overrideUserInterfaceStyle = .dark
            map.tintColor = UIColor(red: 0.45, green: 0.78, blue: 1.0, alpha: 1)
            map.pointOfInterestFilter = .includingAll
        case .photoDots:
            map.overrideUserInterfaceStyle = .dark
            map.tintColor = UIColor(red: 0.45, green: 0.78, blue: 1.0, alpha: 1)
            map.pointOfInterestFilter = .excludingAll
            map.showsUserLocation = false
        }
    }

    fileprivate func updateTrackOnly(on map: MKMapView, coordinator: Coordinator) {
        let segments = displaySegments(for: points, coordinator: coordinator, map: map)
        addTrackOverlays(to: map, points: points, segments: segments, coordinator: coordinator)
    }

    private func displaySegments(for points: [TrackMapPoint], coordinator: Coordinator, map: MKMapView) -> [TrackDisplaySegment] {
        let rawSegments = TrackDisplaySegment.build(from: points)
        guard style != .photoDots else { return rawSegments }
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
                                       averageSpeed: segment.averageSpeed,
                                       speeds: Array(repeating: segment.averageSpeed, count: snapped.count))
        }
    }

    private func displayCoordinates(from points: [TrackMapPoint], segments: [TrackDisplaySegment]) -> [CLLocationCoordinate2D] {
        if style == .photoDots {
            return points.filter(\.isReliable).map(\.coordinate)
        }
        let segmentCoordinates = segments.flatMap(\.coordinates)
        return segmentCoordinates.isEmpty ? points.filter(\.isReliable).map(\.coordinate) : segmentCoordinates
    }

    private func addTrackOverlays(to map: MKMapView, points: [TrackMapPoint], segments: [TrackDisplaySegment], coordinator: Coordinator) {
        let coordinates = segments.flatMap(\.coordinates)
        switch style {
        case .standard:
            guard !segments.isEmpty, coordinates.count > 1 else { return }
            if colorMode == .speed {
                // 速度渐变模式：先画一层半透明粗线作为发光底衬，再画渐变细线
                for segment in segments where segment.coordinates.count > 1 {
                    addPolyline(segment.coordinates,
                               color: UIColor(red: 0.25, green: 0.45, blue: 0.95, alpha: 0.18),
                               lineWidth: 14, to: map, coordinator: coordinator)
                }
                map.addOverlay(TrackGradientOverlay(segments: gradientSegments(from: segments), lineWidth: 5), level: .aboveRoads)
            } else {
                // 活动类型单色模式：粗线 + 同色发光底衬
                for segment in segments where segment.coordinates.count > 1 {
                    let color = UIColor(segment.activityType.trackColor)
                    addPolyline(segment.coordinates, color: color.withAlphaComponent(0.15), lineWidth: 14, to: map, coordinator: coordinator)
                    addPolyline(segment.coordinates, color: color.withAlphaComponent(0.9), lineWidth: 6, to: map, coordinator: coordinator)
                }
            }
        case .vivid:
            guard !segments.isEmpty, coordinates.count > 1 else { return }
            map.addOverlay(TrackDarkOverlay(coordinates: coordinates), level: .aboveRoads)
            if colorMode == .speed {
                map.addOverlay(TrackGlowOverlay(segments: segments), level: .aboveRoads)
                map.addOverlay(TrackGradientOverlay(segments: gradientSegments(from: segments), lineWidth: 4.5), level: .aboveRoads)
            } else {
                for segment in segments where segment.coordinates.count > 1 {
                    let color = UIColor(segment.activityType.trackColor)
                    addPolyline(segment.coordinates, color: color.withAlphaComponent(0.24), lineWidth: 12, to: map, coordinator: coordinator)
                    addPolyline(segment.coordinates, color: color.withAlphaComponent(0.82), lineWidth: 3, to: map, coordinator: coordinator)
                }
                map.addOverlay(TrackGlowOverlay(segments: segments), level: .aboveRoads)
            }
        case .photoDots:
            let reliablePoints = points.filter(\.isReliable)
            let photoCoordinates = reliablePoints.map(\.coordinate)
            guard !photoCoordinates.isEmpty else { return }
            map.addOverlay(TrackDarkOverlay(coordinates: photoCoordinates, opacity: 0.22), level: .aboveRoads)
            map.addOverlay(TrackGlowOverlay(points: reliablePoints, presentation: .photoDots), level: .aboveRoads)
        }
    }

    /// 将各段速度归一化到 [0, 1]（按本段轨迹的全局最值），生成渐变着色所需的坐标+速度序列。
    private func gradientSegments(from segments: [TrackDisplaySegment]) -> [(coordinates: [CLLocationCoordinate2D], speeds: [Double])] {
        let all = segments.flatMap(\.speeds)
        let minS = all.min() ?? 0
        let maxS = all.max() ?? 0
        return segments.compactMap { segment in
            guard segment.coordinates.count > 1 else { return nil }
            let speeds: [Double]
            if maxS > minS {
                speeds = segment.speeds.map { ($0 - minS) / (maxS - minS) }
            } else {
                speeds = Array(repeating: 0.5, count: segment.speeds.count)
            }
            return (segment.coordinates, speeds)
        }
    }

    private func addPolyline(_ coordinates: [CLLocationCoordinate2D], color: UIColor, lineWidth: CGFloat, to map: MKMapView, coordinator: Coordinator) {
        let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
        coordinator.overlayStyles[ObjectIdentifier(line)] = TrackOverlayStyle(color: color, lineWidth: lineWidth)
        map.addOverlay(line)
    }

    private func addEndpointAnnotations(to map: MKMapView, coordinates: [CLLocationCoordinate2D]) {
        guard (style == .vivid || style == .standard), let first = coordinates.first, let last = coordinates.last else { return }
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
        case .coordinate(let lat, let lon):
            coordinator.lastCameraRequestID = cameraRequest.id
            let target = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            map.setRegion(MKCoordinateRegion(center: target, latitudinalMeters: 500, longitudinalMeters: 500), animated: true)
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
        private let maximumRoadMatchedSegments = 48
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
                        map.removeOverlays(map.overlays.filter { $0 is MKPolyline || $0 is TrackGlowOverlay || $0 is TrackDarkOverlay || $0 is TrackGradientOverlay })
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

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            for overlay in mapView.overlays where overlay is TrackGlowOverlay {
                mapView.renderer(for: overlay)?.setNeedsDisplay()
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let gradient = overlay as? TrackGradientOverlay {
                return TrackGradientRenderer(overlay: gradient)
            }
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
            if let photo = annotation as? TrackPhotoAnnotation {
                let identifier = "TrackPhotoAnnotation"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = photo
                view.glyphImage = UIImage(systemName: "photo.fill")
                view.markerTintColor = .systemIndigo
                view.glyphTintColor = .white
                view.displayPriority = .required
                view.canShowCallout = true
                return view
            }
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

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let photo = view.annotation as? TrackPhotoAnnotation else { return }
            parent.onPhotoTap(photo.assetIdentifier)
            mapView.deselectAnnotation(photo, animated: false)
        }
    }
}

struct TrackPhotoMoment: Identifiable {
    let assetIdentifier: String
    let creationDate: Date
    let coordinate: CLLocationCoordinate2D
    let sessionID: UUID
    let usesPhotoLocation: Bool

    var id: String { assetIdentifier }
}

private final class TrackPhotoAnnotation: NSObject, MKAnnotation {
    let assetIdentifier: String
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?

    init(moment: TrackPhotoMoment) {
        assetIdentifier = moment.assetIdentifier
        coordinate = moment.coordinate
        title = "轨迹照片"
        subtitle = moment.creationDate.formatted(date: .omitted, time: .shortened)
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
    let isAnomaly: Bool

    init(coordinate: CLLocationCoordinate2D,
         timestamp: Date = .now,
         activityType: ActivityType = .unknown,
         segmentID: Int = 0,
         horizontalAccuracy: Double = 12,
         speed: Double? = nil,
         source: TrackMapPointSource = .sample,
         isAnomaly: Bool = false) {
        self.coordinate = coordinate
        self.timestamp = timestamp
        self.activityType = activityType
        self.segmentID = segmentID
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.source = source
        self.isAnomaly = isAnomaly
    }

    init(_ point: TrackPoint) {
        self.coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        self.timestamp = point.timestamp
        self.activityType = point.activityType
        self.segmentID = 0
        self.horizontalAccuracy = point.horizontalAccuracy
        self.speed = point.speed >= 0 ? point.speed : nil
        self.source = .recorded
        self.isAnomaly = point.isAnomaly
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
            return !isAnomaly && horizontalAccuracy >= 0 && horizontalAccuracy <= 100
        }
    }
}

struct MapCameraRequest: Equatable {
    let id = UUID()
    let target: Target

    enum Target: Equatable {
        case currentLocation
        case route
        case coordinate(lat: Double, lon: Double)

        static func == (lhs: Target, rhs: Target) -> Bool {
            switch (lhs, rhs) {
            case (.currentLocation, .currentLocation), (.route, .route): return true
            case let (.coordinate(lat1, lon1), .coordinate(lat2, lon2)): return lat1 == lat2 && lon1 == lon2
            default: return false
            }
        }
    }
}

enum TrackMapStyle {
    case standard
    case vivid
    case photoDots
}

/// 轨迹着色方式：`.speed` 按速度渐变（Nike/Strava 风格），`.activity` 按运动类型单色。
enum TrackColorMode {
    case speed
    case activity
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
    /// 每个顶点的速度（米/秒），长度与 `coordinates` 一致，用于按速度着色。
    let speeds: [Double]

    var shouldSnapToRoad: Bool {
        source == .recorded
            && coordinates.count == 2
            && distance >= 80
            && distance <= 2_000
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
            // 采样/照片点已在生成阶段完成清洗，直接连线以保证轨迹连续完整，
            // 只有原始定位点才需要做最大距离/速度的异常截断。
            if current.source != .recorded {
                segments.append(TrackDisplaySegment(id: nextID,
                                                    activityType: current.activityType,
                                                    source: current.source,
                                                    coordinates: [previous.coordinate, current.coordinate],
                                                    startTimestamp: previous.timestamp,
                                                    endTimestamp: current.timestamp,
                                                    distance: distance,
                                                    averageSpeed: averageSpeed,
                                                    speeds: [previous.speed ?? averageSpeed, current.speed ?? averageSpeed]))
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
                                                averageSpeed: averageSpeed,
                                                speeds: [previous.speed ?? averageSpeed, current.speed ?? averageSpeed]))
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
        case .transit: 20
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
        case .transit: 6
        case .unknown: 4
        }
    }

    private static func maximumDistance(for activity: ActivityType) -> CLLocationDistance {
        switch activity {
        case .walking, .running: 450
        case .cycling: 900
        case .automotive: 1_800
        case .transit: 1_800
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
        case .transit: 40
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
        self.boundingMapRect = Self.visibleMapRect(for: coordinates)
        self.coordinate = MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
        self.opacity = opacity
    }

    private static func visibleMapRect(for coordinates: [CLLocationCoordinate2D]) -> MKMapRect {
        guard let first = coordinates.first else { return .world }
        var rect = MKMapRect(origin: MKMapPoint(first), size: MKMapSize(width: 1, height: 1))
        for coordinate in coordinates.dropFirst() {
            let pointRect = MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize(width: 1, height: 1))
            rect = rect.union(pointRect)
        }
        let insetX = max(rect.width, 8_000)
        let insetY = max(rect.height, 8_000)
        return rect.insetBy(dx: -insetX, dy: -insetY)
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

    init(points: [TrackMapPoint], presentation: Presentation) {
        self.points = points
        self.boundingMapRect = Self.visibleMapRect(for: points.map(\.coordinate))
        self.coordinate = MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
        self.presentation = presentation
    }

    init(segments: [TrackDisplaySegment], interpolatesBetweenPoints: Bool = true, presentation: Presentation = .track) {
        self.points = Self.densified(segments, interpolatesBetweenPoints: interpolatesBetweenPoints)
        self.boundingMapRect = Self.visibleMapRect(for: self.points.map(\.coordinate))
        self.coordinate = MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
        self.presentation = presentation
    }

    private static func visibleMapRect(for coordinates: [CLLocationCoordinate2D]) -> MKMapRect {
        guard let first = coordinates.first else { return .world }
        var rect = MKMapRect(origin: MKMapPoint(first), size: MKMapSize(width: 1, height: 1))
        for coordinate in coordinates.dropFirst() {
            let pointRect = MKMapRect(origin: MKMapPoint(coordinate), size: MKMapSize(width: 1, height: 1))
            rect = rect.union(pointRect)
        }
        let padding = max(max(rect.width, rect.height) * 0.18, 7_000)
        return rect.insetBy(dx: -padding, dy: -padding)
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
        let scale = max(CGFloat(zoomScale), 0.000_001)
        let renderUnitsPerPoint = 1 / scale
        context.saveGState()
        context.setBlendMode(.plusLighter)

        if overlay.presentation == .photoDots {
            drawPhotoDots(overlay.points,
                          visible: visible,
                          renderUnitsPerPoint: renderUnitsPerPoint,
                          in: context)
            context.restoreGState()
            return
        }

        for point in overlay.points {
            let mapPoint = MKMapPoint(point.coordinate)
            guard visible.contains(mapPoint) else { continue }
            drawParticle(at: self.point(for: mapPoint),
                         radius: 1.65 * renderUnitsPerPoint,
                         color: UIColor(point.activityType.trackColor),
                         alpha: 0.82,
                         in: context)
        }

        context.restoreGState()
    }

    private func drawPhotoDots(_ points: [TrackMapPoint],
                               visible: MKMapRect,
                               renderUnitsPerPoint: CGFloat,
                               in context: CGContext) {
        let color = UIColor(red: 0.39, green: 0.96, blue: 0.80, alpha: 1)
        // Cluster only to avoid overdraw. The cell and dot both live in screen
        // points, so zooming never changes their perceived size.
        let cellSize = 8 * renderUnitsPerPoint
        var buckets: [PhotoDotBucket: PhotoDotCluster] = [:]

        for point in points {
            let mapPoint = MKMapPoint(point.coordinate)
            guard visible.contains(mapPoint) else { continue }
            let renderPoint = self.point(for: mapPoint)
            let key = PhotoDotBucket(x: Int(renderPoint.x / cellSize), y: Int(renderPoint.y / cellSize))
            buckets[key, default: PhotoDotCluster()].add(renderPoint)
        }

        for cluster in buckets.values {
            let density = min(log2(CGFloat(cluster.count) + 1) / 6, 1)
            drawParticle(at: cluster.center,
                         radius: 2.4 * renderUnitsPerPoint,
                         color: color,
                         alpha: 0.68 + density * 0.26,
                         in: context)
        }
    }

    private func drawParticle(at point: CGPoint,
                              radius: CGFloat,
                              color: UIColor,
                              alpha: CGFloat,
                              in context: CGContext) {
        context.setFillColor(color.withAlphaComponent(alpha).cgColor)
        context.fillEllipse(in: circleRect(center: point, radius: radius))
    }

    private func circleRect(center: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius,
               y: center.y - radius,
               width: radius * 2,
               height: radius * 2)
    }

}

private final class TrackGradientOverlay: NSObject, MKOverlay {
    let polylines: [MKPolyline]
    let speeds: [[Double]]
    let lineWidth: CGFloat
    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D

    init(segments: [(coordinates: [CLLocationCoordinate2D], speeds: [Double])], lineWidth: CGFloat) {
        var polys: [MKPolyline] = []
        var spds: [[Double]] = []
        var rect = MKMapRect.null
        for segment in segments where segment.coordinates.count > 1 {
            let poly = MKPolyline(coordinates: segment.coordinates, count: segment.coordinates.count)
            polys.append(poly)
            spds.append(segment.speeds)
            rect = rect.union(poly.boundingMapRect)
        }
        self.polylines = polys
        self.speeds = spds
        self.lineWidth = lineWidth
        self.boundingMapRect = rect
        self.coordinate = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
    }
}

/// 按速度逐段着色的渲染器（Nike+/Strava 风格速度热力）。
private final class TrackGradientRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? TrackGradientOverlay else { return }
        let lineWidth = overlay.lineWidth * CGFloat(zoomScale)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setBlendMode(.normal)
        context.setShouldAntialias(true)

        // 先画一层半透明白色底衬，增强对比度
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.15).cgColor)
        context.setLineWidth(lineWidth + 3 * CGFloat(zoomScale))
        for index in 0..<overlay.polylines.count {
            let poly = overlay.polylines[index]
            let count = poly.pointCount
            guard count > 1 else { continue }
            var coords = Array(repeating: CLLocationCoordinate2D(), count: count)
            poly.getCoordinates(&coords, range: NSRange(location: 0, length: count))
            let path = CGMutablePath()
            path.move(to: point(for: MKMapPoint(coords[0])))
            for i in 1..<count {
                path.addLine(to: point(for: MKMapPoint(coords[i])))
            }
            context.addPath(path)
        }
        context.strokePath()

        // 再画速度渐变主线
        context.setLineWidth(lineWidth)
        for index in 0..<overlay.polylines.count {
            let poly = overlay.polylines[index]
            let speeds = overlay.speeds[index]
            let count = poly.pointCount
            guard count > 1 else { continue }
            var coordinates = Array(repeating: CLLocationCoordinate2D(), count: count)
            poly.getCoordinates(&coordinates, range: NSRange(location: 0, length: count))
            for i in 0..<count - 1 {
                let a = speeds[min(i, speeds.count - 1)]
                let b = speeds[min(i + 1, speeds.count - 1)]
                context.setStrokeColor(speedRampColor((a + b) / 2).cgColor)
                let p0 = self.point(for: MKMapPoint(coordinates[i]))
                let p1 = self.point(for: MKMapPoint(coordinates[i + 1]))
                context.move(to: p0)
                context.addLine(to: p1)
                context.strokePath()
            }
        }
    }
}

/// 速度→颜色色标：慢（蓝）→中（绿/黄）→快（橙红）。
private func speedRampColor(_ t: Double) -> UIColor {
    let t = min(max(CGFloat(t), 0), 1)
    let stops: [(CGFloat, UIColor)] = [
        (0.0, UIColor(red: 0.20, green: 0.55, blue: 1.00, alpha: 1)),
        (0.40, UIColor(red: 0.24, green: 0.83, blue: 0.66, alpha: 1)),
        (0.70, UIColor(red: 0.98, green: 0.80, blue: 0.30, alpha: 1)),
        (1.0, UIColor(red: 1.00, green: 0.36, blue: 0.28, alpha: 1))
    ]
    for i in 0..<stops.count - 1 {
        let (p0, c0) = stops[i]
        let (p1, c1) = stops[i + 1]
        if t <= p1 {
            let f = p1 > p0 ? (t - p0) / (p1 - p0) : 0
            return interpolateColor(c0, c1, f)
        }
    }
    return stops.last!.1
}

private func interpolateColor(_ a: UIColor, _ b: UIColor, _ f: CGFloat) -> UIColor {
    var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
    var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
    a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
    b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
    return UIColor(red: ar + (br - ar) * f, green: ag + (bg - ag) * f, blue: ab + (bb - ab) * f, alpha: aa + (ba - aa) * f)
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
        case .transit: Color(red: 0.36, green: 0.90, blue: 0.86)
        case .stationary: .gray
        case .unknown: Color(red: 0.68, green: 0.82, blue: 1.0)
        }
    }

    var mapKitTransportType: MKDirectionsTransportType {
        switch self {
        case .walking, .running, .stationary:
            return .walking
        case .cycling, .automotive, .transit, .unknown:
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

extension Array where Element == TrackMapPoint {
    /// 地图渲染前抽稀，避免超大轨迹卡顿；均匀采样并保留首尾点。
    /// 4000 个点在任意缩放级别下都足够平滑，肉眼无差别。
    func downsampledForMap(maxCount: Int = 4000) -> [TrackMapPoint] {
        guard count > maxCount else { return self }
        let step = Double(count - 1) / Double(maxCount - 1)
        var result: [TrackMapPoint] = []
        result.reserveCapacity(maxCount)
        for index in 0..<maxCount {
            let sourceIndex = Swift.min(Int((Double(index) * step).rounded()), count - 1)
            result.append(self[sourceIndex])
        }
        return result
    }
}

/// 速度图例：渐变条 + 慢/快标签，叠加在轨迹地图左下角，说明按速度着色含义。
struct TrackSpeedLegend: View {
    private let stops: [Color] = [
        Color(red: 0.20, green: 0.55, blue: 1.00),
        Color(red: 0.24, green: 0.83, blue: 0.66),
        Color(red: 0.98, green: 0.80, blue: 0.30),
        Color(red: 1.00, green: 0.36, blue: 0.28)
    ]

    var body: some View {
        HStack(spacing: 6) {
            Text("慢").font(.caption2).foregroundStyle(.secondary)
            LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
                .frame(width: 72, height: 8)
                .clipShape(Capsule())
            Text("快").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
