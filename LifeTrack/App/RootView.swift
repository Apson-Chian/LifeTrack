import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<ActivitySession> { $0.isActive }) private var activeSessions: [ActivitySession]
    @State private var locationService = LocationService.shared
    @State private var didRestoreSession = false

    var body: some View {
        TabView {
            TodayView(locationService: locationService)
                .tabItem { Label("今日", systemImage: "location.fill") }

            HistoryView()
                .tabItem { Label("轨迹", systemImage: "map") }

            PlacesView(locationService: locationService)
                .tabItem { Label("地点", systemImage: "mappin.and.ellipse") }

            SettingsView(locationService: locationService)
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .task {
            guard !didRestoreSession else { return }
            didRestoreSession = true
            locationService.configure(with: modelContext)
            if let session = activeSessions.first {
                locationService.restore(session: session)
            }
        }
    }
}
