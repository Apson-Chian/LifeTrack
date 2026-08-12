import Foundation
import SwiftData

struct DataHealthSnapshot {
    struct RecordCount: Identifiable {
        let id: String
        let name: String
        let count: Int
    }

    let generatedAt: Date
    let recordCounts: [RecordCount]
    let activeSessionCount: Int
    let oldestActiveSessionStart: Date?
    let lastBackupDate: Date?
    let databaseSize: Int64

    var hasAbnormalActiveSession: Bool {
        guard activeSessionCount > 0 else { return false }
        if activeSessionCount > 1 { return true }
        guard let oldestActiveSessionStart else { return false }
        return Date.now.timeIntervalSince(oldestActiveSessionStart) > 4 * 60 * 60
    }
}

@MainActor
enum DataHealthService {
    static func inspect(context: ModelContext) throws -> DataHealthSnapshot {
        let activeDescriptor = FetchDescriptor<ActivitySession>(
            predicate: #Predicate { $0.isActive },
            sortBy: [SortDescriptor(\ActivitySession.startTime)]
        )
        let activeSessions = try context.fetch(activeDescriptor)

        let counts: [DataHealthSnapshot.RecordCount] = [
            .init(id: "sessions", name: "活动记录", count: try count(ActivitySession.self, in: context)),
            .init(id: "points", name: "定位点", count: try count(TrackPoint.self, in: context)),
            .init(id: "places", name: "自定义地点", count: try count(CustomPlace.self, in: context)),
            .init(id: "stays", name: "停留记录", count: try count(StayRecord.self, in: context)),
            .init(id: "journeys", name: "Journey", count: try count(JourneyRecord.self, in: context)),
            .init(id: "summaries", name: "每日汇总", count: try count(DailySummary.self, in: context)),
            .init(id: "photos", name: "照片分析", count: try count(PhotoAnalysisRecord.self, in: context)),
            .init(id: "timelineTrips", name: "旅行时间线", count: try count(TravelTimelineTrip.self, in: context)),
            .init(id: "timelineNodes", name: "时间线节点", count: try count(TravelTimelineNode.self, in: context)),
            .init(id: "archives", name: "旅行归档", count: try count(TravelArchiveRecord.self, in: context))
        ]

        return DataHealthSnapshot(
            generatedAt: .now,
            recordCounts: counts,
            activeSessionCount: activeSessions.count,
            oldestActiveSessionStart: activeSessions.first?.startTime,
            lastBackupDate: BackupService.lastBackupDate,
            databaseSize: databaseFootprint()
        )
    }

    private static func count<T: PersistentModel>(_ type: T.Type,
                                                   in context: ModelContext) throws -> Int {
        try context.fetchCount(FetchDescriptor<T>())
    }

    private static func databaseFootprint() -> Int64 {
        let storeURL = DataStoreManager.activeStoreURL
        let urls = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm")
        ]
        return urls.reduce(0) { partial, url in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber else { return partial }
            return partial + size.int64Value
        }
    }
}
