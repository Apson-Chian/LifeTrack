import CoreLocation
import Foundation
import SwiftData

enum JourneyGenerationService {
    private static let generationVersion = 1
    private static let maximumSessionGap: TimeInterval = 3 * 60 * 60
    private static let stayAttachmentWindow: TimeInterval = 90 * 60

    static func refresh(in context: ModelContext) {
        do {
            let sessions = try context.fetch(FetchDescriptor<ActivitySession>())
                .filter { !$0.isActive && !$0.trackPoints.isEmpty }
                .sorted { $0.startTime < $1.startTime }
            let stays = try context.fetch(FetchDescriptor<StayRecord>())
            let places = try context.fetch(FetchDescriptor<CustomPlace>())
            let drafts = buildDrafts(sessions: sessions, stays: stays, places: places)
            reconcile(drafts: drafts, in: context)
            PersistenceService.save(context, operation: "更新自动出行")
        } catch {
            // PersistenceService owns save logging; fetch failures are intentionally non-fatal.
            return
        }
    }

    private static func buildDrafts(sessions: [ActivitySession],
                                    stays: [StayRecord],
                                    places: [CustomPlace]) -> [JourneyDraft] {
        guard !sessions.isEmpty else { return [] }
        var groups: [[ActivitySession]] = []
        var current: [ActivitySession] = []
        var currentEnd = Date.distantPast

        for session in sessions {
            let sessionEnd = effectiveEnd(of: session)
            if let first = current.first {
                let gap = session.startTime.timeIntervalSince(currentEnd)
                let sameDay = Calendar.current.isDate(session.startTime, inSameDayAs: first.startTime)
                if gap > maximumSessionGap || (!sameDay && gap > 60 * 60) {
                    groups.append(current)
                    current = []
                }
            }
            current.append(session)
            currentEnd = max(currentEnd, sessionEnd)
        }
        if !current.isEmpty { groups.append(current) }

        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            let start = first.startTime
            let end = group.map(effectiveEnd(of:)).max() ?? effectiveEnd(of: last)
            let totalDistance = group.reduce(0) { $0 + $1.distance }
            guard totalDistance >= 250 || end.timeIntervalSince(start) >= 5 * 60 else { return nil }

            let attachedStays = stays.filter { stay in
                let stayEnd = stay.departureTime ?? stay.arrivalTime.addingTimeInterval(stay.duration)
                return stayEnd >= start.addingTimeInterval(-stayAttachmentWindow) &&
                    stay.arrivalTime <= end.addingTimeInterval(stayAttachmentWindow)
            }.sorted { $0.arrivalTime < $1.arrivalTime }
            let startPlace = placeName(atStartOf: group,
                                       stays: attachedStays,
                                       places: places)
            let endPlace = placeName(atEndOf: group,
                                     stays: attachedStays,
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
                record.update(startTime: draft.startTime,
                              endTime: draft.endTime,
                              startPlace: draft.startPlace,
                              endPlace: draft.endPlace,
                              totalDistance: draft.totalDistance,
                              primaryActivity: draft.primaryActivity,
                              sessionIDs: draft.sessionIDs,
                              stayRecordIDs: draft.stayRecordIDs,
                              generationVersion: generationVersion)
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

    private static func effectiveEnd(of session: ActivitySession) -> Date {
        session.endTime ?? session.trackPoints.map(\.timestamp).max() ?? session.startTime
    }

    private static func primaryActivity(in sessions: [ActivitySession]) -> ActivityType {
        let totals = Dictionary(grouping: sessions, by: \.activityType)
            .mapValues { $0.reduce(0) { $0 + max($1.distance, 1) } }
        return totals.max(by: { $0.value < $1.value })?.key ?? .unknown
    }

    private static func placeName(atStartOf sessions: [ActivitySession],
                                  stays: [StayRecord],
                                  places: [CustomPlace]) -> String? {
        guard let session = sessions.first else { return nil }
        let candidate = stays
            .filter { $0.arrivalTime <= session.startTime }
            .max { ($0.departureTime ?? $0.arrivalTime) < ($1.departureTime ?? $1.arrivalTime) }
        if let name = candidate?.detectedName { return name }
        guard let point = session.trackPoints.min(by: { $0.timestamp < $1.timestamp }) else { return nil }
        return matchingPlaceName(latitude: point.latitude, longitude: point.longitude, places: places)
    }

    private static func placeName(atEndOf sessions: [ActivitySession],
                                  stays: [StayRecord],
                                  places: [CustomPlace]) -> String? {
        guard let session = sessions.last else { return nil }
        let end = effectiveEnd(of: session)
        let candidate = stays
            .filter { ($0.departureTime ?? $0.arrivalTime.addingTimeInterval($0.duration)) >= end }
            .min { $0.arrivalTime < $1.arrivalTime }
        if let name = candidate?.detectedName { return name }
        guard let point = session.trackPoints.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
        return matchingPlaceName(latitude: point.latitude, longitude: point.longitude, places: places)
    }

    private static func matchingPlaceName(latitude: Double,
                                          longitude: Double,
                                          places: [CustomPlace]) -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        return places
            .filter {
                location.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) <= max($0.radius, 100)
            }
            .min(by: { $0.radius < $1.radius })?
            .shortName
    }
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
