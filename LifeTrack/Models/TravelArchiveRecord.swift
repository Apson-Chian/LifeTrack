import Foundation
import SwiftData

@Model
final class TravelArchiveRecord {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var sourceFingerprint: String
    var title: String
    var startTime: Date
    var endTime: Date
    var photoCount: Int
    var placeCount: Int
    var totalDistance: Double
    var mainPlacesRawValue: String
    var createdAt: Date
    var updatedAt: Date

    init(sourceFingerprint: String,
         title: String,
         startTime: Date,
         endTime: Date,
         photoCount: Int,
         placeCount: Int,
         totalDistance: Double,
         mainPlaces: [String]) {
        id = UUID()
        self.sourceFingerprint = sourceFingerprint
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.photoCount = photoCount
        self.placeCount = placeCount
        self.totalDistance = totalDistance
        mainPlacesRawValue = mainPlaces.joined(separator: "\n")
        createdAt = .now
        updatedAt = .now
    }

    var mainPlaces: [String] {
        mainPlacesRawValue.split(separator: "\n").map(String.init)
    }
}
