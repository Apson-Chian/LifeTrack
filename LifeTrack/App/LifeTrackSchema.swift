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
        result.append(CourseEvent.self)
        return result
    }
}

enum LifeTrackMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [LifeTrackSchemaV1.self, LifeTrackSchemaV2.self]
    }

    static var stages: [MigrationStage] {
        [
            MigrationStage.lightweight(fromVersion: LifeTrackSchemaV1.self,
                                       toVersion: LifeTrackSchemaV2.self)
        ]
    }
}
