import CoreLocation
import Foundation
import SwiftData

enum JourneyGenerationService {
    private static let generationVersion = 2
    private static let maximumSessionGap: TimeInterval = 3 * 60 * 60
    private static let stayAttachmentWindow: TimeInterval = 90 * 60
    private static let maximumDirectConnectionDistance: CLLocationDistance = 1_000
    private static let maximumAnchoredConnectionDistance: CLLocationDistance = 2_500
    private static let endpointStayDistance: CLLocationDistance = 300

    static func refresh(in context: ModelContext) {
        do {
            let descriptor = FetchDescriptor<ActivitySession>(predicate: #Predicate { !$0.isActive })
            let sessions = try context.fetch(descriptor)
                .filter { !$0.trackPoints.isEmpty }
                .sorted { $0.startTime < $1.startTime }
            let stays = try context.fetch(FetchDescriptor<StayRecord>())
            let places = try context.fetch(FetchDescriptor<CustomPlace>())
            let drafts = buildDrafts(sessions: sessions, stays: stays, places: places)
            reconcile(drafts: drafts, in: context)
            if context.hasChanges {
                PersistenceService.save(context, operation: "更新自动出行")
            }
        } catch {
            return
        }
    }

    private static func buildDrafts(sessions: [ActivitySession],
                                    stays: [StayRecord],
                                    places: [CustomPlace]) -> [JourneyDraft] {
        guard !sessions.isEmpty else { return [] }
        let endpointMap: [UUID: SessionEndpoints] = Dictionary(
            uniqueKeysWithValues: sessions.map { ($0.id, sessionEndpoints(of: $0)) }
        )
        var groups: [[ActivitySession]] = []
        var current: [ActivitySession] = []
        var currentEnd = Date.distantPast

        for session in sessions {
            let sessionEnd = effectiveEnd(of: session, endpoints: endpointMap[session.id])
            if let first = current.first, let previous = current.last {
                let gap = session.startTime.timeIntervalSince(currentEnd)
                let sameDay = Calendar.current.isDate(session.startTime, inSameDayAs: first.startTime)
                let exceedsTimeBoundary = gap > maximumSessionGap || (!sameDay && gap > 60 * 60)
                let spatiallyContinuous = isSpatiallyContinuous(from: previous,
                                                                to: session,
                                                                endpoints: endpointMap,
                                                                stays: stays,
                                                                places: places)
                if exceedsTimeBoundary || !spatiallyContinuous {
                    groups.append(current)
                    current = []
                }
            }
            current.append(session)
            currentEnd = max(currentEnd, sessionEnd)
        }
        if !current.isEmpty { groups.append(current) }

        return groups.compactMap { group -> JourneyDraft? in
            guard let first = group.first, let last = group.last else { return nil }
            let start = first.startTime
            let end = group.map { effectiveEnd(of: $0, endpoints: endpointMap[$0.id]) }.max() ??
                effectiveEnd(of: last, endpoints: endpointMap[last.id])
            let totalDistance = group.reduce(0) { $0 + $1.distance }
            guard totalDistance >= 250 || end.timeIntervalSince(start) >= 5 * 60 else { return nil }
            guard let startCoordinate = endpointMap[first.id]?.start,
                  let endCoordinate = endpointMap[last.id]?.end else { return nil }

            let groupIDs = Set(group.map(\.id))
            let startStay = endpointStay(near: startCoordinate,
                                         at: start,
                                         side: .start,
                                         stays: stays)
            let endStay = endpointStay(near: endCoordinate,
                                       at: end,
                                       side: .end,
                                       stays: stays)
            let attachedStays = stays.filter { stay in
                if let sessionID = stay.session?.id, groupIDs.contains(sessionID) { return true }
                return stay.id == startStay?.id || stay.id == endStay?.id
            }.sorted { $0.arrivalTime < $1.arrivalTime }

            let startPlace = placeName(for: startStay,
                                       coordinate: startCoordinate,
                                       places: places)
            let endPlace = placeName(for: endStay,
                                     coordinate: endCoordinate,
                                     places: places)
            let primaryActivity = primaryActivity(in: group)
            let sessionIDs = group.map(\.id)
            let stableKey = sessionIDs.map(\.uuidString).joined(separator: "|")
            return JourneyDraft(stableKey: stableKey,
                                startTime: start,
                                endTime: end,
                                startPlace: startPlace,
                                endPlace: endPlace,
                                totalDistance: totalDistance,
                                primaryActivity: primaryActivity,
                                sessionIDs: sessionIDs,
                                stayRecordIDs: attachedStays.map(\.id))
        }
    }

    private static func isSpatiallyContinuous(from previous: ActivitySession,
                                              to next: ActivitySession,
                                              endpoints: [UUID: SessionEndpoints],
                                              stays: [StayRecord],
                                              places: [CustomPlace]) -> Bool {
        guard let previousCoordinate = endpoints[previous.id]?.end,
              let nextCoordinate = endpoints[next.id]?.start else { return false }
        let distance = previousCoordinate.distance(to: nextCoordinate)
        if distance <= maximumDirectConnectionDistance { return true }
        guard distance <= maximumAnchoredConnectionDistance else { return false }

        let previousTime = effectiveEnd(of: previous, endpoints: endpoints[previous.id])
        let nextTime = next.startTime
        let previousAnchor = anchorID(near: previousCoordinate,
                                      at: previousTime,
                                      stays: stays,
                                      places: places)
        let nextAnchor = anchorID(near: nextCoordinate,
                                  at: nextTime,
                                  stays: stays,
                                  places: places)
        return previousAnchor != nil && previousAnchor == nextAnchor
    }

    private static func anchorID(near coordinate: CLLocationCoordinate2D,
                                 at time: Date,
                                 stays: [StayRecord],
                                 places: [CustomPlace]) -> UUID? {
        if let stay = stays
            .filter({ isTrusted($0) && temporalDistance(from: time, to: $0) <= stayAttachmentWindow })
            .filter({ coordinate.distance(to: $0.coordinate) <= max(endpointStayDistance, $0.radius + 100) })
            .min(by: { temporalDistance(from: time, to: $0) < temporalDistance(from: time, to: $1) }),
           let placeID = stay.customPlaceID {
            return placeID
        }
        return places
            .filter { coordinate.distance(to: $0.coordinate) <= max($0.radius + 100, endpointStayDistance) }
            .min { coordinate.distance(to: $0.coordinate) < coordinate.distance(to: $1.coordinate) }?
            .id
    }

    private enum EndpointSide {
        case start
        case end
    }

    private static func endpointStay(near coordinate: CLLocationCoordinate2D,
                                     at time: Date,
                                     side: EndpointSide,
                                     stays: [StayRecord]) -> StayRecord? {
        stays
            .filter(isTrusted)
            .filter { stay in
                let stayEnd = stay.departureTime ?? stay.arrivalTime.addingTimeInterval(stay.duration)
                let isTemporallyEligible: Bool
                switch side {
                case .start:
                    isTemporallyEligible = stay.arrivalTime <= time.addingTimeInterval(5 * 60) &&
                        stayEnd >= time.addingTimeInterval(-stayAttachmentWindow)
                case .end:
                    isTemporallyEligible = stay.arrivalTime <= time.addingTimeInterval(stayAttachmentWindow) &&
                        stayEnd >= time.addingTimeInterval(-5 * 60)
                }
                return isTemporallyEligible &&
                    coordinate.distance(to: stay.coordinate) <= max(endpointStayDistance, stay.radius + 100)
            }
            .min { lhs, rhs in
                let lhsTime = temporalDistance(from: time, to: lhs)
                let rhsTime = temporalDistance(from: time, to: rhs)
                if lhsTime != rhsTime { return lhsTime < rhsTime }
                return coordinate.distance(to: lhs.coordinate) < coordinate.distance(to: rhs.coordinate)
            }
    }

    private static func isTrusted(_ stay: StayRecord) -> Bool {
        stay.customPlaceID != nil || stay.confidence >= 0.55
    }

    private static func temporalDistance(from time: Date, to stay: StayRecord) -> TimeInterval {
        let end = stay.departureTime ?? stay.arrivalTime.addingTimeInterval(stay.duration)
        if time < stay.arrivalTime { return stay.arrivalTime.timeIntervalSince(time) }
        if time > end { return time.timeIntervalSince(end) }
        return 0
    }

    private static func placeName(for stay: StayRecord?,
                                  coordinate: CLLocationCoordinate2D,
                                  places: [CustomPlace]) -> String? {
        if let name = stay?.detectedName, !name.isEmpty { return name }
        return places
            .filter { coordinate.distance(to: $0.coordinate) <= max($0.radius, 100) }
            .min { coordinate.distance(to: $0.coordinate) < coordinate.distance(to: $1.coordinate) }?
            .shortName
    }

    private static func reconcile(drafts: [JourneyDraft], in context: ModelContext) {
        let existing: [JourneyRecord]
        do {
            existing = try context.fetch(FetchDescriptor<JourneyRecord>())
        } catch {
            return
        }
        var byKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.stableKey, $0) })

        for draft in drafts {
            if let record = byKey.removeValue(forKey: draft.stableKey) {
                if !record.matches(draft, generationVersion: generationVersion) {
                    record.update(startTime: draft.startTime,
                                  endTime: draft.endTime,
                                  startPlace: draft.startPlace,
                                  endPlace: draft.endPlace,
                                  totalDistance: draft.totalDistance,
                                  primaryActivity: draft.primaryActivity,
                                  sessionIDs: draft.sessionIDs,
                                  stayRecordIDs: draft.stayRecordIDs,
                                  generationVersion: generationVersion)
                }
            } else {
                context.insert(JourneyRecord(stableKey: draft.stableKey,
                                             startTime: draft.startTime,
                                             endTime: draft.endTime,
                                             startPlace: draft.startPlace,
                                             endPlace: draft.endPlace,
                                             totalDistance: draft.totalDistance,
                                             primaryActivity: draft.primaryActivity,
                                             sessionIDs: draft.sessionIDs,
                                             stayRecordIDs: draft.stayRecordIDs,
                                             generationVersion: generationVersion))
            }
        }
        for stale in byKey.values { context.delete(stale) }
    }

    private static func sessionEndpoints(of session: ActivitySession) -> SessionEndpoints {
        let points = session.trackPoints
            .filter(\.isUsableForAnalysis)
            .filter { CLLocationCoordinate2DIsValid($0.coordinate) }
            .sorted { $0.timestamp < $1.timestamp }
        return SessionEndpoints(start: points.first?.coordinate,
                                end: points.last?.coordinate,
                                lastTimestamp: points.last?.timestamp)
    }

    private static func effectiveEnd(of session: ActivitySession,
                                     endpoints: SessionEndpoints?) -> Date {
        session.endTime ?? endpoints?.lastTimestamp ?? session.startTime
    }

    private static func primaryActivity(in sessions: [ActivitySession]) -> ActivityType {
        let totals = Dictionary(grouping: sessions, by: \.activityType)
            .mapValues { $0.reduce(0) { $0 + max($1.distance, 1) } }
        return totals.max(by: { $0.value < $1.value })?.key ?? .unknown
    }
}

private struct SessionEndpoints {
    let start: CLLocationCoordinate2D?
    let end: CLLocationCoordinate2D?
    let lastTimestamp: Date?
}

private struct JourneyDraft {
    let stableKey: String
    let startTime: Date
    let endTime: Date
    let startPlace: String?
    let endPlace: String?
    let totalDistance: Double
    let primaryActivity: ActivityType
    let sessionIDs: [UUID]
    let stayRecordIDs: [UUID]
}

private extension JourneyRecord {
    func matches(_ draft: JourneyDraft, generationVersion: Int) -> Bool {
        startTime == draft.startTime &&
            endTime == draft.endTime &&
            startPlace == draft.startPlace &&
            endPlace == draft.endPlace &&
            abs(totalDistance - draft.totalDistance) < 0.01 &&
            primaryActivity == draft.primaryActivity &&
            sessionIDs == draft.sessionIDs &&
            stayRecordIDs == draft.stayRecordIDs &&
            self.generationVersion == generationVersion
    }
}

private extension TrackPoint {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private extension StayRecord {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private extension CustomPlace {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private extension CLLocationCoordinate2D {
    func distance(to other: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }
}
