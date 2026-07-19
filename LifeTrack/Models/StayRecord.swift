import Foundation
import SwiftData

@Model
final class StayRecord {
    @Attribute(.unique) var id: UUID
    var customPlaceID: UUID?
    var detectedName: String?
    var latitude: Double
    var longitude: Double
    var arrivalTime: Date
    var departureTime: Date?
    var duration: TimeInterval
    var session: ActivitySession?

    init(customPlaceID: UUID? = nil, detectedName: String? = nil, latitude: Double, longitude: Double, arrivalTime: Date = .now, session: ActivitySession? = nil) {
        self.id = UUID()
        self.customPlaceID = customPlaceID
        self.detectedName = detectedName
        self.latitude = latitude
        self.longitude = longitude
        self.arrivalTime = arrivalTime
        self.duration = 0
        self.session = session
    }
}
