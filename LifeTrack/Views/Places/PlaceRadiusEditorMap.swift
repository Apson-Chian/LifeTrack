import SwiftUI
import MapKit

struct PlaceRadiusEditorMap: UIViewRepresentable {
    @Binding var coordinate: CLLocationCoordinate2D
    @Binding var radius: Double
    @Binding var boundaryVertices: [CLLocationCoordinate2D]
    @Binding var isDrawingBoundary: Bool
    @Binding var isBoundaryClosed: Bool

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        map.pointOfInterestFilter = .includingAll
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)

        let annotation = context.coordinator.annotation
        annotation.coordinate = coordinate
        annotation.title = "打卡中心"
        map.addAnnotation(annotation)

        let longPress = UILongPressGestureRecognizer(target: context.coordinator,
                                                     action: #selector(Coordinator.longPressed(_:)))
        map.addGestureRecognizer(longPress)
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.tapped(_:)))
        tap.require(toFail: longPress)
        map.addGestureRecognizer(tap)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        if !context.coordinator.isDragging {
            context.coordinator.annotation.coordinate = coordinate
        }

        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations.filter { $0 is BoundaryVertexAnnotation })
        if isBoundaryClosed, boundaryVertices.count >= 3 {
            var vertices = boundaryVertices
            map.addOverlay(MKPolygon(coordinates: &vertices, count: vertices.count))
        } else {
            if !isDrawingBoundary {
                map.addOverlay(MKCircle(center: coordinate, radius: radius))
            }
        }
        for (index, vertex) in boundaryVertices.enumerated() {
            map.addAnnotation(BoundaryVertexAnnotation(coordinate: vertex, index: index))
        }

        guard !context.coordinator.hasSetInitialRegion else { return }
        let span = max(radius * 4, 600)
        map.setRegion(MKCoordinateRegion(center: coordinate,
                                         latitudinalMeters: span,
                                         longitudinalMeters: span),
                      animated: false)
        context.coordinator.hasSetInitialRegion = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: PlaceRadiusEditorMap
        let annotation = MKPointAnnotation()
        var hasSetInitialRegion = false
        var isDragging = false

        init(_ parent: PlaceRadiusEditorMap) {
            self.parent = parent
        }

        @objc func longPressed(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began,
                  let map = recognizer.view as? MKMapView,
                  !parent.isDrawingBoundary else { return }
            let newCoordinate = map.convert(recognizer.location(in: map), toCoordinateFrom: map)
            annotation.coordinate = newCoordinate
            parent.coordinate = newCoordinate
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let map = recognizer.view as? MKMapView,
                  parent.isDrawingBoundary else { return }
            parent.boundaryVertices.append(
                map.convert(recognizer.location(in: map), toCoordinateFrom: map)
            )
            parent.isBoundaryClosed = false
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let vertex = annotation as? BoundaryVertexAnnotation {
                let identifier = "BoundaryVertex"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.markerTintColor = .systemIndigo
                view.glyphText = "\(vertex.index + 1)"
                view.displayPriority = .required
                return view
            }
            guard annotation === self.annotation else { return nil }
            let identifier = "PlaceRadiusCenter"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.markerTintColor = .systemBlue
            view.glyphImage = UIImage(systemName: "scope")
            view.glyphTintColor = .white
            view.isDraggable = true
            view.canShowCallout = true
            return view
        }

        func mapView(_ mapView: MKMapView,
                     annotationView view: MKAnnotationView,
                     didChange newState: MKAnnotationView.DragState,
                     fromOldState oldState: MKAnnotationView.DragState) {
            switch newState {
            case .starting:
                isDragging = true
            case .ending, .canceling:
                if let coordinate = view.annotation?.coordinate {
                    annotation.coordinate = coordinate
                    parent.coordinate = coordinate
                }
                isDragging = false
                view.setDragState(.none, animated: true)
            default:
                break
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.strokeColor = .systemIndigo
                renderer.fillColor = UIColor.systemIndigo.withAlphaComponent(0.18)
                renderer.lineWidth = 2
                return renderer
            }
            guard let circle = overlay as? MKCircle else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKCircleRenderer(circle: circle)
            renderer.strokeColor = .systemBlue
            renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.16)
            renderer.lineWidth = 2
            return renderer
        }
    }
}

private final class BoundaryVertexAnnotation: MKPointAnnotation {
    let index: Int

    init(coordinate: CLLocationCoordinate2D, index: Int) {
        self.index = index
        super.init()
        self.coordinate = coordinate
    }
}
