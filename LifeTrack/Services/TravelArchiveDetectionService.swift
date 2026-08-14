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
    let reason: String
    let routineSummary: String

    var id: String { sourceFingerprint }
}

/// 在本机用长期活动规律判断旅行。照片不是旅行候选来源，只会在旅行时段确定后，
/// 通过拍摄时间和本机 GPS 核对是否属于该段旅行；图像内容不参与判断。
enum TravelArchiveDetectionService {
    private static let awayFromRoutineThreshold: CLLocationDistance = 50_000
    private static let minimumTravelDistance: CLLocationDistance = 5_000
    private static let minimumRemoteStay: TimeInterval = 30 * 60

    static func suggestions(photos: [PhotoAnalysisRecord],
                            sessions: [ActivitySession],
                            stays: [StayRecord],
                            places: [CustomPlace],
                            timelineNodes: [TravelTimelineNode],
                            confirmed: [TravelArchiveRecord],
                            calendar: Calendar = .current) -> [TravelArchiveSuggestion] {
        let eligibleSessions = sessions.filter { !$0.isActive }
        let profile = routineProfile(places: places, stays: stays)
        guard !profile.anchors.isEmpty else { return [] }

        // 照片不产生候选日期，避免“有照片 = 去旅行”。
        let days = candidateDays(sessions: eligibleSessions, stays: stays, calendar: calendar)
        let travelDays = days.filter { day in
            let value = evidence(for: day,
                                 sessions: eligibleSessions,
                                 stays: stays,
                                 anchors: profile.anchors,
                                 calendar: calendar)
            return value.maximumDistanceFromRoutine >= awayFromRoutineThreshold &&
                (value.remoteStayCount > 0 || value.remoteCoordinateCount >= 3) &&
                (value.totalDistance >= minimumTravelDistance || value.remoteStayDuration >= minimumRemoteStay)
        }
        let confirmedKeys = Set(confirmed.map(\.sourceFingerprint))

        return consecutiveGroups(travelDays, calendar: calendar).compactMap { group in
            guard let first = group.first, let last = group.last,
                  let broadEnd = calendar.date(byAdding: .day, value: 1,
                                               to: calendar.startOfDay(for: last)) else { return nil }
            let broadStart = calendar.startOfDay(for: first)
            let broadClosedEnd = broadEnd.addingTimeInterval(-1)
            let groupSessions = eligibleSessions.filter {
                effectiveEnd(of: $0) >= broadStart && $0.startTime <= broadClosedEnd
            }
            let groupStays = stays.filter {
                effectiveEnd(of: $0) >= broadStart && $0.arrivalTime <= broadClosedEnd
            }
            let remoteSessions = groupSessions.filter {
                sampledCoordinates(of: $0).filter { isRemote($0, from: profile.anchors) }.count >= 3
            }
            let remoteStays = groupStays.filter {
                isRemote(.init(latitude: $0.latitude, longitude: $0.longitude), from: profile.anchors)
            }
            guard !remoteSessions.isEmpty || !remoteStays.isEmpty else { return nil }

            let starts = remoteSessions.map(\.startTime) + remoteStays.map(\.arrivalTime)
            let ends = remoteSessions.map(effectiveEnd(of:)) + remoteStays.map(effectiveEnd(of:))
            guard let start = starts.min(), let end = ends.max() else { return nil }

            // 只附加旅行实际时段内的照片；有 GPS 的照片还必须位于日常活动圈之外。
            let relevantPhotos = photos.filter { photo in
                guard photo.creationDate >= start && photo.creationDate <= end else { return false }
                guard let coordinate = coordinate(of: photo) else { return true }
                return isRemote(coordinate, from: profile.anchors)
            }
            let relevantNodes = timelineNodes.filter { $0.endTime >= start && $0.startTime <= end }
            let fingerprint = fingerprint(start: start,
                                          end: end,
                                          photos: relevantPhotos,
                                          sessions: remoteSessions,
                                          calendar: calendar)
            guard !confirmedKeys.contains(fingerprint) else { return nil }

            let placeNames = mainPlaceNames(nodes: relevantNodes,
                                            stays: remoteStays,
                                            places: places,
                                            excludedNames: profile.names)
            let remoteCoordinates = remoteSessions.flatMap(sampledCoordinates(of:)) +
                remoteStays.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            let placeCount = max(placeNames.count, coordinateClusterCount(remoteCoordinates))
            let totalDistance = remoteSessions.reduce(0) { $0 + $1.distance }
            let maxDistance = remoteCoordinates.map { nearestDistance($0, to: profile.anchors) }.max() ?? 0
            let reason = "已排除\(profile.summary)，最远离日常活动圈 \(Formatters.distance(maxDistance))，包含 \(remoteStays.count) 段异地停留和 \(remoteSessions.count) 段异地轨迹"
            let title = placeNames.first.map { "\(shortPlaceName($0))旅行" } ?? "异地旅行"

            return TravelArchiveSuggestion(sourceFingerprint: fingerprint,
                                           title: title,
                                           startTime: start,
                                           endTime: end,
                                           photoCount: relevantPhotos.count,
                                           placeCount: placeCount,
                                           totalDistance: totalDistance,
                                           mainPlaces: Array(placeNames.prefix(4)),
                                           reason: reason,
                                           routineSummary: profile.summary)
        }
        .sorted { $0.startTime > $1.startTime }
    }

    static func routineSummary(places: [CustomPlace], stays: [StayRecord]) -> String {
        routineProfile(places: places, stays: stays).summary
    }

    /// 供旅行时间轴在本机判断历史照片是否明显离开家、学校或长期高频地点。
    static func routineAnchors(places: [CustomPlace], stays: [StayRecord]) -> [CLLocationCoordinate2D] {
        routineProfile(places: places, stays: stays).anchors
    }

    private static func candidateDays(sessions: [ActivitySession],
                                      stays: [StayRecord],
                                      calendar: Calendar) -> [Date] {
        var values = Set(sessions.map { calendar.startOfDay(for: $0.startTime) })
        values.formUnion(stays.map { calendar.startOfDay(for: $0.arrivalTime) })
        return values.sorted()
    }

    private static func evidence(for day: Date,
                                 sessions: [ActivitySession],
                                 stays: [StayRecord],
                                 anchors: [CLLocationCoordinate2D],
                                 calendar: Calendar) -> DayEvidence {
        let daySessions = sessions.filter { calendar.isDate($0.startTime, inSameDayAs: day) }
        let dayStays = stays.filter { calendar.isDate($0.arrivalTime, inSameDayAs: day) }
        let coordinates = daySessions.flatMap(sampledCoordinates(of:)) +
            dayStays.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let distances = coordinates.map { nearestDistance($0, to: anchors) }
        let remoteStays = dayStays.filter {
            isRemote(.init(latitude: $0.latitude, longitude: $0.longitude), from: anchors)
        }
        return DayEvidence(totalDistance: daySessions.reduce(0) { $0 + $1.distance },
                           maximumDistanceFromRoutine: distances.max() ?? 0,
                           remoteCoordinateCount: distances.filter { $0 >= awayFromRoutineThreshold }.count,
                           remoteStayCount: remoteStays.count,
                           remoteStayDuration: remoteStays.reduce(0) { $0 + $1.duration })
    }

    private static func routineProfile(places: [CustomPlace], stays: [StayRecord]) -> RoutineProfile {
        let counts = Dictionary(grouping: stays.compactMap(\.customPlaceID), by: { $0 }).mapValues(\.count)
        let anchoredPlaces = places.filter { place in
            place.category == .accommodation || place.category == .study || (counts[place.id] ?? 0) >= 3
        }
        .sorted {
            let leftRank = ($0.category == .accommodation ? 3 : $0.category == .study ? 2 : 1,
                            counts[$0.id] ?? 0)
            let rightRank = ($1.category == .accommodation ? 3 : $1.category == .study ? 2 : 1,
                             counts[$1.id] ?? 0)
            return leftRank > rightRank
        }

        var anchors = anchoredPlaces.prefix(6).map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        var names = Set(anchoredPlaces.prefix(6).map(\.shortName))

        // 尚未维护自定义地点时，从至少出现 3 次的停留簇中推断日常活动圈，仍只在本机使用。
        if anchors.isEmpty {
            let clusters = Dictionary(grouping: stays) { stay in
                "\(Int((stay.latitude * 1_000).rounded())):\(Int((stay.longitude * 1_000).rounded()))"
            }
            for cluster in clusters.values.sorted(by: { $0.count > $1.count }).prefix(3) where cluster.count >= 3 {
                let latitude = cluster.reduce(0) { $0 + $1.latitude } / Double(cluster.count)
                let longitude = cluster.reduce(0) { $0 + $1.longitude } / Double(cluster.count)
                anchors.append(.init(latitude: latitude, longitude: longitude))
                if let name = cluster.compactMap(\.detectedName).first { names.insert(name) }
            }
        }

        let categoryNames = anchoredPlaces.prefix(6).map { place in
            if place.category == .accommodation { return "家/宿舍" }
            if place.category == .study { return "学校/学习地点" }
            return place.shortName
        }
        let summary = categoryNames.isEmpty
            ? (anchors.isEmpty ? "尚未形成稳定日常活动圈" : "长期高频停留区域")
            : Array(Set(categoryNames)).sorted().joined(separator: "、")
        return RoutineProfile(anchors: anchors, names: names, summary: summary)
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
                                       places: [CustomPlace],
                                       excludedNames: Set<String>) -> [String] {
        var ordered: [String] = []
        func append(_ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, !excludedNames.contains(value), !ordered.contains(value) else { return }
            ordered.append(value)
        }
        for stay in stays.sorted(by: { $0.duration > $1.duration }) {
            append(stay.detectedName)
            if let id = stay.customPlaceID { append(places.first { $0.id == id }?.shortName) }
        }
        for node in nodes.sorted(by: { $0.startTime < $1.startTime }) {
            append(node.placeName)
            append(node.endPlaceName)
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
        let ordered = session.trackPoints.filter(\.isUsableForAnalysis).sorted { $0.timestamp < $1.timestamp }
        guard !ordered.isEmpty else { return [] }
        let step = max(1, ordered.count / 100)
        return Swift.stride(from: 0, to: ordered.count, by: step).map {
            CLLocationCoordinate2D(latitude: ordered[$0].latitude, longitude: ordered[$0].longitude)
        }
    }

    private static func nearestDistance(_ coordinate: CLLocationCoordinate2D,
                                        to anchors: [CLLocationCoordinate2D]) -> CLLocationDistance {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return anchors.map { location.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) }.min() ?? 0
    }

    private static func isRemote(_ coordinate: CLLocationCoordinate2D,
                                 from anchors: [CLLocationCoordinate2D]) -> Bool {
        nearestDistance(coordinate, to: anchors) >= awayFromRoutineThreshold
    }

    private static func coordinateClusterCount(_ coordinates: [CLLocationCoordinate2D]) -> Int {
        Set(coordinates.map { "\(Int(($0.latitude * 100).rounded())),\(Int(($0.longitude * 100).rounded()))" }).count
    }

    private static func fingerprint(start: Date,
                                    end: Date,
                                    photos: [PhotoAnalysisRecord],
                                    sessions: [ActivitySession],
                                    calendar: Calendar) -> String {
        let startParts = calendar.dateComponents([.year, .month, .day], from: start)
        let endParts = calendar.dateComponents([.year, .month, .day], from: end)
        let sessionKey = sessions.map(\.id.uuidString).sorted().joined(separator: ",")
        let photoKey = photos.map(\.assetIdentifier).sorted().prefix(10).joined(separator: ",")
        return "travel-v2-\(startParts.year ?? 0)-\(startParts.month ?? 0)-\(startParts.day ?? 0)-\(endParts.year ?? 0)-\(endParts.month ?? 0)-\(endParts.day ?? 0)-\(sessionKey)-\(photoKey)"
    }

    private static func effectiveEnd(of session: ActivitySession) -> Date {
        session.endTime ?? session.trackPoints.map(\.timestamp).max() ?? session.startTime
    }

    private static func effectiveEnd(of stay: StayRecord) -> Date {
        stay.departureTime ?? stay.arrivalTime.addingTimeInterval(stay.duration)
    }

    private static func shortPlaceName(_ value: String) -> String {
        value.components(separatedBy: CharacterSet(charactersIn: "，,·-"))
            .first?.trimmingCharacters(in: .whitespaces) ?? value
    }
}

private struct RoutineProfile {
    let anchors: [CLLocationCoordinate2D]
    let names: Set<String>
    let summary: String
}

private struct DayEvidence {
    let totalDistance: CLLocationDistance
    let maximumDistanceFromRoutine: CLLocationDistance
    let remoteCoordinateCount: Int
    let remoteStayCount: Int
    let remoteStayDuration: TimeInterval
}
