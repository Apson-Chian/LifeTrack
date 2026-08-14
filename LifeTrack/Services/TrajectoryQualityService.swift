import CoreLocation
import Foundation

struct TrajectoryQuality {
    let totalPointCount: Int
    let validPointCount: Int
    let anomalyPointCount: Int
    let anomalyRatio: Double
    let longestLocationGap: TimeInterval
    let averageHorizontalAccuracy: Double
    let maximumHorizontalAccuracy: Double
    let totalDistance: CLLocationDistance
    let effectiveDistance: CLLocationDistance
    let grade: TrajectoryQualityGrade
}

enum TrajectoryQualityGrade: String {
    case excellent
    case good
    case fair
    case poor

    var displayName: String {
        switch self {
        case .excellent: "优秀"
        case .good: "良好"
        case .fair: "一般"
        case .poor: "较差"
        }
    }

    var symbolName: String {
        switch self {
        case .excellent: "checkmark.seal.fill"
        case .good: "checkmark.circle.fill"
        case .fair: "exclamationmark.circle.fill"
        case .poor: "exclamationmark.triangle.fill"
        }
    }
}

enum TrajectoryQualityService {
    static func evaluate(_ session: ActivitySession) -> TrajectoryQuality {
        evaluate(points: session.trackPoints)
    }

    static func evaluate(points: [TrackPoint]) -> TrajectoryQuality {
        let ordered = points.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id.uuidString < $1.id.uuidString
        }
        let valid = ordered.filter(\.isUsableForAnalysis)
        let anomalyCount = ordered.count - valid.count
        let ratio = ordered.isEmpty ? 0 : Double(anomalyCount) / Double(ordered.count)
        let accuracies = ordered.map(\.horizontalAccuracy).filter { $0 >= 0 && $0.isFinite }
        let averageAccuracy = accuracies.isEmpty ? 0 : accuracies.reduce(0, +) / Double(accuracies.count)
        let maximumAccuracy = accuracies.max() ?? 0
        let longestGap = zip(ordered, ordered.dropFirst())
            .map { $1.timestamp.timeIntervalSince($0.timestamp) }
            .filter { $0 > 0 }
            .max() ?? 0
        let rawDistance = distance(in: ordered, validateLegs: false)
        let effectiveDistance = TrajectoryAnalysisService.analyze(ordered).effectiveDistance
        let grade = grade(pointCount: ordered.count,
                          anomalyRatio: ratio,
                          averageAccuracy: averageAccuracy,
                          maximumGap: longestGap)

        return TrajectoryQuality(totalPointCount: ordered.count,
                                 validPointCount: valid.count,
                                 anomalyPointCount: anomalyCount,
                                 anomalyRatio: ratio,
                                 longestLocationGap: longestGap,
                                 averageHorizontalAccuracy: averageAccuracy,
                                 maximumHorizontalAccuracy: maximumAccuracy,
                                 totalDistance: rawDistance,
                                 effectiveDistance: effectiveDistance,
                                 grade: grade)
    }

    private static func grade(pointCount: Int,
                              anomalyRatio: Double,
                              averageAccuracy: Double,
                              maximumGap: TimeInterval) -> TrajectoryQualityGrade {
        guard pointCount >= 3 else { return .poor }
        if pointCount >= 20,
           anomalyRatio <= 0.02,
           averageAccuracy <= 20,
           maximumGap <= 5 * 60 {
            return .excellent
        }
        if anomalyRatio <= 0.08,
           averageAccuracy <= 40,
           maximumGap <= 15 * 60 {
            return .good
        }
        if anomalyRatio <= 0.20,
           averageAccuracy <= 80,
           maximumGap <= 60 * 60 {
            return .fair
        }
        return .poor
    }

    private static func distance(in points: [TrackPoint], validateLegs: Bool) -> CLLocationDistance {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            let interval = pair.1.timestamp.timeIntervalSince(pair.0.timestamp)
            guard interval > 0 else { return total }
            let start = CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
            let end = CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude)
            let distance = start.distance(from: end)
            if validateLegs, distance / interval > 55 { return total }
            return total + distance
        }
    }
}
