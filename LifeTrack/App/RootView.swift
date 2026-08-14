import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var locationService = LocationService.shared
    @State private var didConfigureServices = false
    @State private var showOnboarding = !OnboardingState.hasSeenOnboarding
    @State private var selectedTab: RootTab = .today
    @StateObject private var assistantCenter = AssistantTaskCenter()

    var body: some View {
        TabView(selection: $selectedTab) {
            TodayView(locationService: locationService)
                .tabItem { Label("今日", systemImage: "location.fill") }
                .tag(RootTab.today)

            HistoryView()
                .tabItem { Label("轨迹", systemImage: "map") }
                .tag(RootTab.history)

            PlacesView(locationService: locationService)
                .tabItem { Label("地点", systemImage: "mappin.and.ellipse") }
                .tag(RootTab.places)

            InsightAssistantView()
                .tabItem { Label("助手", systemImage: "sparkles") }
                .tag(RootTab.assistant)

            SettingsView(locationService: locationService)
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(RootTab.settings)
        }
        .environmentObject(assistantCenter)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if assistantCenter.isGenerating && selectedTab != .assistant {
                Button { selectedTab = .assistant } label: {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI 管家正在查阅记录")
                                .font(.subheadline.weight(.semibold))
                            Text("可以继续使用 App，完成后回助手查看")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                }
                .buttonStyle(.plain)
            }
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

private enum RootTab: Hashable {
    case today, history, places, assistant, settings
}
