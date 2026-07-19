import Foundation
import SwiftData

@Model
final class ActivitySession {
    @Attribute(.unique) var id: UUID
    var activityTypeRawValue: String
    var sourceRawValue: String
    var startTime: Date
    var endTime: Date?
    var distance: Double
    var duration: TimeInterval
    var isActive: Bool
    var destinationName: String?
    var destinationLatitude: Double?
    var destinationLongitude: Double?
    var manualActivityTypeRawValue: String?

    @Relationship(deleteRule: .cascade, inverse: \TrackPoint.session)
    var trackPoints: [TrackPoint] = []
    @Relationship(deleteRule: .cascade, inverse: \StayRecord.session)
    var stayRecords: [StayRecord] = []

    init(activityType: ActivityType = .unknown, source: String = "manual", startTime: Date = .now) {
        self.id = UUID()
        self.activityTypeRawValue = activityType.rawValue
        self.sourceRawValue = source
        self.startTime = startTime
        self.distance = 0
        self.duration = 0
        self.isActive = true
    }

    var activityType: ActivityType {
        get { ActivityType(rawValue: activityTypeRawValue) ?? .unknown }
        set { activityTypeRawValue = newValue.rawValue }
    }

    var manualActivityType: ActivityType? {
        get { manualActivityTypeRawValue.flatMap(ActivityType.init(rawValue:)) }
        set { manualActivityTypeRawValue = newValue?.rawValue }
    }
}
