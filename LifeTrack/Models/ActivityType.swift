import Foundation
import CoreLocation

enum ActivityType: String, CaseIterable, Codable, Identifiable {
    case stationary
    case walking
    case running
    case cycling
    case automotive
    case transit
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stationary: "静止"
        case .walking: "步行"
        case .running: "跑步"
        case .cycling: "骑行"
        case .automotive: "驾车"
        case .transit: "公交地铁"
        case .unknown: "未知"
        }
    }

    var symbolName: String {
        switch self {
        case .stationary: "pause.circle"
        case .walking: "figure.walk"
        case .running: "figure.run"
        case .cycling: "bicycle"
        case .automotive: "car"
        case .transit: "tram.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var isExercise: Bool { self == .walking || self == .running || self == .cycling }
}

enum RecordingPreference: String, CaseIterable, Identifiable {
    case smart
    case batterySaver
    case precise

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .smart: "智能"
        case .batterySaver: "省电"
        case .precise: "精细"
        }
    }
}

struct SamplingPolicy {
    let desiredAccuracy: CLLocationAccuracy
    let distanceFilter: CLLocationDistance
    let minimumInterval: TimeInterval
    let minimumAccuracy: CLLocationAccuracy

    static func policy(for activity: ActivityType, preference: RecordingPreference) -> SamplingPolicy {
        if preference == .precise {
            return SamplingPolicy(desiredAccuracy: kCLLocationAccuracyBest,
                                  distanceFilter: 3,
                                  minimumInterval: 1,
                                  minimumAccuracy: 80)
        }
        if preference == .batterySaver {
            return SamplingPolicy(desiredAccuracy: kCLLocationAccuracyNearestTenMeters,
                                  distanceFilter: 35,
                                  minimumInterval: 12,
                                  minimumAccuracy: 120)
        }

        switch activity {
        case .stationary:
            return SamplingPolicy(desiredAccuracy: kCLLocationAccuracyHundredMeters, distanceFilter: 100, minimumInterval: 120, minimumAccuracy: 200)
        case .walking:
            return SamplingPolicy(desiredAccuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: 12, minimumInterval: 6, minimumAccuracy: 80)
        case .running:
            return SamplingPolicy(desiredAccuracy: kCLLocationAccuracyBest, distanceFilter: 4, minimumInterval: 1.5, minimumAccuracy: 45)
        case .cycling:
            return SamplingPolicy(desiredAccuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: 25, minimumInterval: 7, minimumAccuracy: 70)
        case .automotive:
            return SamplingPolicy(desiredAccuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: 75, minimumInterval: 15, minimumAccuracy: 100)
        case .transit:
            return SamplingPolicy(desiredAccuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: 75, minimumInterval: 15, minimumAccuracy: 100)
        case .unknown:
            return SamplingPolicy(desiredAccuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: 25, minimumInterval: 10, minimumAccuracy: 100)
        }
    }
}
