import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ActivitySession.startTime, order: .reverse) private var sessions: [ActivitySession]
    @Query(sort: \JourneyRecord.startTime, order: .reverse) private var journeys: [JourneyRecord]
    @State private var selectedActivity: ActivityFilter = .all
    @State private var selectedSection: TrackSection = .recorded
    @State private var isImportingGPX = false
    @State private var importMessage: String?

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
                case .journeys:
                    journeyList
                case .photos:
                    PhotoTrackView()
                }
            }
            .navigationTitle("轨迹")
            .toolbar {
                if selectedSection == .recorded {
                    ToolbarItem(placement: .topBarLeading) { EditButton() }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isImportingGPX = true
                        } label: {
                            Label("导入 GPX", systemImage: "square.and.arrow.down")
                        }
                    }
                }
            }
            .fileImporter(isPresented: $isImportingGPX,
                          allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml]) { result in
                do {
                    let url = try result.get()
                    let session = try GPXService.importFile(at: url, into: modelContext)
                    importMessage = "已导入 \(session.trackPoints.count) 个轨迹点。"
                } catch {
                    importMessage = error.localizedDescription
                }
            }
            .alert("GPX 导入", isPresented: importMessagePresented) {
                Button("好", role: .cancel) { importMessage = nil }
            } message: {
                Text(importMessage ?? "")
            }
        }
    }

    private var journeyList: some View {
        List(journeys) { journey in
            NavigationLink {
                JourneyDetailView(journey: journey,
                                  sessions: sessions.filter { journey.sessionIDs.contains($0.id) })
            } label: {
                JourneyRow(journey: journey)
            }
        }
        .overlay {
            if journeys.isEmpty {
                ContentUnavailableView("暂无自动出行",
                                       systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                       description: Text("完成轨迹记录后，连续移动会自动组合为一次出行。"))
            }
        }
    }

    private var importMessagePresented: Binding<Bool> {
        Binding(get: { importMessage != nil },
                set: { if !$0 { importMessage = nil } })
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
        case journeys
        case photos

        var id: String { rawValue }

        var title: String {
            switch self {
            case .recorded: "记录轨迹"
            case .journeys: "自动出行"
            case .photos: "照片轨迹"
            }
        }

        var symbolName: String {
            switch self {
            case .recorded: "figure.walk.motion"
            case .journeys: "point.topleft.down.to.point.bottomright.curvepath"
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
        let targets = offsets.map { sessions[$0] }
        let deletable = targets.filter { !$0.isActive }
        if deletable.count != targets.count {
            importMessage = "进行中的轨迹不能删除，请先结束记录。"
        }
        guard !deletable.isEmpty else { return }
        for session in deletable { modelContext.delete(session) }
        let saved = PersistenceService.save(modelContext,
                                            operation: "删除轨迹",
                                            failureRecovery: .rollback) { importMessage = $0 }
        if saved { JourneyGenerationService.refresh(in: modelContext) }
    }
}

private enum ActivityFilter: String, CaseIterable, Identifiable {
    case all
    case walking
    case running
    case cycling
    case automotive
    case transit
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
        case .transit: "公交地铁"
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
        case .transit: .transit
        case .stationary: .stationary
        case .unknown: .unknown
        }
    }

    static let activityOrder: [ActivityType] = [.walking, .running, .cycling, .automotive, .transit, .stationary, .unknown]
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
                HStack(spacing: 5) {
                    Text(session.activityType.displayName)
                    if session.sourceRawValue == "imported_gpx" {
                        Text("GPX")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.indigo)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.indigo.opacity(0.1), in: Capsule())
                    }
                }
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

private struct JourneyRow: View {
    let journey: JourneyRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: journey.primaryActivity.symbolName)
                .foregroundStyle(.indigo)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(routeTitle)
                    .lineLimit(1)
                Text(journey.startTime.formatted(.dateTime.month().day().hour().minute()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(Formatters.distance(journey.totalDistance))
                Text("\(journey.sessionIDs.count) 段")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var routeTitle: String {
        switch (journey.startPlace, journey.endPlace) {
        case let (start?, end?): "\(start) → \(end)"
        case let (start?, nil): "从 \(start) 出发"
        case let (nil, end?): "前往 \(end)"
        default: "\(journey.primaryActivity.displayName)出行"
        }
    }
}

private struct JourneyDetailView: View {
    let journey: JourneyRecord
    let sessions: [ActivitySession]
    @Query private var places: [CustomPlace]

    private var orderedSessions: [ActivitySession] {
        sessions.sorted { $0.startTime < $1.startTime }
    }

    private var mapPoints: [TrackMapPoint] {
        orderedSessions.flatMap(\.trackPoints)
            .sorted { $0.timestamp < $1.timestamp }
            .map(TrackMapPoint.init)
            .downsampledForMap()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !mapPoints.isEmpty {
                    TrackMapView(points: mapPoints, places: places, currentLocation: nil) { _ in }
                        .frame(height: 290)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal)
                }

                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        StatisticTile(title: "总距离",
                                      value: Formatters.distance(journey.totalDistance),
                                      symbol: "arrow.left.and.right")
                        StatisticTile(title: "总时长",
                                      value: Formatters.duration(journey.duration),
                                      symbol: "clock")
                    }
                    GridRow {
                        StatisticTile(title: "活动方式",
                                      value: journey.primaryActivity.displayName,
                                      symbol: journey.primaryActivity.symbolName)
                        StatisticTile(title: "移动段数",
                                      value: "\(journey.sessionIDs.count)",
                                      symbol: "point.3.connected.trianglepath.dotted")
                    }
                }
                .padding(.horizontal)

                VStack(alignment: .leading, spacing: 10) {
                    Text("行程组成").font(.headline)
                    ForEach(orderedSessions) { session in
                        NavigationLink {
                            SessionDetailView(session: session)
                        } label: {
                            SessionRow(session: session)
                                .padding(12)
                                .background(Color(uiColor: .secondarySystemBackground),
                                            in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .navigationTitle(routeTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var routeTitle: String {
        if let start = journey.startPlace, let end = journey.endPlace {
            return "\(start) → \(end)"
        }
        return "自动出行"
    }
}

struct SessionDetailView: View {
    let session: ActivitySession
    @Query private var places: [CustomPlace]
    @State private var sharedFile: SharedFile?
    @State private var exportError: String?

    private var mapPoints: [TrackMapPoint] {
        session.trackPoints.sorted { $0.timestamp < $1.timestamp }.map(TrackMapPoint.init).downsampledForMap()
    }

    private var anomalyCount: Int {
        session.trackPoints.filter(\.isAnomaly).count
    }

    private var orderedStays: [StayRecord] {
        session.stayRecords.sorted { $0.arrivalTime < $1.arrivalTime }
    }

    private var quality: TrajectoryQuality {
        TrajectoryQualityService.evaluate(session)
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
                trajectoryQualityCard
                if !orderedStays.isEmpty {
                    stayTimeline
                }
                samplingNote
            }
            .padding(.vertical)
        }
        .navigationTitle(session.activityType.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    TrackTrimView(session: session)
                } label: {
                    Label("修剪轨迹", systemImage: "slider.horizontal.3")
                }
                .disabled(session.isActive || session.trackPoints.count < 3)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    exportGPX()
                } label: {
                    Label("导出 GPX", systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(item: $sharedFile) { file in
            ShareSheet(items: [file.url])
        }
        .alert("无法导出 GPX", isPresented: exportErrorPresented) {
            Button("好", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "请稍后重试。")
        }
    }

    private var trajectoryQualityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("轨迹质量")
                    .font(.headline)
                Spacer()
                Label(quality.grade.displayName, systemImage: quality.grade.symbolName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(qualityColor)
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    qualityValue("总 GPS 点", "\(quality.totalPointCount)")
                    qualityValue("有效 / 异常", "\(quality.validPointCount) / \(quality.anomalyPointCount)")
                }
                GridRow {
                    qualityValue("异常比例", quality.anomalyRatio.formatted(.percent.precision(.fractionLength(1))))
                    qualityValue("最长中断", Formatters.duration(quality.longestLocationGap))
                }
                GridRow {
                    qualityValue("平均精度", String(format: "%.1f m", quality.averageHorizontalAccuracy))
                    qualityValue("最大误差", String(format: "%.1f m", quality.maximumHorizontalAccuracy))
                }
                GridRow {
                    qualityValue("原始距离", Formatters.distance(quality.totalDistance))
                    qualityValue("有效距离", Formatters.distance(quality.effectiveDistance))
                }
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func qualityValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.medium)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var qualityColor: Color {
        switch quality.grade {
        case .excellent: .green
        case .good: .teal
        case .fair: .orange
        case .poor: .red
        }
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

    private func exportGPX() {
        do {
            sharedFile = SharedFile(url: try GPXService.export(session: session))
        } catch {
            exportError = error.localizedDescription
        }
    }

    private var exportErrorPresented: Binding<Bool> {
        Binding(get: { exportError != nil },
                set: { if !$0 { exportError = nil } })
    }
}
