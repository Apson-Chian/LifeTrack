import CoreLocation
import SwiftData

final class PlaceRecognitionService {
    // Exit uses an extra buffer so a user standing at a boundary does not create repeated visits.
    private let exitBuffer: CLLocationDistance = 20
    private let minimumStay: TimeInterval = 5 * 60

    func matchingPlace(for location: CLLocation, places: [CustomPlace]) -> CustomPlace? {
        places
            .filter { location.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) <= $0.radius }
            .sorted {
                if $0.radius != $1.radius { return $0.radius < $1.radius }
                if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
                return $0.priority > $1.priority
            }
            .first
    }

    func hasExited(_ place: CustomPlace, location: CLLocation) -> Bool {
        location.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude)) > place.radius + exitBuffer
    }

    func isConfirmedStay(from arrival: Date, to departure: Date = .now) -> Bool {
        departure.timeIntervalSince(arrival) >= minimumStay
    }
}
