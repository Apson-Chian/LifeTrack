import CoreLocation
import Foundation
import SwiftData

/// A separately versioned geofence keeps the original CustomPlace schema stable while
/// allowing irregular, user-drawn areas to be added through a lightweight migration.
@Model
final class PlaceGeofence {
    @Attribute(.unique) var placeID: UUID
    var areaTypeRawValue: String
    var encodedVertices: String?
    var updatedAt: Date

    init(placeID: UUID,
         areaType: PlaceAreaType = .ordinary,
         vertices: [CLLocationCoordinate2D] = []) {
        self.placeID = placeID
        self.areaTypeRawValue = areaType.rawValue
        self.encodedVertices = Self.encode(vertices)
        self.updatedAt = .now
    }

    var areaType: PlaceAreaType {
        get { PlaceAreaType(rawValue: areaTypeRawValue) ?? .ordinary }
        set { areaTypeRawValue = newValue.rawValue }
    }

    var vertices: [CLLocationCoordinate2D] {
        get { Self.decode(encodedVertices) }
        set { encodedVertices = Self.encode(newValue); updatedAt = .now }
    }

    private static func encode(_ vertices: [CLLocationCoordinate2D]) -> String? {
        guard vertices.count >= 3 else { return nil }
        return vertices.map { "\($0.latitude),\($0.longitude)" }.joined(separator: ";")
    }

    private static func decode(_ value: String?) -> [CLLocationCoordinate2D] {
        guard let value else { return [] }
        return value.split(separator: ";").compactMap { pair in
            let parts = pair.split(separator: ",")
            guard parts.count == 2,
                  let latitude = Double(parts[0]),
                  let longitude = Double(parts[1]),
                  CLLocationCoordinate2DIsValid(.init(latitude: latitude, longitude: longitude)) else { return nil }
            return .init(latitude: latitude, longitude: longitude)
        }
    }
}

enum PlaceAreaType: String, CaseIterable, Identifiable {
    case ordinary, campus, library, classroom, dormitory, foodStreet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ordinary: "普通地点"
        case .campus: "校园"
        case .library: "图书馆"
        case .classroom: "教室"
        case .dormitory: "寝室"
        case .foodStreet: "美食街"
        }
    }

    var symbolName: String {
        switch self {
        case .ordinary: "mappin.circle.fill"
        case .campus: "graduationcap.fill"
        case .library: "books.vertical.fill"
        case .classroom: "person.3.fill"
        case .dormitory: "bed.double.fill"
        case .foodStreet: "fork.knife"
        }
    }

    var defaultCategory: PlaceCategory {
        switch self {
        case .library, .classroom: .study
        case .dormitory: .accommodation
        case .foodStreet: .dining
        case .ordinary, .campus: .other
        }
    }
}

enum PlaceGeofenceGeometry {
    static func contains(_ coordinate: CLLocationCoordinate2D,
                         place: CustomPlace,
                         geofence: PlaceGeofence?) -> Bool {
        let vertices = geofence?.vertices ?? []
        guard vertices.count >= 3 else {
            return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude)) <= place.radius
        }
        return contains(coordinate, in: vertices)
    }

    static func contains(_ point: CLLocationCoordinate2D,
                         in polygon: [CLLocationCoordinate2D]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var isInside = false
        var previous = polygon.count - 1
        for current in polygon.indices {
            let a = polygon[current]
            let b = polygon[previous]
            let crossesLatitude = (a.latitude > point.latitude) != (b.latitude > point.latitude)
            if crossesLatitude {
                let crossingLongitude = (b.longitude - a.longitude) *
                    (point.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude
                if point.longitude < crossingLongitude { isInside.toggle() }
            }
            previous = current
        }
        return isInside
    }
}
