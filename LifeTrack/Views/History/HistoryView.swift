import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ActivitySession.startTime, order: .reverse) private var sessions: [ActivitySession]
    @State private var selectedActivity: ActivityFilter = .all
    @State private var selectedSection: TrackSection = .recorded

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("轨迹来源", selection: $selectedSection) {
                    ForEach(TrackSection.allCases) { section in
                        Label(section.title, systemImage: section.symbolName).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)

                switch selectedSection {
                case .recorded:
                    recordedTrackList
                case .photos:
                    PhotoTrackView()
                }
            }
            .navigationTitle("轨迹")
            .toolbar {
                if selectedSection == .recorded {
                    EditButton()
                }
            }
        }
    }

    private var recordedTrackList: some View {
        List {
            Section {
                Picker("显示类型", selection: $selectedActivity) {
                    ForEach(ActivityFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .pickerStyle(.menu)
            }

            ForEach(groupedSessions, id: \.activity) { group in
                Section {
                    ForEach(group.sessions) { session in
                        NavigationLink { SessionDetailView(session: session) } label: { SessionRow(session: session) }
                    }
                    .onDelete { offsets in delete(from: group.sessions, at: offsets) }
                } header: {
                    Label(group.activity.displayName, systemImage: group.activity.symbolName)
                }
            }
        }
        .overlay {
            if filteredSessions.isEmpty {
                ContentUnavailableView("暂无轨迹", systemImage: "clock.arrow.circlepath", description: Text("开始记录后，按运动类型分类显示在这里。"))
            }
        }
    }

    private enum TrackSection: String, CaseIterable, Identifiable {
        case recorded
        case photos

        var id: String { rawValue }

        var title: String {
            switch self {
            case .recorded: "记录轨迹"
            case .photos: "照片轨迹"
            }
        }

        var symbolName: String {
            switch self {
            case .recorded: "figure.walk.motion"
            case .photos: "photo.on.rectangle.angled"
            }
        }
    }

    private var filteredSessions: [ActivitySession] {
        guard let activity = selectedActivity.activityType else { return sessions }
        return sessions.filter { $0.activityType == activity }
    }

    private var groupedSessions: [(activity: ActivityType, sessions: [ActivitySession])] {
        let groups = Dictionary(grouping: filteredSessions) { $0.activityType }
        return ActivityFilter.activityOrder.compactMap { activity in
            guard let sessions = groups[activity]?.sorted(by: { $0.startTime > $1.startTime }), !sessions.isEmpty else { return nil }
            return (activity, sessions)
        }
    }

    private func delete(from sessions: [ActivitySession], at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(sessions[index])
        }
        try? modelContext.save()
    }
}

private enum ActivityFilter: String, CaseIterable, Identifiable {
    case all
    case walking
    case running
    case cycling
    case automotive
    case stationary
    case unknown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all: "全部"
        case .walking: "步行"
        case .running: "跑步"
        case .cycling: "骑行"
        case .automotive: "驾车"
        case .stationary: "静止"
        case .unknown: "未知"
        }
    }

    var activityType: ActivityType? {
        switch self {
        case .all: nil
        case .walking: .walking
        case .running: .running
        case .cycling: .cycling
        case .automotive: .automotive
        case .stationary: .stationary
        case .unknown: .unknown
        }
    }

    static let activityOrder: [ActivityType] = [.walking, .running, .cycling, .automotive, .stationary, .unknown]
}

private extension Date {
    var chineseRecordTime: String {
        formatted(.dateTime.month().day().hour().minute())
    }
}

struct SessionRow: View {
    let session: ActivitySession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.activityType.symbolName)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.activityType.displayName)
                Text(session.startTime.chineseRecordTime)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(Formatters.distance(session.distance))
                Text(Formatters.duration(session.duration)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct SessionDetailView: View {
    let session: ActivitySession
    @Query private var places: [CustomPlace]

    private var mapPoints: [TrackMapPoint] {
        session.trackPoints.sorted { $0.timestamp < $1.timestamp }.map(TrackMapPoint.init)
    }

    private var anomalyCount: Int {
        session.trackPoints.filter(\.isAnomaly).count
    }

    private var orderedStays: [StayRecord] {
        session.stayRecords.sorted { $0.arrivalTime < $1.arrivalTime }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                TrackMapView(points: mapPoints, places: places, currentLocation: nil) { _ in }
                    .frame(height: 290)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        StatisticTile(title: "距离", value: Formatters.distance(session.distance), symbol: "arrow.left.and.right")
                        StatisticTile(title: "时长", value: Formatters.duration(session.duration), symbol: "clock")
                    }
                    GridRow {
                        StatisticTile(title: "有效轨迹点",
                                      value: "\(session.trackPoints.count - anomalyCount)",
                                      symbol: "point.3.connected.trianglepath.dotted")
                        StatisticTile(title: session.activityType == .running ? "配速" : "均速", value: metric, symbol: session.activityType.symbolName)
                    }
                }
                .padding(.horizontal)
                if !orderedStays.isEmpty {
                    stayTimeline
                }
                samplingNote
            }
            .padding(.vertical)
        }
        .navigationTitle(session.activityType.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var metric: String {
        if session.activityType == .running { return Formatters.pace(distance: session.distance, duration: session.duration) }
        guard session.duration > 0 else { return "--" }
        return String(format: "%.1f 公里/小时", session.distance / session.duration * 3.6)
    }

    private var samplingNote: some View {
        Text(anomalyCount == 0
             ? "已根据\(session.activityType.displayName)调整定位频率。距离只统计筛选后的有效定位点。"
             : "已自动排除 \(anomalyCount) 个疑似漂移点；原始点仍保留，可用于后续重新分析。")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
    }

    private var stayTimeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("停留记录")
                .font(.headline)

            ForEach(orderedStays) { stay in
                HStack(spacing: 12) {
                    Image(systemName: stay.customPlaceID == nil ? "mappin.circle" : "mappin.circle.fill")
                        .foregroundStyle(.teal)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(stay.detectedName ?? "未命名停留")
                            .font(.subheadline.weight(.semibold))
                        Text(stayTime(stay))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Formatters.duration(stay.duration))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal)
    }

    private func stayTime(_ stay: StayRecord) -> String {
        let arrival = stay.arrivalTime.formatted(.dateTime.hour().minute())
        guard let departure = stay.departureTime else { return "\(arrival) 起" }
        return "\(arrival)–\(departure.formatted(.dateTime.hour().minute()))"
    }
}
