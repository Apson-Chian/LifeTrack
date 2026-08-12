import CoreLocation
import Foundation

struct TrajectoryAnalysisResult {
    let anomalyReasons: [UUID: TrackPointAnomalyReason]
    let effectiveDistance: CLLocationDistance
}

enum TrajectoryAnalysisService {
    private static let maximumRunLength = 5
    private static let impossibleSpeed: Double = 55
    private static let detourSpeedThreshold: Double = 45
    private static let boundaryGateSpeed: Double = 20
    private static let nearbyStayRadius: CLLocationDistance = 150
    private static let minimumExcursionDistance: CLLocationDistance = 350
    private static let maximumExcursionDuration: TimeInterval = 10 * 60
    private static let maximumDistanceGap: TimeInterval = 30 * 60

    static func analyze(_ points: [TrackPoint]) -> TrajectoryAnalysisResult {
        let ordered = points.sorted(by: pointOrder)
        var reasons: [UUID: TrackPointAnomalyReason] = [:]

        for point in ordered {
            if !CLLocationCoordinate2DIsValid(point.coordinate) ||
                (point.latitude == 0 && point.longitude == 0) {
                reasons[point.id] = .invalidCoordinate
            } else if point.horizontalAccuracy < 0 || point.horizontalAccuracy > 200 {
                reasons[point.id] = .poorAccuracy
            }
        }

        let candidates = ordered.filter { reasons[$0.id] == nil }
        if candidates.count >= 3 {
            let threshold = adaptiveSpeedThreshold(for: candidates)
            markDisplacedRuns(in: candidates, threshold: threshold, reasons: &reasons)
        }

        return TrajectoryAnalysisResult(
            anomalyReasons: reasons,
            effectiveDistance: effectiveDistance(in: ordered, excluding: Set(reasons.keys))
        )
    }

    static func isPlausibleLeg(from previous: CLLocation, to current: CLLocation) -> Bool {
        let interval = current.timestamp.timeIntervalSince(previous.timestamp)
        guard interval > 0, interval <= maximumDistanceGap else { return false }
        return current.distance(from: previous) / interval <= impossibleSpeed
    }

    private static func markDisplacedRuns(in points: [TrackPoint],
                                          threshold: Double,
                                          reasons: inout [UUID: TrackPointAnomalyReason]) {
        let upperLength = min(maximumRunLength, points.count - 2)
        guard upperLength > 0 else { return }

        for length in 1...upperLength {
            guard points.count >= length + 2 else { continue }
            for start in 0...(points.count - length - 2) {
                let previous = points[start]
                let run = Array(points[(start + 1)...(start + length)])
                let next = points[start + length + 1]

                guard run.allSatisfy({ reasons[$0.id] == nil }) else { continue }
                guard next.timestamp >= previous.timestamp else { continue }

                let entrySpeed = legSpeed(from: previous, to: run[0])
                let exitSpeed = legSpeed(from: run[run.count - 1], to: next)
                let bothLegsImpossible = entrySpeed.map { $0 > threshold } == true &&
                    exitSpeed.map { $0 > threshold } == true
                let detour = detourSpeed(for: run, between: previous, and: next)
                let implausibleDetour = detour > detourSpeedThreshold &&
                    max(entrySpeed ?? 0, exitSpeed ?? 0) > boundaryGateSpeed
                let contradictsStay = contradictsNearbyStay(run: run,
                                                            previous: previous,
                                                            next: next,
                                                            entrySpeed: entrySpeed,
                                                            exitSpeed: exitSpeed)

                guard bothLegsImpossible || implausibleDetour || contradictsStay else { continue }
                let reason: TrackPointAnomalyReason = bothLegsImpossible ? .impossibleJump : .detourSpike
                for point in run {
                    reasons[point.id] = reason
                }
            }
        }
    }

    private static func contradictsNearbyStay(run: [TrackPoint],
                                              previous: TrackPoint,
                                              next: TrackPoint,
                                              entrySpeed: Double?,
                                              exitSpeed: Double?) -> Bool {
        guard previous.distance(to: next) <= nearbyStayRadius else { return false }
        guard let first = run.first, let last = run.last else { return false }
        guard last.timestamp.timeIntervalSince(first.timestamp) <= maximumExcursionDuration else { return false }
        guard previous.distance(to: first) >= minimumExcursionDistance,
              last.distance(to: next) >= minimumExcursionDistance else { return false }
        return max(entrySpeed ?? 0, exitSpeed ?? 0) > boundaryGateSpeed
    }

    private static func detourSpeed(for run: [TrackPoint],
                                    between previous: TrackPoint,
                                    and next: TrackPoint) -> Double {
        guard let first = run.first, let last = run.last else { return 0 }
        let interval = next.timestamp.timeIntervalSince(previous.timestamp)
        guard interval > 0 else {
            return previous.distance(to: first) + last.distance(to: next) > 1_000
                ? .infinity
                : 0
        }
        let viaRun = previous.distance(to: first) + last.distance(to: next)
        let direct = previous.distance(to: next)
        return max(viaRun - direct, 0) / interval
    }

    private static func adaptiveSpeedThreshold(for points: [TrackPoint]) -> Double {
        let normalSpeeds = zip(points, points.dropFirst()).compactMap { pair -> Double? in
            guard let speed = legSpeed(from: pair.0, to: pair.1), speed <= impossibleSpeed else { return nil }
            return speed
        }.sorted()
        guard !normalSpeeds.isEmpty else { return impossibleSpeed }
        let median = normalSpeeds[normalSpeeds.count / 2]
        return max(impossibleSpeed, median * 3)
    }

    private static func effectiveDistance(in points: [TrackPoint],
                                          excluding anomalyIDs: Set<UUID>) -> CLLocationDistance {
        let usable = points.filter { !anomalyIDs.contains($0.id) }
        guard usable.count > 1 else { return 0 }

        var total: CLLocationDistance = 0
        var previous = usable[0]
        for current in usable.dropFirst() {
            let interval = current.timestamp.timeIntervalSince(previous.timestamp)
            guard interval > 0 else { continue }
            if interval <= maximumDistanceGap {
                let distance = previous.distance(to: current)
                if distance / interval <= impossibleSpeed {
                    total += distance
                }
            }
            previous = current
        }
        return total
    }

    private static func legSpeed(from previous: TrackPoint, to current: TrackPoint) -> Double? {
        let interval = current.timestamp.timeIntervalSince(previous.timestamp)
        let distance = previous.distance(to: current)
        guard interval > 0 else { return distance > 1_000 ? .infinity : nil }
        return distance / interval
    }

    private static func pointOrder(_ lhs: TrackPoint, _ rhs: TrackPoint) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private extension TrackPoint {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func distance(to other: TrackPoint) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }
}
