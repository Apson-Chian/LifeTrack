import Foundation
import SwiftData

enum LifeTrackSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            ActivitySession.self,
            TrackPoint.self,
            CustomPlace.self,
            StayRecord.self,
            DailySummary.self,
            PhotoAnalysisRecord.self,
            TravelTimelineTrip.self,
            TravelTimelineNode.self,
            JourneyRecord.self,
            TravelArchiveRecord.self
        ]
    }
}

enum LifeTrackSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        var result: [any PersistentModel.Type] = LifeTrackSchemaV1.models
        result.append(LifeTrackSchemaV2.CourseEvent.self)
        return result
    }
}

enum LifeTrackSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        var result: [any PersistentModel.Type] = LifeTrackSchemaV1.models
        result.append(LifeTrackSchemaV3.CourseEvent.self)
        return result
    }
}

enum LifeTrackSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        var result: [any PersistentModel.Type] = LifeTrackSchemaV1.models
        result.append(LifeTrackSchemaV3.CourseEvent.self)
        result.append(LifeTrackSchemaV4.LifeInsightRecord.self)
        return result
    }
}

extension LifeTrackSchemaV4 {
    /// AI 生成的生活/学习轨迹洞察。
    @Model
    final class LifeInsightRecord {
        @Attribute(.unique) var id: UUID
        var kindRawValue: String
        var title: String
        var content: String
        var source: String
        var createdAt: Date

        init(kind: String, title: String, content: String, source: String = "agnes") {
            self.id = UUID()
            self.kindRawValue = kind
            self.title = title
            self.content = content
            self.source = source
            self.createdAt = .now
        }
    }
}

enum LifeTrackMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [LifeTrackSchemaV1.self, LifeTrackSchemaV2.self, LifeTrackSchemaV3.self, LifeTrackSchemaV4.self]
    }

    static var stages: [MigrationStage] {
        [
            MigrationStage.lightweight(fromVersion: LifeTrackSchemaV1.self,
                                       toVersion: LifeTrackSchemaV2.self),
            MigrationStage.lightweight(fromVersion: LifeTrackSchemaV2.self,
                                       toVersion: LifeTrackSchemaV3.self),
            MigrationStage.lightweight(fromVersion: LifeTrackSchemaV3.self,
                                       toVersion: LifeTrackSchemaV4.self)
        ]
    }
}

/// 业务代码始终使用最新 schema 中的洞察类型。
typealias LifeInsightRecord = LifeTrackSchemaV4.LifeInsightRecord

extension LifeTrackSchemaV4.LifeInsightRecord {
    /// 放在 `@Model` 宏之外，避免被 SwiftData 当成待持久字段。
    var kind: InsightKind { InsightKind(rawValue: kindRawValue) ?? .custom }
}
