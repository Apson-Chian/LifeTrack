import Foundation
import SwiftData

@Model
final class JourneyRecord {
    @Attribute(.unique) var id: UUID
    @Attribute(.unique) var stableKey: String
    var startTime: Date
    var endTime: Date
    var startPlace: String?
    var endPlace: String?
    var totalDistance: Double
    var duration: TimeInterval
    var primaryActivityRawValue: String
    var sessionIDsRawValue: String
    var stayRecordIDsRawValue: String
    var generatedAt: Date
    var generationVersion: Int

    init(stableKey: String,
         startTime: Date,
         endTime: Date,
         startPlace: String?,
         endPlace: String?,
         totalDistance: Double,
         primaryActivity: ActivityType,
         sessionIDs: [UUID],
         stayRecordIDs: [UUID],
         generationVersion: Int = 1) {
        id = UUID()
        self.stableKey = stableKey
        self.startTime = startTime
        self.endTime = endTime
        self.startPlace = startPlace
        self.endPlace = endPlace
        self.totalDistance = totalDistance
        duration = max(0, endTime.timeIntervalSince(startTime))
        primaryActivityRawValue = primaryActivity.rawValue
        sessionIDsRawValue = sessionIDs.map(\.uuidString).joined(separator: "\n")
        stayRecordIDsRawValue = stayRecordIDs.map(\.uuidString).joined(separator: "\n")
        generatedAt = .now
        self.generationVersion = generationVersion
    }

    var primaryActivity: ActivityType {
        ActivityType(rawValue: primaryActivityRawValue) ?? .unknown
    }

    var sessionIDs: [UUID] {
        sessionIDsRawValue.split(separator: "\n").compactMap { UUID(uuidString: String($0)) }
    }

    var stayRecordIDs: [UUID] {
        stayRecordIDsRawValue.split(separator: "\n").compactMap { UUID(uuidString: String($0)) }
    }

    func update(startTime: Date,
                endTime: Date,
                startPlace: String?,
                endPlace: String?,
                totalDistance: Double,
                primaryActivity: ActivityType,
                sessionIDs: [UUID],
                stayRecordIDs: [UUID],
                generationVersion: Int) {
        self.startTime = startTime
        self.endTime = endTime
        self.startPlace = startPlace
        self.endPlace = endPlace
        self.totalDistance = totalDistance
        duration = max(0, endTime.timeIntervalSince(startTime))
        primaryActivityRawValue = primaryActivity.rawValue
        sessionIDsRawValue = sessionIDs.map(\.uuidString).joined(separator: "\n")
        stayRecordIDsRawValue = stayRecordIDs.map(\.uuidString).joined(separator: "\n")
        generatedAt = .now
        self.generationVersion = generationVersion
    }
}
