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

enum LifeTrackMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [LifeTrackSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}
