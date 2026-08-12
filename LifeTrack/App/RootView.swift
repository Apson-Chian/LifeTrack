import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var locationService = LocationService.shared
    @State private var didConfigureServices = false

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
            guard !didConfigureServices else { return }
            didConfigureServices = true
            locationService.configure(with: modelContext)
            JourneyGenerationService.refresh(in: modelContext)
        }
    }
}
