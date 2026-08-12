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
    var isAnomaly: Bool = false
    var anomalyReasonRawValue: String?
    var session: ActivitySession?

    init(latitude: Double,
         longitude: Double,
         altitude: Double,
         speed: Double,
         course: Double,
         horizontalAccuracy: Double,
         timestamp: Date,
         activityType: ActivityType,
         isAnomaly: Bool = false,
         anomalyReason: TrackPointAnomalyReason? = nil,
         session: ActivitySession? = nil) {
        self.id = UUID()
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speed = speed
        self.course = course
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
        self.activityTypeRawValue = activityType.rawValue
        self.isAnomaly = isAnomaly
        self.anomalyReasonRawValue = anomalyReason?.rawValue
        self.session = session
    }

    var activityType: ActivityType { ActivityType(rawValue: activityTypeRawValue) ?? .unknown }

    var anomalyReason: TrackPointAnomalyReason? {
        get { anomalyReasonRawValue.flatMap(TrackPointAnomalyReason.init(rawValue:)) }
        set {
            anomalyReasonRawValue = newValue?.rawValue
            isAnomaly = newValue != nil
        }
    }

    var isUsableForAnalysis: Bool { !isAnomaly }
}

enum TrackPointAnomalyReason: String, Codable {
    case invalidCoordinate
    case poorAccuracy
    case impossibleJump
    case detourSpike

    var displayName: String {
        switch self {
        case .invalidCoordinate: "无效坐标"
        case .poorAccuracy: "定位精度过低"
        case .impossibleJump: "不可能的位移"
        case .detourSpike: "疑似 GPS 漂移"
        }
    }
}
