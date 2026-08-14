import CoreLocation
import Foundation

/// 公共交通识别：基于轨迹点的事后启发式判断。
///
/// 由于 Core Motion 不会区分“驾车”与“公交/地铁”，这里在轨迹结束后，
/// 依据「中等移动速度 + 多次短暂停靠（车站/站点）」的模式把疑似公共交通
/// 的 `.automotive` 轨迹重标为 `.transit`。属于尽力而为的本地推断。
enum TransitDetectionService {
    private static let minimumPointCount = 20
    private static let minimumAutomotiveRatio = 0.5
    private static let minimumStopDuration: TimeInterval = 20
    private static let maximumStopDuration: TimeInterval = 5 * 60
    private static let minimumTransitSpeed: Double = 5
    private static let maximumTransitSpeed: Double = 30

    /// 返回该轨迹应归类为的活动类型（`.transit` 或保留原类型）。
    static func classify(_ points: [TrackPoint]) -> ActivityType {
        let ordered = points
            .filter(\.isUsableForAnalysis)
            .sorted { $0.timestamp < $1.timestamp }
        guard ordered.count >= minimumPointCount else { return ordered.first?.activityType ?? .unknown }

        let automotiveCount = ordered.filter { $0.activityType == .automotive }.count
        guard Double(automotiveCount) / Double(ordered.count) >= minimumAutomotiveRatio else {
            return ordered.first?.activityType ?? .automotive
        }

        guard stopCount(in: ordered) >= 2 else { return .automotive }
        guard let medianSpeed = medianMovingSpeed(in: ordered),
              medianSpeed >= minimumTransitSpeed,
              medianSpeed <= maximumTransitSpeed else { return .automotive }

        return .transit
    }

    /// 对一条已结束的记录执行识别，若判定为公共交通则重标会话与轨迹点。
    static func relabelIfTransit(_ session: ActivitySession) {
        guard session.manualActivityType == nil else { return }
        guard classify(session.trackPoints) == .transit else { return }

        session.activityType = .transit
        for point in session.trackPoints where point.activityType == .automotive {
            point.activityTypeRawValue = ActivityType.transit.rawValue
        }
    }

    private static func stopCount(in points: [TrackPoint]) -> Int {
        var count = 0
        var inStop = false
        var stopStart: Date?

        for point in points {
            if point.activityType == .stationary {
                if !inStop {
                    inStop = true
                    stopStart = point.timestamp
                }
            } else {
                if inStop, let start = stopStart {
                    let duration = point.timestamp.timeIntervalSince(start)
                    if duration >= minimumStopDuration && duration <= maximumStopDuration {
                        count += 1
                    }
                }
                inStop = false
                stopStart = nil
            }
        }
        return count
    }

    private static func medianMovingSpeed(in points: [TrackPoint]) -> Double? {
        let speeds = zip(points, points.dropFirst()).compactMap { pair -> Double? in
            guard pair.0.activityType != .stationary,
                  pair.1.activityType != .stationary else { return nil }
            let interval = pair.1.timestamp.timeIntervalSince(pair.0.timestamp)
            guard interval > 0, interval <= 30 * 60 else { return nil }
            let distance = CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
            return distance / interval
        }.sorted()
        guard !speeds.isEmpty else { return nil }
        return speeds[speeds.count / 2]
    }
}
