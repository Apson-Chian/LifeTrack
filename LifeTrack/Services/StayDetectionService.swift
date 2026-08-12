import CoreLocation
import Foundation
import SwiftData

struct DetectedStay {
    let center: CLLocationCoordinate2D
    let arrival: Date
    let departure: Date
    let radius: CLLocationDistance
    let pointCount: Int
    let confidence: Double
    let place: CustomPlace?
}

enum StayDetectionService {
    private static let stayRadius: CLLocationDistance = 80
    private static let driftCap: CLLocationDistance = 120
    private static let sweepGap: TimeInterval = 60 * 60
    private static let bridgeGap: TimeInterval = 6 * 60 * 60
    private static let minimumDuration: TimeInterval = 5 * 60
    private static let minimumPointCount = 3

    static func detect(points: [TrackPoint], places: [CustomPlace]) -> [DetectedStay] {
        let ordered = points
            .filter(\.isUsableForAnalysis)
            .sorted { $0.timestamp < $1.timestamp }
        guard ordered.count >= minimumPointCount else { return [] }

        let fragments = bridgeSamePlaceFragments(sweep(ordered))
        return fragments.compactMap { fragment in
            guard fragment.duration >= minimumDuration,
                  fragment.points.count >= minimumPointCount else { return nil }

            let stationaryFraction = Double(fragment.points.filter { $0.activityType == .stationary }.count) /
                Double(fragment.points.count)
            guard stationaryFraction >= 0.25 || fragment.duration >= 15 * 60 else { return nil }

            let center = fragment.center
            let radius = max(15, fragment.points.map { $0.distance(to: center) }.max() ?? 15)
            let matchingPlace = places
                .filter { $0.distance(to: center) <= max($0.radius, 60) }
                .min { $0.distance(to: center) < $1.distance(to: center) }

            return DetectedStay(center: center,
                                arrival: fragment.start,
                                departure: fragment.end,
                                radius: radius,
                                pointCount: fragment.points.count,
                                confidence: confidence(for: fragment,
                                                       radius: radius,
                                                       stationaryFraction: stationaryFraction,
                                                       hasPlaceMatch: matchingPlace != nil),
                                place: matchingPlace)
        }
    }

    static func rebuildRecords(for session: ActivitySession,
                               places: [CustomPlace],
                               in context: ModelContext) {
        let detected = detect(points: session.trackPoints, places: places)
        for record in session.stayRecords {
            context.delete(record)
        }

        for stay in detected {
            let record = StayRecord(customPlaceID: stay.place?.id,
                                    detectedName: stay.place?.shortName ?? "未命名停留",
                                    latitude: stay.center.latitude,
                                    longitude: stay.center.longitude,
                                    arrivalTime: stay.arrival,
                                    radius: stay.radius,
                                    pointCount: stay.pointCount,
                                    confidence: stay.confidence,
                                    source: .automaticDetection,
                                    session: session)
            record.departureTime = stay.departure
            record.duration = stay.departure.timeIntervalSince(stay.arrival)
            context.insert(record)
        }
    }

    private static func sweep(_ points: [TrackPoint]) -> [StayFragment] {
        var fragments: [StayFragment] = []
        var open: StayFragment?

        for point in points {
            guard var current = open else {
                open = StayFragment(first: point)
                continue
            }

            let gap = point.timestamp.timeIntervalSince(current.end)
            if gap > sweepGap || !current.canInclude(point, radius: stayRadius, driftCap: driftCap) {
                fragments.append(current)
                open = StayFragment(first: point)
            } else {
                current.add(point)
                open = current
            }
        }
        if let open { fragments.append(open) }
        return fragments
    }

    private static func bridgeSamePlaceFragments(_ fragments: [StayFragment]) -> [StayFragment] {
        var merged: [StayFragment] = []
        for fragment in fragments {
            guard var previous = merged.last else {
                merged.append(fragment)
                continue
            }

            let gap = fragment.start.timeIntervalSince(previous.end)
            if gap <= bridgeGap && previous.center.distance(to: fragment.center) <= stayRadius {
                previous.merge(fragment)
                merged[merged.count - 1] = previous
            } else {
                merged.append(fragment)
            }
        }
        return merged
    }

    private static func confidence(for fragment: StayFragment,
                                   radius: CLLocationDistance,
                                   stationaryFraction: Double,
                                   hasPlaceMatch: Bool) -> Double {
        let durationScore = min(fragment.duration / (30 * 60), 1)
        let pointScore = min(Double(fragment.points.count) / 8, 1)
        let compactnessScore = max(0, 1 - radius / (stayRadius * 1.5))
        let accuracyValues = fragment.points.map(\.horizontalAccuracy).filter { $0 >= 0 }
        let meanAccuracy = accuracyValues.isEmpty ? 100 : accuracyValues.reduce(0, +) / Double(accuracyValues.count)
        let accuracyScore = max(0, 1 - meanAccuracy / 150)
        let placeBonus = hasPlaceMatch ? 0.08 : 0

        return min(1,
                   durationScore * 0.28 +
                   pointScore * 0.22 +
                   compactnessScore * 0.2 +
                   accuracyScore * 0.14 +
                   stationaryFraction * 0.16 +
                   placeBonus)
    }
}

private struct StayFragment {
    private(set) var points: [TrackPoint]
    private var weightedLatitude: Double
    private var weightedLongitude: Double
    private var totalWeight: Double
    private let reference: CLLocationCoordinate2D

    var start: Date { points[0].timestamp }
    var end: Date { points[points.count - 1].timestamp }
    var duration: TimeInterval { end.timeIntervalSince(start) }
    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: weightedLatitude / totalWeight,
                               longitude: weightedLongitude / totalWeight)
    }

    init(first: TrackPoint) {
        let weight = Self.weight(for: first)
        points = [first]
        weightedLatitude = first.latitude * weight
        weightedLongitude = first.longitude * weight
        totalWeight = weight
        reference = CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude)
    }

    func canInclude(_ point: TrackPoint,
                    radius: CLLocationDistance,
                    driftCap: CLLocationDistance) -> Bool {
        let coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        return center.distance(to: coordinate) <= radius && reference.distance(to: coordinate) <= driftCap
    }

    mutating func add(_ point: TrackPoint) {
        let weight = Self.weight(for: point)
        points.append(point)
        weightedLatitude += point.latitude * weight
        weightedLongitude += point.longitude * weight
        totalWeight += weight
    }

    mutating func merge(_ other: StayFragment) {
        points.append(contentsOf: other.points)
        weightedLatitude += other.weightedLatitude
        weightedLongitude += other.weightedLongitude
        totalWeight += other.totalWeight
    }

    private static func weight(for point: TrackPoint) -> Double {
        1 / max(point.horizontalAccuracy, 5)
    }
}

private extension TrackPoint {
    func distance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }
}

private extension CustomPlace {
    func distance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }
}

private extension CLLocationCoordinate2D {
    func distance(to other: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }
}
