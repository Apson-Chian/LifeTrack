import CoreLocation
import Foundation

struct TravelArchiveSuggestion: Identifiable {
    let sourceFingerprint: String
    let title: String
    let startTime: Date
    let endTime: Date
    let photoCount: Int
    let placeCount: Int
    let totalDistance: Double
    let mainPlaces: [String]

    var id: String { sourceFingerprint }
}

enum TravelArchiveDetectionService {
    /// 只有当某天最远点离“家”超过该距离时，才可能算作旅行，避免把日常通勤/同城活动当旅行。
    private static let awayFromHomeThreshold: CLLocationDistance = 50_000

    static func suggestions(photos: [PhotoAnalysisRecord],
                            sessions: [ActivitySession],
                            stays: [StayRecord],
                            places: [CustomPlace],
                            timelineNodes: [TravelTimelineNode],
                            confirmed: [TravelArchiveRecord],
                            calendar: Calendar = .current) -> [TravelArchiveSuggestion] {
        let eligibleSessions = sessions.filter { !$0.isActive }
        let anchor = homeAnchor(places: places, stays: stays)
        // 没有“家”的锚点就无法区分“日常出行”与“异地旅行”，保守起见不推荐。
        guard anchor != nil else { return [] }
        let days = candidateDays(photos: photos,
                                 sessions: eligibleSessions,
                                 stays: stays,
                                 calendar: calendar)
        let travelDays = days.filter { day in
            let evidence = evidence(for: day,
                                    photos: photos,
                                    sessions: eligibleSessions,
                                    stays: stays,
                                    anchor: anchor,
                                    calendar: calendar)
            return evidence.maximumDistanceFromHome >= awayFromHomeThreshold &&
                (evidence.photoCount >= 2 || evidence.totalDistance >= 5_000)
        }
        let groups = consecutiveGroups(travelDays, calendar: calendar)
        let confirmedKeys = Set(confirmed.map(\.sourceFingerprint))

        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            let start = calendar.startOfDay(for: first)
            guard let dayAfterEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last)) else {
                return nil
            }
            let end = dayAfterEnd.addingTimeInterval(-1)
            let relevantPhotos = photos.filter { $0.creationDate >= start && $0.creationDate <= end }
            let relevantSessions = eligibleSessions.filter {
                effectiveEnd(of: $0) >= start && $0.startTime <= end
            }
            let relevantStays = stays.filter {
                let stayEnd = $0.departureTime ?? $0.arrivalTime.addingTimeInterval($0.duration)
                return stayEnd >= start && $0.arrivalTime <= end
            }
            let relevantNodes = timelineNodes.filter { $0.endTime >= start && $0.startTime <= end }
            let fingerprint = fingerprint(start: start,
                                          end: end,
                                          photos: relevantPhotos,
                                          sessions: relevantSessions,
                                          calendar: calendar)
            guard !confirmedKeys.contains(fingerprint) else { return nil }

            let placeNames = mainPlaceNames(nodes: relevantNodes,
                                            stays: relevantStays,
                                            places: places)
            let coordinates = relevantPhotos.compactMap(coordinate(of:)) +
                relevantSessions.flatMap { sampledCoordinates(of: $0) } +
                relevantStays.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            let placeCount = max(placeNames.count, coordinateClusterCount(coordinates))
            let totalDistance = relevantSessions.reduce(0) { $0 + $1.distance }
            let title = placeNames.first.map { "\(shortPlaceName($0))旅行" } ?? "异地旅行"

            return TravelArchiveSuggestion(sourceFingerprint: fingerprint,
                                           title: title,
                                           startTime: start,
                                           endTime: end,
                                           photoCount: relevantPhotos.count,
                                           placeCount: placeCount,
                                           totalDistance: totalDistance,
                                           mainPlaces: Array(placeNames.prefix(4)))
        }
        .sorted { $0.startTime > $1.startTime }
    }

    private static func candidateDays(photos: [PhotoAnalysisRecord],
                                      sessions: [ActivitySession],
                                      stays: [StayRecord],
                                      calendar: Calendar) -> [Date] {
        var values = Set(photos.map { calendar.startOfDay(for: $0.creationDate) })
        values.formUnion(sessions.map { calendar.startOfDay(for: $0.startTime) })
        values.formUnion(stays.map { calendar.startOfDay(for: $0.arrivalTime) })
        return values.sorted()
    }

    private static func evidence(for day: Date,
                                 photos: [PhotoAnalysisRecord],
                                 sessions: [ActivitySession],
                                 stays: [StayRecord],
                                 anchor: CLLocationCoordinate2D?,
                                 calendar: Calendar) -> DayEvidence {
        let dayPhotos = photos.filter { calendar.isDate($0.creationDate, inSameDayAs: day) }
        let daySessions = sessions.filter { calendar.isDate($0.startTime, inSameDayAs: day) }
        let dayStays = stays.filter { calendar.isDate($0.arrivalTime, inSameDayAs: day) }
        let coordinates = dayPhotos.compactMap(coordinate(of:)) +
            daySessions.flatMap { sampledCoordinates(of: $0) } +
            dayStays.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let maximumDistanceFromHome: CLLocationDistance
        if let anchor {
            let home = CLLocation(latitude: anchor.latitude, longitude: anchor.longitude)
            maximumDistanceFromHome = coordinates.map {
                home.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
            }.max() ?? 0
        } else {
            maximumDistanceFromHome = 0
        }
        return DayEvidence(photoCount: dayPhotos.count,
                           totalDistance: daySessions.reduce(0) { $0 + $1.distance },
                           geographicSpan: geographicSpan(coordinates),
                           maximumDistanceFromHome: maximumDistanceFromHome)
    }

    private static func homeAnchor(places: [CustomPlace],
                                   stays: [StayRecord]) -> CLLocationCoordinate2D? {
        if let accommodation = places
            .filter({ $0.category == .accommodation })
            .sorted(by: { ($0.isFavorite ? 1 : 0) > ($1.isFavorite ? 1 : 0) })
            .first {
            return CLLocationCoordinate2D(latitude: accommodation.latitude,
                                          longitude: accommodation.longitude)
        }
        let counts = Dictionary(grouping: stays.compactMap(\.customPlaceID), by: { $0 })
            .mapValues(\.count)
        if let frequentID = counts.max(by: { $0.value < $1.value })?.key,
           let frequent = places.first(where: { $0.id == frequentID }) {
            return CLLocationCoordinate2D(latitude: frequent.latitude, longitude: frequent.longitude)
        }
        return nil
    }

    private static func consecutiveGroups(_ days: [Date], calendar: Calendar) -> [[Date]] {
        var groups: [[Date]] = []
        for day in days.sorted() {
            if let previous = groups.last?.last,
               calendar.dateComponents([.day], from: previous, to: day).day == 1 {
                groups[groups.count - 1].append(day)
            } else {
                groups.append([day])
            }
        }
        return groups
    }

    private static func mainPlaceNames(nodes: [TravelTimelineNode],
                                       stays: [StayRecord],
                                       places: [CustomPlace]) -> [String] {
        var ordered: [String] = []
        func append(_ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  !ordered.contains(value) else { return }
            ordered.append(value)
        }
        for node in nodes.sorted(by: { $0.startTime < $1.startTime }) {
            append(node.placeName)
            append(node.endPlaceName)
        }
        for stay in stays.sorted(by: { $0.duration > $1.duration }) {
            append(stay.detectedName)
            if let id = stay.customPlaceID {
                append(places.first(where: { $0.id == id })?.shortName)
            }
        }
        return ordered
    }

    private static func coordinate(of photo: PhotoAnalysisRecord) -> CLLocationCoordinate2D? {
        guard let latitude = photo.originalLatitude ?? photo.latitude,
              let longitude = photo.originalLongitude ?? photo.longitude else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    private static func sampledCoordinates(of session: ActivitySession) -> [CLLocationCoordinate2D] {
        let ordered = session.trackPoints
            .filter(\.isUsableForAnalysis)
            .sorted { $0.timestamp < $1.timestamp }
        guard !ordered.isEmpty else { return [] }
        let strideValue = max(1, ordered.count / 100)
        return Swift.stride(from: 0, to: ordered.count, by: strideValue).map {
            CLLocationCoordinate2D(latitude: ordered[$0].latitude, longitude: ordered[$0].longitude)
        }
    }

    private static func geographicSpan(_ coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
        guard let first = coordinates.first else { return 0 }
        let extremes = [
            coordinates.min(by: { $0.latitude < $1.latitude }),
            coordinates.max(by: { $0.latitude < $1.latitude }),
            coordinates.min(by: { $0.longitude < $1.longitude }),
            coordinates.max(by: { $0.longitude < $1.longitude })
        ].compactMap { $0 }
        let origin = CLLocation(latitude: first.latitude, longitude: first.longitude)
        return extremes.map {
            origin.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
        }.max() ?? 0
    }

    private static func coordinateClusterCount(_ coordinates: [CLLocationCoordinate2D]) -> Int {
        Set(coordinates.map {
            "\(Int(($0.latitude * 100).rounded())),\(Int(($0.longitude * 100).rounded()))"
        }).count
    }

    private static func fingerprint(start: Date,
                                    end: Date,
                                    photos: [PhotoAnalysisRecord],
                                    sessions: [ActivitySession],
                                    calendar: Calendar) -> String {
        let dayStart = calendar.dateComponents([.year, .month, .day], from: start)
        let dayEnd = calendar.dateComponents([.year, .month, .day], from: end)
        let sessionKey = sessions.map(\.id.uuidString).sorted().joined(separator: ",")
        let photoKey = photos.map(\.assetIdentifier).sorted().prefix(10).joined(separator: ",")
        return "travel-v1-\(dayStart.year ?? 0)-\(dayStart.month ?? 0)-\(dayStart.day ?? 0)-\(dayEnd.year ?? 0)-\(dayEnd.month ?? 0)-\(dayEnd.day ?? 0)-\(sessionKey)-\(photoKey)"
    }

    private static func effectiveEnd(of session: ActivitySession) -> Date {
        session.endTime ?? session.trackPoints.map(\.timestamp).max() ?? session.startTime
    }

    private static func shortPlaceName(_ value: String) -> String {
        let separators = CharacterSet(charactersIn: "，,·-")
        return value.components(separatedBy: separators).first?.trimmingCharacters(in: .whitespaces) ?? value
    }
}

private struct DayEvidence {
    let photoCount: Int
    let totalDistance: CLLocationDistance
    let geographicSpan: CLLocationDistance
    let maximumDistanceFromHome: CLLocationDistance
}
