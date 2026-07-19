import SwiftUI
import SwiftData

@main
struct LifeTrackApp: App {
    private let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            ActivitySession.self,
            TrackPoint.self,
            CustomPlace.self,
            StayRecord.self,
            DailySummary.self
        ])
        let configuration = ModelConfiguration("LifeTrack", schema: schema)

        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            fatalError("Unable to create LifeTrack data store: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(sharedModelContainer)
    }
}
