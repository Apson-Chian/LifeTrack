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
    var radius: Double = 0
    var pointCount: Int = 0
    var confidence: Double = 0
    var sourceRawValue: String = StayRecordSource.placeGeofence.rawValue
    var session: ActivitySession?

    init(customPlaceID: UUID? = nil,
         detectedName: String? = nil,
         latitude: Double,
         longitude: Double,
         arrivalTime: Date = .now,
         radius: Double = 0,
         pointCount: Int = 0,
         confidence: Double = 0,
         source: StayRecordSource = .placeGeofence,
         session: ActivitySession? = nil) {
        self.id = UUID()
        self.customPlaceID = customPlaceID
        self.detectedName = detectedName
        self.latitude = latitude
        self.longitude = longitude
        self.arrivalTime = arrivalTime
        self.duration = 0
        self.radius = radius
        self.pointCount = pointCount
        self.confidence = confidence
        self.sourceRawValue = source.rawValue
        self.session = session
    }

    var source: StayRecordSource {
        get { StayRecordSource(rawValue: sourceRawValue) ?? .placeGeofence }
        set { sourceRawValue = newValue.rawValue }
    }
}

enum StayRecordSource: String, Codable {
    case placeGeofence
    case automaticDetection
}
