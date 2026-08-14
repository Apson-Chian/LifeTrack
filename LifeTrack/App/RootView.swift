import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var locationService = LocationService.shared
    @State private var didConfigureServices = false
    @State private var showOnboarding = !OnboardingState.hasSeenOnboarding

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
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .inactive || phase == .background {
                locationService.flushPendingTrackDataIfNeeded(force: true)
            }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView()
        }
    }
}
