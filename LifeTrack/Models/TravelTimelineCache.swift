import Foundation
import SwiftData
import CoreLocation

@Model
final class TravelTimelineTrip {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var stableKey: String
    var title: String
    var startTime: Date
    var endTime: Date
    var totalDistance: Double
    var sourceFingerprint: String
    var generatedAt: Date
    var routeData: Data

    @Relationship(deleteRule: .cascade, inverse: \TravelTimelineNode.trip)
    var nodes: [TravelTimelineNode] = []

    init(stableKey: String,
         title: String,
         startTime: Date,
         endTime: Date,
         totalDistance: Double,
         sourceFingerprint: String,
         routePoints: [TravelTimelineRoutePoint]) {
        id = UUID()
        self.stableKey = stableKey
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.totalDistance = totalDistance
        self.sourceFingerprint = sourceFingerprint
        generatedAt = .now
        routeData = (try? JSONEncoder().encode(routePoints)) ?? Data()
    }

    var duration: TimeInterval { max(0, endTime.timeIntervalSince(startTime)) }

    var routePoints: [TravelTimelineRoutePoint] {
        (try? JSONDecoder().decode([TravelTimelineRoutePoint].self, from: routeData)) ?? []
    }

    func update(title: String,
                startTime: Date,
                endTime: Date,
                totalDistance: Double,
                sourceFingerprint: String,
                routePoints: [TravelTimelineRoutePoint]) {
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.totalDistance = totalDistance
        self.sourceFingerprint = sourceFingerprint
        generatedAt = .now
        routeData = (try? JSONEncoder().encode(routePoints)) ?? Data()
    }
}

@Model
final class TravelTimelineNode {
    @Attribute(.unique) var id: UUID
    var stableKey: String
    var kindRawValue: String
    var startTime: Date
    var endTime: Date
    var latitude: Double
    var longitude: Double
    var endLatitude: Double?
    var endLongitude: Double?
    var placeName: String?
    var endPlaceName: String?
    var distance: Double
    var activityTypeRawValue: String
    var photoIdentifiersRawValue: String
    var categoryRawValues: String
    var trip: TravelTimelineTrip?

    init(stableKey: String,
         kind: TravelTimelineNodeKind,
         startTime: Date,
         endTime: Date,
         coordinate: CLLocationCoordinate2D,
         endCoordinate: CLLocationCoordinate2D?,
         distance: Double,
         activityType: ActivityType,
         photoIdentifiers: [String],
         categories: [PhotoSmartCategory],
         trip: TravelTimelineTrip) {
        id = UUID()
        self.stableKey = stableKey
        kindRawValue = kind.rawValue
        self.startTime = startTime
        self.endTime = endTime
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        endLatitude = endCoordinate?.latitude
        endLongitude = endCoordinate?.longitude
        self.distance = distance
        activityTypeRawValue = activityType.rawValue
        photoIdentifiersRawValue = photoIdentifiers.joined(separator: "\n")
        categoryRawValues = categories.map(\.rawValue).joined(separator: ",")
        self.trip = trip
    }

    var kind: TravelTimelineNodeKind {
        TravelTimelineNodeKind(rawValue: kindRawValue) ?? .stay
    }

    var activityType: ActivityType {
        ActivityType(rawValue: activityTypeRawValue) ?? .unknown
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var endingCoordinate: CLLocationCoordinate2D? {
        guard let endLatitude, let endLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: endLatitude, longitude: endLongitude)
    }

    var duration: TimeInterval { max(0, endTime.timeIntervalSince(startTime)) }

    var photoIdentifiers: [String] {
        photoIdentifiersRawValue.isEmpty ? [] : photoIdentifiersRawValue.split(separator: "\n").map(String.init)
    }

    var categories: [PhotoSmartCategory] {
        categoryRawValues.split(separator: ",").compactMap { PhotoSmartCategory(rawValue: String($0)) }
    }

    func update(kind: TravelTimelineNodeKind,
                startTime: Date,
                endTime: Date,
                coordinate: CLLocationCoordinate2D,
                endCoordinate: CLLocationCoordinate2D?,
                distance: Double,
                activityType: ActivityType,
                photoIdentifiers: [String],
                categories: [PhotoSmartCategory]) {
        let moved = CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) > 80
        let endMoved: Bool
        if let previous = endingCoordinate, let endCoordinate {
            endMoved = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                .distance(from: CLLocation(latitude: endCoordinate.latitude, longitude: endCoordinate.longitude)) > 80
        } else {
            endMoved = endingCoordinate != nil || endCoordinate != nil
        }

        kindRawValue = kind.rawValue
        self.startTime = startTime
        self.endTime = endTime
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        endLatitude = endCoordinate?.latitude
        endLongitude = endCoordinate?.longitude
        self.distance = distance
        activityTypeRawValue = activityType.rawValue
        photoIdentifiersRawValue = photoIdentifiers.joined(separator: "\n")
        categoryRawValues = categories.map(\.rawValue).joined(separator: ",")
        if moved { placeName = nil }
        if endMoved { endPlaceName = nil }
    }
}

enum TravelTimelineNodeKind: String, Codable {
    case stay
    case movement
}

struct TravelTimelineRoutePoint: Codable, Sendable {
    let latitude: Double
    let longitude: Double
    let timestamp: Date
    let activityTypeRawValue: String

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var activityType: ActivityType {
        ActivityType(rawValue: activityTypeRawValue) ?? .unknown
    }
}
