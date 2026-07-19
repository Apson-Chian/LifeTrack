import Foundation
import SwiftData

@Model
final class TrackPoint {
    @Attribute(.unique) var id: UUID
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var speed: Double
    var course: Double
    var horizontalAccuracy: Double
    var timestamp: Date
    var activityTypeRawValue: String
    var session: ActivitySession?

    init(latitude: Double, longitude: Double, altitude: Double, speed: Double, course: Double, horizontalAccuracy: Double, timestamp: Date, activityType: ActivityType, session: ActivitySession? = nil) {
        self.id = UUID()
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speed = speed
        self.course = course
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
        self.activityTypeRawValue = activityType.rawValue
        self.session = session
    }

    var activityType: ActivityType { ActivityType(rawValue: activityTypeRawValue) ?? .unknown }
}
