import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var locationService = LocationService.shared
    @State private var didConfigureServices = false
    @State private var showOnboarding = !OnboardingState.hasSeenOnboarding
    @SceneStorage("root.selectedTab") private var selectedTabRawValue = RootTab.today.rawValue
    @StateObject private var assistantCenter = AssistantTaskCenter()

    var body: some View {
        TabView(selection: selectedTabBinding) {
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
        .tint(isInstrumentDarkMode ? InstrumentPalette.lime : .indigo)
        .toolbar(isInstrumentDarkMode ? .hidden : .visible, for: .tabBar)
        .environmentObject(assistantCenter)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if assistantCenter.isGenerating && selectedTab != .assistant {
                    Button { selectedTabRawValue = RootTab.assistant.rawValue } label: {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("AI 管家正在查阅记录")
                                    .font(.subheadline.weight(.semibold))
                                Text("可以继续使用 App，完成后回助手查看")
                                    .font(.caption)
                                    .foregroundStyle(isInstrumentDarkMode ? InstrumentPalette.textMuted : .secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isInstrumentDarkMode ? InstrumentPalette.textMuted : Color.secondary.opacity(0.7))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .foregroundStyle(isInstrumentDarkMode ? InstrumentPalette.textPrimary : .primary)
                        .background {
                            if isInstrumentDarkMode {
                                InstrumentPalette.surface
                            } else {
                                Rectangle().fill(.ultraThinMaterial)
                            }
                        }
                        .overlay(alignment: .top) {
                            Rectangle()
                                .fill(InstrumentPalette.border)
                                .frame(height: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }

                if isInstrumentDarkMode {
                    instrumentTabBar
                }
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

    private var selectedTab: RootTab {
        RootTab(rawValue: selectedTabRawValue) ?? .today
    }

    private var isInstrumentDarkMode: Bool { colorScheme == .dark }

    private var selectedTabBinding: Binding<RootTab> {
        Binding(
            get: { selectedTab },
            set: { selectedTabRawValue = $0.rawValue }
        )
    }

    private var instrumentTabBar: some View {
        HStack(spacing: 0) {
            ForEach(RootTab.allCases, id: \.self) { tab in
                Button {
                    selectedTabRawValue = tab.rawValue
                } label: {
                    VStack(spacing: 4) {
                        Rectangle()
                            .fill(selectedTab == tab ? InstrumentPalette.lime : .clear)
                            .frame(height: 3)
                        Image(systemName: tab.symbol)
                            .font(.system(size: 18, weight: .bold))
                        Text(tab.title)
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(selectedTab == tab ? InstrumentPalette.lime : InstrumentPalette.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 4)
        .background(InstrumentPalette.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(InstrumentPalette.border)
                .frame(height: 1)
        }
    }
}

private enum RootTab: String, Hashable, CaseIterable {
    case today, history, places, assistant, settings

    var title: String {
        switch self {
        case .today: "今日"
        case .history: "轨迹"
        case .places: "地点"
        case .assistant: "助手"
        case .settings: "设置"
        }
    }

    var symbol: String {
        switch self {
        case .today: "location.fill"
        case .history: "point.3.connected.trianglepath.dotted"
        case .places: "mappin.and.ellipse"
        case .assistant: "sparkles"
        case .settings: "gearshape"
        }
    }
}
