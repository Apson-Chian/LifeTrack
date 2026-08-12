import CoreLocation
import MapKit

final class GeocodingService {
    private let geocoder = CLGeocoder()

    func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async -> String? {
        if #available(iOS 26.0, *) {
            let request = MKReverseGeocodingRequest(location: CLLocation(latitude: coordinate.latitude,
                                                                          longitude: coordinate.longitude))
            do {
                if let item = try await request?.mapItems.first,
                   let name = item.name ?? item.placemark.title,
                   !name.isEmpty {
                    return name
                }
            } catch {
                // Fall back to the system geocoder when MapKit has no local result.
            }
        }

        do {
            let placemark = try await geocoder.reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)).first
            return [placemark?.name, placemark?.locality].compactMap { $0 }.joined(separator: ", ")
        } catch {
            return nil
        }
    }
}
