import Foundation
import SwiftData

struct TrackEditingResult {
    let removedPointCount: Int
    let remainingPointCount: Int
}

enum TrackEditingError: LocalizedError {
    case activeSession
    case tooFewPoints
    case nothingSelected
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .activeSession:
            "进行中的记录不能修剪，请先结束记录。"
        case .tooFewPoints:
            "修剪后至少需要保留两个轨迹点。"
        case .nothingSelected:
            "没有选择要删除的轨迹点。"
        case let .saveFailed(message):
            message
        }
    }
}

@MainActor
enum TrackEditingService {
    static func trim(session: ActivitySession,
                     removing pointIDs: Set<UUID>,
                     in context: ModelContext) throws -> TrackEditingResult {
        guard !session.isActive else { throw TrackEditingError.activeSession }
        guard !pointIDs.isEmpty else { throw TrackEditingError.nothingSelected }

        let ordered = session.trackPoints.sorted(by: pointOrder)
        let removed = ordered.filter { pointIDs.contains($0.id) }
        let remaining = ordered.filter { !pointIDs.contains($0.id) }
        guard removed.count == pointIDs.count, remaining.count >= 2,
              let first = remaining.first, let last = remaining.last else {
            throw TrackEditingError.tooFewPoints
        }

        session.trackPoints.removeAll { pointIDs.contains($0.id) }
        for point in removed {
            context.delete(point)
        }

        let analysis = TrajectoryAnalysisService.analyze(remaining)
        for point in remaining {
            point.anomalyReason = analysis.anomalyReasons[point.id]
        }
        session.startTime = first.timestamp
        session.endTime = last.timestamp
        session.duration = max(0, last.timestamp.timeIntervalSince(first.timestamp))
        session.distance = analysis.effectiveDistance
        if session.manualActivityType == nil {
            session.activityType = dominantActivity(in: remaining)
        }

        do {
            let places = try context.fetch(FetchDescriptor<CustomPlace>())
            StayDetectionService.rebuildRecords(for: session, places: places, in: context)

            var saveError = "保存轨迹修剪失败。"
            guard PersistenceService.save(context,
                                          operation: "保存轨迹修剪",
                                          failureRecovery: .rollback,
                                          onError: { saveError = $0 }) else {
                throw TrackEditingError.saveFailed(saveError)
            }
        } catch {
            context.rollback()
            throw error
        }
        JourneyGenerationService.refresh(in: context)

        return TrackEditingResult(removedPointCount: removed.count,
                                  remainingPointCount: remaining.count)
    }

    private static func dominantActivity(in points: [TrackPoint]) -> ActivityType {
        let usable = points.filter(\.isUsableForAnalysis)
        let counts = Dictionary(grouping: usable, by: \.activityType).mapValues(\.count)
        return counts.max { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key.rawValue < rhs.key.rawValue
        }?.key ?? .unknown
    }

    private static func pointOrder(_ lhs: TrackPoint, _ rhs: TrackPoint) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
