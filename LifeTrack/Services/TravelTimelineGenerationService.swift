import Foundation
import SwiftData
import CoreLocation
import Photos

struct TravelTimelineRefreshSummary {
    let tripCount: Int
    let updatedTripCount: Int
    let analyzedPhotoCount: Int
}

@MainActor
enum TravelTimelineGenerationService {
    static func refresh(context: ModelContext,
                        sessions: [ActivitySession]) async -> TravelTimelineRefreshSummary {
        let analyzedPhotoCount = await updatePhotoCache(context: context, sessions: sessions)
        let photoRecords = (try? context.fetch(FetchDescriptor<PhotoAnalysisRecord>())) ?? []
        let input = TimelineGenerationInput(sessions: sessions, photos: photoRecords)
        let drafts = await Task.detached(priority: .utility) {
            TravelTimelineDraftBuilder.build(input)
        }.value

        let updatedTripCount = reconcile(drafts: drafts, in: context)
        try? context.save()
        await resolveMissingPlaceNames(in: context)

        return TravelTimelineRefreshSummary(tripCount: drafts.count,
                                            updatedTripCount: updatedTripCount,
                                            analyzedPhotoCount: analyzedPhotoCount)
    }

    private static func updatePhotoCache(context: ModelContext,
                                         sessions: [ActivitySession]) async -> Int {
        let status = await photoAuthorizationStatus()
        guard status == .authorized || status == .limited else { return 0 }

        let descriptors = await Task.detached(priority: .utility) {
            PhotoLibraryScanner.descriptors()
        }.value
        let records = (try? context.fetch(FetchDescriptor<PhotoAnalysisRecord>())) ?? []
        var recordByIdentifier = Dictionary(uniqueKeysWithValues: records.map { ($0.assetIdentifier, $0) })
        let sessionSnapshots = PhotoTrackAssociationService.snapshots(from: sessions)
        let availableIdentifiers = Set(descriptors.map(\.id))

        if status == .authorized {
            for record in records where !availableIdentifiers.contains(record.assetIdentifier) {
                context.delete(record)
                recordByIdentifier.removeValue(forKey: record.assetIdentifier)
            }
        }

        var analyzedCount = 0
        for descriptor in descriptors {
            let linkedSessionID = PhotoTrackAssociationService.bestSessionID(for: descriptor,
                                                                              sessions: sessionSnapshots)
            if let cached = recordByIdentifier[descriptor.id] {
                cached.linkedSessionID = linkedSessionID
                continue
            }
            guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { continue }

            let result = await PhotoVisionAnalysisService.analyze(descriptor)
            let record = PhotoAnalysisRecord(assetIdentifier: descriptor.id,
                                             creationDate: descriptor.creationDate,
                                             latitude: descriptor.displayLatitude,
                                             longitude: descriptor.displayLongitude,
                                             originalLatitude: descriptor.originalLatitude,
                                             originalLongitude: descriptor.originalLongitude,
                                             categories: result.categories,
                                             topLabels: result.topLabels,
                                             confidence: result.confidence,
                                             faceCount: result.faceCount,
                                             state: result.state,
                                             linkedSessionID: linkedSessionID)
            context.insert(record)
            recordByIdentifier[descriptor.id] = record
            analyzedCount += 1
            if analyzedCount % 10 == 0 {
                try? context.save()
                await Task.yield()
            }
        }
        try? context.save()
        return analyzedCount
    }

    private static func photoAuthorizationStatus() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    private static func reconcile(drafts: [TravelTimelineTripDraft],
                                  in context: ModelContext) -> Int {
        let existingTrips = (try? context.fetch(FetchDescriptor<TravelTimelineTrip>())) ?? []
        var existingByKey = Dictionary(uniqueKeysWithValues: existingTrips.map { ($0.stableKey, $0) })
        var updatedCount = 0

        for draft in drafts {
            let trip: TravelTimelineTrip
            if let existing = existingByKey.removeValue(forKey: draft.stableKey) {
                trip = existing
                guard trip.sourceFingerprint != draft.sourceFingerprint else { continue }
                trip.update(title: draft.title,
                            startTime: draft.startTime,
                            endTime: draft.endTime,
                            totalDistance: draft.totalDistance,
                            sourceFingerprint: draft.sourceFingerprint,
                            routePoints: draft.routePoints)
            } else {
                trip = TravelTimelineTrip(stableKey: draft.stableKey,
                                          title: draft.title,
                                          startTime: draft.startTime,
                                          endTime: draft.endTime,
                                          totalDistance: draft.totalDistance,
                                          sourceFingerprint: draft.sourceFingerprint,
                                          routePoints: draft.routePoints)
                context.insert(trip)
            }

            reconcile(nodes: draft.nodes, for: trip, in: context)
            updatedCount += 1
        }

        for staleTrip in existingByKey.values {
            context.delete(staleTrip)
        }
        return updatedCount + existingByKey.count
    }

    private static func reconcile(nodes drafts: [TravelTimelineNodeDraft],
                                  for trip: TravelTimelineTrip,
                                  in context: ModelContext) {
        var existingByKey: [String: [TravelTimelineNode]] = Dictionary(grouping: trip.nodes,
                                                                        by: \.stableKey)
        for draft in drafts {
            let node: TravelTimelineNode
            if var matches = existingByKey[draft.stableKey], let existing = matches.first {
                node = existing
                matches.removeFirst()
                existingByKey[draft.stableKey] = matches
                node.update(kind: draft.kind,
                            startTime: draft.startTime,
                            endTime: draft.endTime,
                            coordinate: draft.coordinate,
                            endCoordinate: draft.endCoordinate,
                            distance: draft.distance,
                            activityType: draft.activityType,
                            photoIdentifiers: draft.photoIdentifiers,
                            categories: draft.categories)
            } else {
                node = TravelTimelineNode(stableKey: draft.stableKey,
                                          kind: draft.kind,
                                          startTime: draft.startTime,
                                          endTime: draft.endTime,
                                          coordinate: draft.coordinate,
                                          endCoordinate: draft.endCoordinate,
                                          distance: draft.distance,
                                          activityType: draft.activityType,
                                          photoIdentifiers: draft.photoIdentifiers,
                                          categories: draft.categories,
                                          trip: trip)
                context.insert(node)
            }
        }

        for staleNode in existingByKey.values.flatMap({ $0 }) {
            context.delete(staleNode)
        }
    }

    private static func resolveMissingPlaceNames(in context: ModelContext) async {
        let nodes = (try? context.fetch(FetchDescriptor<TravelTimelineNode>())) ?? []
        let geocoder = GeocodingService()
        var cache: [String: String] = [:]
        var resolvedCount = 0

        for node in nodes.sorted(by: { $0.startTime > $1.startTime }) {
            guard !Task.isCancelled else { break }
            if node.placeName == nil {
                let key = coordinateKey(node.coordinate)
                if let cached = cache[key] {
                    node.placeName = cached
                } else if let name = await geocoder.reverseGeocode(node.coordinate), !name.isEmpty {
                    node.placeName = name
                    cache[key] = name
                }
                resolvedCount += 1
            }
            if node.kind == .movement, node.endPlaceName == nil, let end = node.endingCoordinate {
                let key = coordinateKey(end)
                if let cached = cache[key] {
                    node.endPlaceName = cached
                } else if let name = await geocoder.reverseGeocode(end), !name.isEmpty {
                    node.endPlaceName = name
                    cache[key] = name
                }
                resolvedCount += 1
            }
            if resolvedCount > 0, resolvedCount % 8 == 0 { try? context.save() }
        }
        try? context.save()
    }

    private static func coordinateKey(_ coordinate: CLLocationCoordinate2D) -> String {
        "\(Int((coordinate.latitude * 10_000).rounded())):\(Int((coordinate.longitude * 10_000).rounded()))"
    }
}

private struct TimelineGenerationInput: Sendable {
    let sessions: [TimelineSessionSnapshot]
    let photos: [TimelinePhotoSnapshot]

    @MainActor
    init(sessions: [ActivitySession], photos: [PhotoAnalysisRecord]) {
        self.sessions = sessions.compactMap { session in
            let points = session.trackPoints
                .filter { $0.isUsableForAnalysis && $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 200 }
                .sorted { $0.timestamp < $1.timestamp }
                .map(TimelineTrackPointSnapshot.init)
            let fallbackEnd = points.last?.timestamp ?? session.startTime.addingTimeInterval(session.duration)
            let endTime = session.endTime ?? fallbackEnd
            guard !points.isEmpty || session.distance > 0 else { return nil }
            let stays = session.stayRecords.compactMap(TimelineStaySnapshot.init)
            return TimelineSessionSnapshot(id: session.id,
                                           startTime: session.startTime,
                                           endTime: max(endTime, session.startTime),
                                           activityType: session.manualActivityType ?? session.activityType,
                                           distance: session.distance,
                                           points: points,
                                           stays: stays)
        }
        self.photos = photos.map(TimelinePhotoSnapshot.init)
    }
}

private struct TimelineSessionSnapshot: Sendable {
    let id: UUID
    let startTime: Date
    let endTime: Date
    let activityType: ActivityType
    let distance: Double
    let points: [TimelineTrackPointSnapshot]
    let stays: [TimelineStaySnapshot]
}

private struct TimelineTrackPointSnapshot: Sendable {
    let id: UUID
    let coordinate: CLLocationCoordinate2D
    let timestamp: Date
    let activityType: ActivityType

    init(_ point: TrackPoint) {
        id = point.id
        coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        timestamp = point.timestamp
        activityType = point.activityType
    }
}

private struct TimelineStaySnapshot: Sendable {
    let coordinate: CLLocationCoordinate2D
    let startTime: Date
    let endTime: Date

    init?(_ stay: StayRecord) {
        let end = stay.departureTime ?? stay.arrivalTime.addingTimeInterval(stay.duration)
        guard end.timeIntervalSince(stay.arrivalTime) >= 10 * 60,
              stay.radius == 0 || stay.radius <= 100 else { return nil }
        coordinate = CLLocationCoordinate2D(latitude: stay.latitude, longitude: stay.longitude)
        startTime = stay.arrivalTime
        endTime = end
    }
}

private struct TimelinePhotoSnapshot: Sendable {
    let id: String
    let date: Date
    let coordinate: CLLocationCoordinate2D?
    let categories: [PhotoSmartCategory]
    let analyzedAt: Date

    init(_ record: PhotoAnalysisRecord) {
        id = record.assetIdentifier
        date = record.creationDate
        if let latitude = record.originalLatitude, let longitude = record.originalLongitude {
            coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        } else {
            coordinate = nil
        }
        categories = record.categories
        analyzedAt = record.analyzedAt
    }
}

private struct TravelTimelineTripDraft: Sendable {
    let stableKey: String
    let title: String
    let startTime: Date
    let endTime: Date
    let totalDistance: Double
    let sourceFingerprint: String
    let routePoints: [TravelTimelineRoutePoint]
    let nodes: [TravelTimelineNodeDraft]
}

private struct TravelTimelineNodeDraft: Sendable {
    let stableKey: String
    let kind: TravelTimelineNodeKind
    let startTime: Date
    let endTime: Date
    let coordinate: CLLocationCoordinate2D
    let endCoordinate: CLLocationCoordinate2D?
    let distance: Double
    let activityType: ActivityType
    var photoIdentifiers: [String]
    var categories: [PhotoSmartCategory]
}

private enum TravelTimelineDraftBuilder {
    private static let stayRadius: CLLocationDistance = 100
    private static let minimumStayDuration: TimeInterval = 10 * 60
    private static let maximumTripGap: TimeInterval = 6 * 60 * 60

    static func build(_ input: TimelineGenerationInput) -> [TravelTimelineTripDraft] {
        let sessionGroups = groupSessions(input.sessions.sorted { $0.startTime < $1.startTime })
        var photosByGroup = Array(repeating: [TimelinePhotoSnapshot](), count: sessionGroups.count)
        var unassignedPhotos: [TimelinePhotoSnapshot] = []

        for photo in input.photos {
            if let index = bestSessionGroup(for: photo, groups: sessionGroups) {
                photosByGroup[index].append(photo)
            } else {
                unassignedPhotos.append(photo)
            }
        }

        var trips: [TravelTimelineTripDraft] = []
        for (index, group) in sessionGroups.enumerated() {
            if let draft = buildActivityTrip(sessions: group, photos: photosByGroup[index]) {
                trips.append(draft)
            }
        }
        trips.append(contentsOf: buildPhotoOnlyTrips(unassignedPhotos))
        return trips.sorted { $0.startTime > $1.startTime }
    }

    private static func groupSessions(_ sessions: [TimelineSessionSnapshot]) -> [[TimelineSessionSnapshot]] {
        var groups: [[TimelineSessionSnapshot]] = []
        for session in sessions {
            guard var current = groups.last, let previous = current.last else {
                groups.append([session])
                continue
            }
            let gap = session.startTime.timeIntervalSince(previous.endTime)
            let sameDay = Calendar.current.isDate(session.startTime, inSameDayAs: previous.endTime)
            if gap <= maximumTripGap && (sameDay || gap <= 2 * 60 * 60) {
                current.append(session)
                groups[groups.count - 1] = current
            } else {
                groups.append([session])
            }
        }
        return groups
    }

    private static func bestSessionGroup(for photo: TimelinePhotoSnapshot,
                                         groups: [[TimelineSessionSnapshot]]) -> Int? {
        var best: (index: Int, score: Double)?
        for (index, group) in groups.enumerated() {
            guard let start = group.map(\.startTime).min(), let end = group.map(\.endTime).max() else { continue }
            let timeGap: TimeInterval
            if photo.date >= start && photo.date <= end {
                timeGap = 0
            } else {
                timeGap = min(abs(photo.date.timeIntervalSince(start)), abs(photo.date.timeIntervalSince(end)))
            }
            let sameDay = Calendar.current.isDate(photo.date, inSameDayAs: start) ||
                Calendar.current.isDate(photo.date, inSameDayAs: end)
            guard timeGap <= 2 * 60 * 60 || sameDay else { continue }

            var distance = 0.0
            if let coordinate = photo.coordinate {
                let points = group.flatMap(\.points)
                if !points.isEmpty {
                    distance = points.map { coordinate.distance(to: $0.coordinate) }.min() ?? .greatestFiniteMagnitude
                    guard distance <= 5_000 || timeGap <= 60 * 60 else { continue }
                }
            }
            let score = timeGap / 3_600 + distance / 2_000
            if best == nil || score < best!.score { best = (index, score) }
        }
        return best?.index
    }

    private static func buildActivityTrip(sessions: [TimelineSessionSnapshot],
                                          photos: [TimelinePhotoSnapshot]) -> TravelTimelineTripDraft? {
        let points = sessions.flatMap(\.points).sorted { $0.timestamp < $1.timestamp }
        guard let sessionStart = sessions.map(\.startTime).min(),
              let sessionEnd = sessions.map(\.endTime).max(),
              let firstSession = sessions.first else { return nil }
        let startTime = min(sessionStart, photos.map(\.date).min() ?? sessionStart)
        let endTime = max(sessionEnd, photos.map(\.date).max() ?? sessionEnd)
        let fallbackCoordinate = points.first?.coordinate ?? photos.compactMap(\.coordinate).first
        guard let fallbackCoordinate else { return nil }

        let detected = detectStays(in: points)
        let recorded = sessions.flatMap(\.stays).map {
            StayDraft(coordinate: $0.coordinate, startTime: $0.startTime, endTime: $0.endTime)
        }
        let stays = mergeStays(detected + recorded)
        var nodes = buildNodes(startTime: startTime,
                               endTime: endTime,
                               points: points,
                               stays: stays,
                               fallbackCoordinate: fallbackCoordinate,
                               defaultActivity: dominantActivity(in: points,
                                                                 fallback: sessions.first?.activityType ?? .unknown))
        attach(photos: photos, to: &nodes)

        let route = sampledRoute(from: points, fallbackPhotos: photos)
        let distance = routeDistance(points)
        return TravelTimelineTripDraft(stableKey: "activity:\(firstSession.id.uuidString)",
                                       title: tripTitle(start: startTime, end: endTime),
                                       startTime: startTime,
                                       endTime: endTime,
                                       totalDistance: distance > 0 ? distance : sessions.map(\.distance).reduce(0, +),
                                       sourceFingerprint: fingerprint(sessions: sessions, photos: photos),
                                       routePoints: route,
                                       nodes: nodes.sorted { $0.startTime < $1.startTime })
    }

    private static func buildPhotoOnlyTrips(_ photos: [TimelinePhotoSnapshot]) -> [TravelTimelineTripDraft] {
        let located = photos.filter { $0.coordinate != nil }
        let byDay = Dictionary(grouping: located) { Calendar.current.startOfDay(for: $0.date) }
        return byDay.flatMap { day, dayPhotos in
            spatialPhotoGroups(dayPhotos).compactMap { group -> TravelTimelineTripDraft? in
                guard let first = group.min(by: { $0.date < $1.date }),
                      let last = group.max(by: { $0.date < $1.date }),
                      let coordinate = first.coordinate else { return nil }
                var nodes = buildPhotoNodes(group)
                attach(photos: group, to: &nodes)
                let route = group.sorted { $0.date < $1.date }.compactMap { photo -> TravelTimelineRoutePoint? in
                    guard let coordinate = photo.coordinate else { return nil }
                    return TravelTimelineRoutePoint(latitude: coordinate.latitude,
                                                    longitude: coordinate.longitude,
                                                    timestamp: photo.date,
                                                    activityTypeRawValue: ActivityType.unknown.rawValue)
                }
                let bucket = "\(Int(coordinate.latitude * 2)):\(Int(coordinate.longitude * 2))"
                return TravelTimelineTripDraft(stableKey: "photo:\(Int(day.timeIntervalSince1970)):\(bucket)",
                                               title: tripTitle(start: first.date, end: last.date),
                                               startTime: first.date,
                                               endTime: max(last.date, first.date),
                                               totalDistance: photoRouteDistance(group),
                                               sourceFingerprint: fingerprint(sessions: [], photos: group),
                                               routePoints: route,
                                               nodes: nodes.sorted { $0.startTime < $1.startTime })
            }
        }
    }

    private static func spatialPhotoGroups(_ photos: [TimelinePhotoSnapshot]) -> [[TimelinePhotoSnapshot]] {
        var groups: [[TimelinePhotoSnapshot]] = []
        for photo in photos.sorted(by: { $0.date < $1.date }) {
            guard let coordinate = photo.coordinate else { continue }
            if let index = groups.firstIndex(where: { group in
                guard let center = center(of: group.compactMap(\.coordinate)) else { return false }
                return center.distance(to: coordinate) <= 15_000
            }) {
                groups[index].append(photo)
            } else {
                groups.append([photo])
            }
        }
        return groups
    }

    private static func detectStays(in points: [TimelineTrackPointSnapshot]) -> [StayDraft] {
        guard points.count >= 2 else { return [] }
        var stays: [StayDraft] = []
        var startIndex = 0

        while startIndex < points.count - 1 {
            var cluster = [points[startIndex]]
            var clusterCenter = points[startIndex].coordinate
            var index = startIndex + 1
            while index < points.count {
                let gap = points[index].timestamp.timeIntervalSince(points[index - 1].timestamp)
                guard gap <= 30 * 60,
                      clusterCenter.distance(to: points[index].coordinate) <= stayRadius else { break }
                cluster.append(points[index])
                clusterCenter = center(of: cluster.map(\.coordinate)) ?? clusterCenter
                index += 1
            }

            if let last = cluster.last,
               last.timestamp.timeIntervalSince(cluster[0].timestamp) >= minimumStayDuration {
                stays.append(StayDraft(coordinate: clusterCenter,
                                       startTime: cluster[0].timestamp,
                                       endTime: last.timestamp))
                startIndex = max(index, startIndex + 1)
            } else {
                startIndex += 1
            }
        }
        return stays
    }

    private static func mergeStays(_ stays: [StayDraft]) -> [StayDraft] {
        var merged: [StayDraft] = []
        for stay in stays.sorted(by: { $0.startTime < $1.startTime }) {
            guard var previous = merged.last else {
                merged.append(stay)
                continue
            }
            let gap = stay.startTime.timeIntervalSince(previous.endTime)
            if previous.coordinate.distance(to: stay.coordinate) <= stayRadius && gap <= 30 * 60 {
                previous = StayDraft(coordinate: center(of: [previous.coordinate, stay.coordinate]) ?? previous.coordinate,
                                     startTime: min(previous.startTime, stay.startTime),
                                     endTime: max(previous.endTime, stay.endTime))
                merged[merged.count - 1] = previous
            } else {
                merged.append(stay)
            }
        }
        return merged.filter { $0.endTime.timeIntervalSince($0.startTime) >= minimumStayDuration }
    }

    private static func buildNodes(startTime: Date,
                                   endTime: Date,
                                   points: [TimelineTrackPointSnapshot],
                                   stays: [StayDraft],
                                   fallbackCoordinate: CLLocationCoordinate2D,
                                   defaultActivity: ActivityType) -> [TravelTimelineNodeDraft] {
        var result: [TravelTimelineNodeDraft] = []
        var cursor = startTime
        var cursorCoordinate = points.first?.coordinate ?? fallbackCoordinate

        for stay in stays where stay.endTime >= startTime && stay.startTime <= endTime {
            let clampedStart = max(stay.startTime, startTime)
            if clampedStart > cursor {
                if let movement = movementNode(start: cursor,
                                               end: clampedStart,
                                               startCoordinate: cursorCoordinate,
                                               endCoordinate: stay.coordinate,
                                               points: points,
                                               defaultActivity: defaultActivity) {
                    result.append(movement)
                }
            }
            result.append(stayNode(stay))
            cursor = max(cursor, stay.endTime)
            cursorCoordinate = stay.coordinate
        }

        if cursor < endTime,
           let movement = movementNode(start: cursor,
                                       end: endTime,
                                       startCoordinate: cursorCoordinate,
                                       endCoordinate: points.last?.coordinate ?? fallbackCoordinate,
                                       points: points,
                                       defaultActivity: defaultActivity) {
            result.append(movement)
        }
        if result.isEmpty {
            result.append(movementNode(start: startTime,
                                       end: endTime,
                                       startCoordinate: points.first?.coordinate ?? fallbackCoordinate,
                                       endCoordinate: points.last?.coordinate ?? fallbackCoordinate,
                                       points: points,
                                       defaultActivity: defaultActivity,
                                       force: true)!)
        }
        return result
    }

    private static func buildPhotoNodes(_ photos: [TimelinePhotoSnapshot]) -> [TravelTimelineNodeDraft] {
        let ordered = photos.sorted { $0.date < $1.date }
        var clusters: [[TimelinePhotoSnapshot]] = []
        for photo in ordered {
            guard let coordinate = photo.coordinate else { continue }
            if var current = clusters.last,
               let center = center(of: current.compactMap(\.coordinate)),
               center.distance(to: coordinate) <= stayRadius {
                current.append(photo)
                clusters[clusters.count - 1] = current
            } else {
                clusters.append([photo])
            }
        }

        var nodes: [TravelTimelineNodeDraft] = []
        for (clusterIndex, cluster) in clusters.enumerated() {
            guard let first = cluster.first,
                  let last = cluster.last,
                  let coordinate = center(of: cluster.compactMap(\.coordinate)) else { continue }
            let duration = last.date.timeIntervalSince(first.date)
            if duration >= minimumStayDuration {
                nodes.append(TravelTimelineNodeDraft(stableKey: nodeKey(kind: .stay,
                                                                        time: first.date,
                                                                        coordinate: coordinate),
                                                      kind: .stay,
                                                      startTime: first.date,
                                                      endTime: last.date,
                                                      coordinate: coordinate,
                                                      endCoordinate: nil,
                                                      distance: 0,
                                                      activityType: .stationary,
                                                      photoIdentifiers: [],
                                                      categories: []))
            } else {
                for photo in cluster {
                    guard let coordinate = photo.coordinate else { continue }
                    nodes.append(TravelTimelineNodeDraft(stableKey: "photo:\(photo.id)",
                                                          kind: .stay,
                                                          startTime: photo.date,
                                                          endTime: photo.date,
                                                          coordinate: coordinate,
                                                          endCoordinate: nil,
                                                          distance: 0,
                                                          activityType: .stationary,
                                                          photoIdentifiers: [],
                                                          categories: []))
                }
            }

            if clusterIndex < clusters.count - 1,
               let next = clusters[clusterIndex + 1].first,
               let nextCoordinate = next.coordinate {
                let distance = coordinate.distance(to: nextCoordinate)
                if distance >= 25 {
                    nodes.append(TravelTimelineNodeDraft(stableKey: nodeKey(kind: .movement,
                                                                            time: last.date,
                                                                            coordinate: coordinate),
                                                          kind: .movement,
                                                          startTime: last.date,
                                                          endTime: next.date,
                                                          coordinate: coordinate,
                                                          endCoordinate: nextCoordinate,
                                                          distance: distance,
                                                          activityType: .unknown,
                                                          photoIdentifiers: [],
                                                          categories: []))
                }
            }
        }
        return nodes
    }

    private static func stayNode(_ stay: StayDraft) -> TravelTimelineNodeDraft {
        TravelTimelineNodeDraft(stableKey: nodeKey(kind: .stay,
                                                   time: stay.startTime,
                                                   coordinate: stay.coordinate),
                                kind: .stay,
                                startTime: stay.startTime,
                                endTime: stay.endTime,
                                coordinate: stay.coordinate,
                                endCoordinate: nil,
                                distance: 0,
                                activityType: .stationary,
                                photoIdentifiers: [],
                                categories: [])
    }

    private static func movementNode(start: Date,
                                     end: Date,
                                     startCoordinate: CLLocationCoordinate2D,
                                     endCoordinate: CLLocationCoordinate2D,
                                     points: [TimelineTrackPointSnapshot],
                                     defaultActivity: ActivityType,
                                     force: Bool = false) -> TravelTimelineNodeDraft? {
        let segmentPoints = points.filter { $0.timestamp >= start && $0.timestamp <= end }
        let distance = routeDistance(segmentPoints)
        let directDistance = startCoordinate.distance(to: endCoordinate)
        guard force || end.timeIntervalSince(start) >= 60 || max(distance, directDistance) >= 25 else { return nil }
        return TravelTimelineNodeDraft(stableKey: nodeKey(kind: .movement,
                                                          time: start,
                                                          coordinate: startCoordinate),
                                       kind: .movement,
                                       startTime: start,
                                       endTime: end,
                                       coordinate: startCoordinate,
                                       endCoordinate: endCoordinate,
                                       distance: distance > 0 ? distance : directDistance,
                                       activityType: dominantActivity(in: segmentPoints, fallback: defaultActivity),
                                       photoIdentifiers: [],
                                       categories: [])
    }

    private static func attach(photos: [TimelinePhotoSnapshot],
                               to nodes: inout [TravelTimelineNodeDraft]) {
        guard !nodes.isEmpty else { return }
        for photo in photos {
            let candidateIndices = nodes.indices.filter { index in
                let node = nodes[index]
                let timeFits = photo.date >= node.startTime.addingTimeInterval(-30 * 60) &&
                    photo.date <= node.endTime.addingTimeInterval(30 * 60)
                guard timeFits else { return false }
                if node.kind == .stay, let coordinate = photo.coordinate {
                    return node.coordinate.distance(to: coordinate) <= 150
                }
                return photo.date >= node.startTime && photo.date <= node.endTime
            }
            let index = candidateIndices.min { lhs, rhs in
                timeDistance(photo.date, nodes[lhs]) < timeDistance(photo.date, nodes[rhs])
            } ?? nodes.indices.min {
                timeDistance(photo.date, nodes[$0]) < timeDistance(photo.date, nodes[$1])
            }
            guard let index else { continue }
            if !nodes[index].photoIdentifiers.contains(photo.id) {
                nodes[index].photoIdentifiers.append(photo.id)
            }
            let categorySet = Set(nodes[index].categories).union(photo.categories)
            nodes[index].categories = PhotoSmartCategory.allCases.filter { categorySet.contains($0) }
        }
    }

    private static func timeDistance(_ date: Date, _ node: TravelTimelineNodeDraft) -> TimeInterval {
        if date >= node.startTime && date <= node.endTime { return 0 }
        return min(abs(date.timeIntervalSince(node.startTime)), abs(date.timeIntervalSince(node.endTime)))
    }

    private static func dominantActivity(in points: [TimelineTrackPointSnapshot],
                                         fallback: ActivityType) -> ActivityType {
        let candidates = points.map(\.activityType).filter { $0 != .stationary && $0 != .unknown }
        let counts = Dictionary(grouping: candidates, by: { $0 }).mapValues(\.count)
        return counts.max(by: { $0.value < $1.value })?.key ?? fallback
    }

    private static func sampledRoute(from points: [TimelineTrackPointSnapshot],
                                     fallbackPhotos: [TimelinePhotoSnapshot]) -> [TravelTimelineRoutePoint] {
        if points.isEmpty {
            return fallbackPhotos.sorted { $0.date < $1.date }.compactMap { photo in
                guard let coordinate = photo.coordinate else { return nil }
                return TravelTimelineRoutePoint(latitude: coordinate.latitude,
                                                longitude: coordinate.longitude,
                                                timestamp: photo.date,
                                                activityTypeRawValue: ActivityType.unknown.rawValue)
            }
        }
        let stride = max(points.count / 1_200, 1)
        return points.enumerated().compactMap { index, point in
            guard index % stride == 0 || index == points.count - 1 else { return nil }
            return TravelTimelineRoutePoint(latitude: point.coordinate.latitude,
                                            longitude: point.coordinate.longitude,
                                            timestamp: point.timestamp,
                                            activityTypeRawValue: point.activityType.rawValue)
        }
    }

    private static func routeDistance(_ points: [TimelineTrackPointSnapshot]) -> CLLocationDistance {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for pair in zip(points, points.dropFirst()) {
            let interval = pair.1.timestamp.timeIntervalSince(pair.0.timestamp)
            guard interval > 0, interval <= 30 * 60 else { continue }
            let distance = pair.0.coordinate.distance(to: pair.1.coordinate)
            guard distance / interval <= 60 else { continue }
            total += distance
        }
        return total
    }

    private static func photoRouteDistance(_ photos: [TimelinePhotoSnapshot]) -> CLLocationDistance {
        let points = photos.sorted { $0.date < $1.date }.compactMap { photo -> TimelineTrackPointSnapshot? in
            guard let coordinate = photo.coordinate else { return nil }
            return TimelineTrackPointSnapshot(id: UUID(), coordinate: coordinate, timestamp: photo.date, activityType: .unknown)
        }
        return zip(points, points.dropFirst()).reduce(0) { result, pair in
            result + pair.0.coordinate.distance(to: pair.1.coordinate)
        }
    }

    private static func tripTitle(start: Date, end: Date) -> String {
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return "\(start.formatted(.dateTime.year().month().day())) 旅行"
        }
        return "\(start.formatted(.dateTime.month().day()))–\(end.formatted(.dateTime.month().day())) 旅行"
    }

    private static func nodeKey(kind: TravelTimelineNodeKind,
                                time: Date,
                                coordinate: CLLocationCoordinate2D) -> String {
        "\(kind.rawValue):\(Int(time.timeIntervalSince1970 / 300)):\(Int(coordinate.latitude * 1_000)):\(Int(coordinate.longitude * 1_000))"
    }

    private static func fingerprint(sessions: [TimelineSessionSnapshot],
                                    photos: [TimelinePhotoSnapshot]) -> String {
        var hash = StableFNVHash()
        hash.add("travel-timeline-v1")
        for session in sessions {
            hash.add(session.id.uuidString)
            hash.add(session.startTime.timeIntervalSince1970)
            hash.add(session.endTime.timeIntervalSince1970)
            hash.add(session.activityType.rawValue)
            for point in session.points {
                hash.add(point.id.uuidString)
                hash.add(point.timestamp.timeIntervalSince1970)
                hash.add(point.coordinate.latitude)
                hash.add(point.coordinate.longitude)
                hash.add(point.activityType.rawValue)
            }
            for stay in session.stays {
                hash.add(stay.startTime.timeIntervalSince1970)
                hash.add(stay.endTime.timeIntervalSince1970)
                hash.add(stay.coordinate.latitude)
                hash.add(stay.coordinate.longitude)
            }
        }
        for photo in photos.sorted(by: { $0.id < $1.id }) {
            hash.add(photo.id)
            hash.add(photo.date.timeIntervalSince1970)
            hash.add(photo.analyzedAt.timeIntervalSince1970)
            hash.add(photo.categories.map(\.rawValue).joined(separator: ","))
            if let coordinate = photo.coordinate {
                hash.add(coordinate.latitude)
                hash.add(coordinate.longitude)
            }
        }
        return hash.hex
    }

    private static func center(of coordinates: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        guard !coordinates.isEmpty else { return nil }
        return CLLocationCoordinate2D(latitude: coordinates.map(\.latitude).reduce(0, +) / Double(coordinates.count),
                                      longitude: coordinates.map(\.longitude).reduce(0, +) / Double(coordinates.count))
    }
}

private struct StayDraft: Sendable {
    let coordinate: CLLocationCoordinate2D
    let startTime: Date
    let endTime: Date
}

private struct StableFNVHash {
    private var value: UInt64 = 14_695_981_039_346_656_037

    mutating func add<T>(_ value: T) {
        for byte in String(describing: value).utf8 {
            self.value ^= UInt64(byte)
            self.value &*= 1_099_511_628_211
        }
        self.value ^= 0xFF
        self.value &*= 1_099_511_628_211
    }

    var hex: String { String(value, radix: 16) }
}

private extension TimelineTrackPointSnapshot {
    init(id: UUID,
         coordinate: CLLocationCoordinate2D,
         timestamp: Date,
         activityType: ActivityType) {
        self.id = id
        self.coordinate = coordinate
        self.timestamp = timestamp
        self.activityType = activityType
    }
}

private extension CLLocationCoordinate2D {
    func distance(to other: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }
}
