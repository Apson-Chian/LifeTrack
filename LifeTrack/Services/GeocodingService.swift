import CoreLocation

final class GeocodingService {
    private let geocoder = CLGeocoder()

    func reverseGeocode(_ coordinate: CLLocationCoordinate2D) async -> String? {
        do {
            let placemark = try await geocoder.reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)).first
            return [placemark?.name, placemark?.locality].compactMap { $0 }.joined(separator: ", ")
        } catch {
            return nil
        }
    }
}
