import SwiftUI
import SwiftData
import CoreLocation

struct PhotoTravelTimelineView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TravelTimelineTrip.startTime, order: .reverse) private var trips: [TravelTimelineTrip]
    @Query(sort: \ActivitySession.startTime, order: .forward) private var sessions: [ActivitySession]
    @Query private var places: [CustomPlace]
    @Query private var stays: [StayRecord]

    @State private var selectedTripID: UUID?
    @State private var selectedNodeID: UUID?
    @State private var cameraRequest: MapCameraRequest?
    @State private var isRefreshing = false
    @State private var isRestoringHistory = false
    @State private var statusMessage: String?
    @State private var selectedPhoto: PhotoDetailItem?

    private var selectedTrip: TravelTimelineTrip? {
        if let selectedTripID, let selected = trips.first(where: { $0.id == selectedTripID }) {
            return selected
        }
        return trips.first
    }

    private var orderedNodes: [TravelTimelineNode] {
        selectedTrip?.nodes.sorted { $0.startTime < $1.startTime } ?? []
    }

    private var mapPoints: [TrackMapPoint] {
        guard let routePoints = selectedTrip?.routePoints else { return [] }
        var segmentID = 0
        var previousDate: Date?
        return routePoints.map { point in
            if let previousDate, point.timestamp.timeIntervalSince(previousDate) > 30 * 60 {
                segmentID += 1
            }
            previousDate = point.timestamp
            return TrackMapPoint(coordinate: point.coordinate,
                                 timestamp: point.timestamp,
                                 activityType: point.activityType,
                                 segmentID: segmentID,
                                 horizontalAccuracy: 1,
                                 source: .sample)
        }
    }

    var body: some View {
        ScrollView {
            if isRefreshing && trips.isEmpty {
                ProgressView("正在本机生成旅行时间轴…")
                    .frame(maxWidth: .infinity, minHeight: 460)
            } else if let trip = selectedTrip {
                VStack(alignment: .leading, spacing: 16) {
                    tripSelector(trip)
                    routeMap
                    tripSummary(trip)
                    timeline
                }
                .padding()
            } else {
                ContentUnavailableView("还没有可生成的旅行",
                                       systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                       description: Text("记录一段 GPS 轨迹，或为照片保留拍摄时间和地点后，会自动生成旅行时间轴。"))
                    .frame(minHeight: 520)
                    .padding()
            }
        }
        .navigationTitle("旅行时间轴")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await refreshTimeline()
                        await restoreHistoricalTrips()
                    }
                } label: {
                    if isRefreshing || isRestoringHistory {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing || isRestoringHistory)
                .accessibilityLabel("增量更新旅行时间轴")
            }
        }
        .task {
            if selectedTripID == nil { selectedTripID = trips.first?.id }
            // 先即时读取缓存，再在后台枚举照片时间/GPS 元数据恢复旧行程；不加载图片或运行 Vision。
            await rebuildFromCache()
            await restoreHistoricalTrips()
        }
        .onChange(of: selectedTripID) { _, _ in
            selectedNodeID = nil
            cameraRequest = MapCameraRequest(target: .route)
        }
        .sheet(item: $selectedPhoto) { item in
            PhotoDetailView(item: item)
        }
    }

    private func tripSelector(_ trip: TravelTimelineTrip) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(trip.title)
                    .font(.title2.weight(.bold))
                Text(tripDateText(trip))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if trips.count > 1 {
                Menu {
                    ForEach(trips) { item in
                        Button {
                            selectedTripID = item.id
                        } label: {
                            if item.id == trip.id {
                                Label(item.title, systemImage: "checkmark")
                            } else {
                                Text(item.title)
                            }
                        }
                    }
                } label: {
                    Label("选择旅行", systemImage: "calendar")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var routeMap: some View {
        ZStack(alignment: .topTrailing) {
            TrackMapView(points: mapPoints,
                         places: [],
                         currentLocation: nil,
                         cameraRequest: cameraRequest,
                         style: .vivid,
                         focusedCoordinate: orderedNodes.first(where: { $0.id == selectedNodeID })?.coordinate) { _ in }
                .frame(height: 310)
                .clipShape(RoundedRectangle(cornerRadius: 20))

            Button {
                cameraRequest = MapCameraRequest(target: .route)
                selectedNodeID = nil
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.subheadline.weight(.semibold))
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(12)
            .accessibilityLabel("显示完整旅行轨迹")
        }
    }

    private func tripSummary(_ trip: TravelTimelineTrip) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("旅行概览")
                    .font(.headline)
                Spacer()
                Text("本地缓存")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.indigo)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.indigo.opacity(0.1), in: Capsule())
            }

            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    TimelineMetric(title: "总距离", value: distanceText(trip.totalDistance), symbol: "map")
                    TimelineMetric(title: "总时长", value: durationText(trip.duration), symbol: "clock")
                }
                GridRow {
                    TimelineMetric(title: "停留节点", value: "\(orderedNodes.filter { $0.kind == .stay }.count)", symbol: "mappin.circle")
                    TimelineMetric(title: "照片", value: "\(Set(orderedNodes.flatMap(\.photoIdentifiers)).count)", symbol: "photo.stack")
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if ProcessInfo.processInfo.isLowPowerModeEnabled {
                Label("低电量模式下保留已有缓存，新照片将在关闭后分析。", systemImage: "battery.25percent")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("行程节点")
                .font(.headline)

            LazyVStack(spacing: 0) {
                ForEach(Array(orderedNodes.enumerated()), id: \.element.id) { index, node in
                    TravelTimelineNodeRow(node: node,
                                          isSelected: node.id == selectedNodeID,
                                          isLast: index == orderedNodes.count - 1,
                                          onPhotoTap: showPhoto) {
                        selectedNodeID = node.id
                        cameraRequest = MapCameraRequest(target: .coordinate(lat: node.latitude,
                                                                             lon: node.longitude))
                    }
                }
            }
        }
    }

    private func refreshTimeline() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        statusMessage = "正在比较新增照片和轨迹…"
        let summary = await TravelTimelineGenerationService.refresh(context: modelContext,
                                                                     sessions: sessions)
        let descriptor = FetchDescriptor<TravelTimelineTrip>(sortBy: [SortDescriptor(\TravelTimelineTrip.startTime,
                                                                                     order: .reverse)])
        let refreshedTrips = (try? modelContext.fetch(descriptor)) ?? []
        if selectedTripID == nil || !refreshedTrips.contains(where: { $0.id == selectedTripID }) {
            selectedTripID = refreshedTrips.first?.id
        }
        cameraRequest = refreshedTrips.isEmpty ? nil : MapCameraRequest(target: .route)
        if summary.updatedTripCount == 0 && summary.analyzedPhotoCount == 0 {
            statusMessage = "未发现新增数据，已直接读取 SwiftData 缓存。"
        } else {
            var parts: [String] = []
            if summary.updatedTripCount > 0 { parts.append("更新 \(summary.updatedTripCount) 次旅行") }
            if summary.analyzedPhotoCount > 0 { parts.append("分析 \(summary.analyzedPhotoCount) 张新照片") }
            statusMessage = parts.joined(separator: "，") + "。"
        }
        isRefreshing = false
    }

    private func rebuildFromCache() async {
        guard !isRefreshing else { return }
        let summary = await TravelTimelineGenerationService.rebuildFromCache(context: modelContext,
                                                                              sessions: sessions)
        let descriptor = FetchDescriptor<TravelTimelineTrip>(sortBy: [SortDescriptor(\TravelTimelineTrip.startTime,
                                                                                     order: .reverse)])
        let refreshedTrips = (try? modelContext.fetch(descriptor)) ?? []
        if selectedTripID == nil || !refreshedTrips.contains(where: { $0.id == selectedTripID }) {
            selectedTripID = refreshedTrips.first?.id
        }
        if summary.updatedTripCount > 0 {
            statusMessage = "已从现有 GPS 和照片缓存补回 \(summary.updatedTripCount) 次行程。"
        }
    }

    private func restoreHistoricalTrips() async {
        guard !isRestoringHistory else { return }
        isRestoringHistory = true
        let summary = await TravelTimelineGenerationService.rebuildFromPhotoMetadata(context: modelContext,
                                                                                      sessions: sessions,
                                                                                      places: places,
                                                                                      stays: stays)
        if summary.updatedTripCount > 0 {
            statusMessage = "已根据日常活动圈从历史照片元数据恢复 \(summary.updatedTripCount) 次异地行程。"
        }
        if selectedTripID == nil { selectedTripID = trips.first?.id }
        isRestoringHistory = false
    }

    private func showPhoto(_ identifier: String, date: Date, coordinate: CLLocationCoordinate2D?) {
        selectedPhoto = PhotoDetailItem(assetIdentifier: identifier,
                                        creationDate: date,
                                        coordinate: coordinate)
    }

    private func tripDateText(_ trip: TravelTimelineTrip) -> String {
        if Calendar.current.isDate(trip.startTime, inSameDayAs: trip.endTime) {
            return trip.startTime.formatted(.dateTime.year().month().day().weekday(.wide))
        }
        return "\(trip.startTime.formatted(.dateTime.year().month().day())) – \(trip.endTime.formatted(.dateTime.year().month().day()))"
    }
}

private struct TravelTimelineNodeRow: View {
    let node: TravelTimelineNode
    let isSelected: Bool
    let isLast: Bool
    let onPhotoTap: (String, Date, CLLocationCoordinate2D?) -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(node.kind == .stay ? Color.indigo : activityColor)
                        .frame(width: 30, height: 30)
                    Image(systemName: node.kind == .stay ? "mappin" : node.activityType.symbolName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                }
                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 2, height: 132)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(timeText)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(node.kind == .stay ? durationText(node.duration) : distanceText(node.distance))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(node.kind == .stay ? Color.indigo : activityColor)
                        Button(action: onSelect) {
                            Image(systemName: "map")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("在地图中定位")
                    }

                    Label(locationText, systemImage: node.kind == .stay ? "mappin.and.ellipse" : "arrow.right")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if node.kind == .movement {
                        HStack(spacing: 12) {
                            Label("\(node.activityType.displayName) · \(durationText(node.duration))",
                                  systemImage: node.activityType.symbolName)
                            Label("\(node.photoIdentifiers.count) 张照片", systemImage: "photo")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 12) {
                            Label("停留 \(durationText(node.duration))", systemImage: "clock")
                            Label("\(node.photoIdentifiers.count) 张照片", systemImage: "photo")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if !node.categories.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(node.categories.prefix(5)) { category in
                                    Label(category.title, systemImage: category.symbolName)
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(categoryColor(category).opacity(0.12), in: Capsule())
                                        .foregroundStyle(categoryColor(category))
                                }
                            }
                        }
                    }

                    if !node.photoIdentifiers.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(Array(node.photoIdentifiers.prefix(3)), id: \.self) { identifier in
                                Button {
                                    onPhotoTap(identifier, node.startTime, node.coordinate)
                                } label: {
                                    PhotoSquareThumbnail(assetIdentifier: identifier, cornerRadius: 10)
                                        .frame(width: 76)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("查看照片详情")
                            }
                            if node.photoIdentifiers.count > 3 {
                                Text("+\(node.photoIdentifiers.count - 3)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.indigo : Color.clear, lineWidth: 2)
            }
            .padding(.bottom, 12)
        }
    }

    private var timeText: String {
        if node.startTime == node.endTime {
            return node.startTime.formatted(.dateTime.hour().minute())
        }
        return "\(node.startTime.formatted(.dateTime.hour().minute())) – \(node.endTime.formatted(.dateTime.hour().minute()))"
    }

    private var locationText: String {
        let start = node.placeName ?? coordinateText(node.coordinate)
        if node.kind == .movement {
            let end = node.endPlaceName ?? node.endingCoordinate.map(coordinateText) ?? "下一站"
            return "\(start) → \(end)"
        }
        return start
    }

    private var activityColor: Color {
        switch node.activityType {
        case .walking: .blue
        case .running: .orange
        case .cycling: .green
        case .automotive: .purple
        case .transit: .teal
        case .stationary: .indigo
        case .unknown: .gray
        }
    }
}

private struct TimelineMetric: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

private func durationText(_ duration: TimeInterval) -> String {
    let totalMinutes = max(0, Int(duration / 60))
    if totalMinutes < 1 { return "<1 分钟" }
    if totalMinutes < 60 { return "\(totalMinutes) 分钟" }
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    return minutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes) 分"
}

private func distanceText(_ distance: CLLocationDistance) -> String {
    if distance < 1_000 { return "\(Int(distance.rounded())) 米" }
    return String(format: "%.1f 公里", distance / 1_000)
}

private func coordinateText(_ coordinate: CLLocationCoordinate2D) -> String {
    String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
}

private func categoryColor(_ category: PhotoSmartCategory) -> Color {
    switch category {
    case .landscape: .teal
    case .architecture: .blue
    case .food: .orange
    case .people: .pink
    case .animal: .brown
    case .plant: .green
    case .sport: .red
    case .selfie: .purple
    case .night: .indigo
    case .other: .gray
    }
}
