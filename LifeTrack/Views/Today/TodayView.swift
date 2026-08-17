import SwiftUI
import SwiftData
import CoreLocation
import Photos
import UIKit

struct TodayView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var locationService: LocationService
    @Query(sort: \ActivitySession.startTime, order: .reverse) private var sessions: [ActivitySession]
    @Query(sort: \CustomPlace.shortName) private var places: [CustomPlace]
    @State private var placeDraft: PlaceDraft?
    @State private var showDestinationSearch = false
    @State private var manualActivity: ActivityType?
    @State private var showActivityPicker = false
    @State private var showAmapUnavailable = false
    @State private var showTodayTrackDetail = false
    @State private var pendingPlaceFromCurrentLocation = false
    @State private var mapCameraRequest: MapCameraRequest?
    @State private var photoDescriptors: [PhotoLibraryAssetDescriptor] = []
    @State private var photoAuthorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var isLoadingPhotos = false
    @State private var selectedTrackPhoto: PhotoDetailItem?
    @State private var showMarkdownExportSheet = false

    private var todaySessions: [ActivitySession] {
        sessions.filter { Calendar.current.isDateInToday($0.startTime) }
    }
    private var activeOrLatestSession: ActivitySession? { locationService.activeSession ?? todaySessions.first }
    private var todayPoints: [TrackPoint] {
        todaySessions.flatMap(\.trackPoints).sorted { $0.timestamp < $1.timestamp }
    }
    private var todayMapPoints: [TrackMapPoint] {
        todayPoints.map(TrackMapPoint.init)
    }
    private var totalDistance: Double { todaySessions.reduce(0) { $0 + $1.distance } }
    private var activeDuration: TimeInterval { todaySessions.reduce(0) { $0 + $1.duration } }
    private var todayPhotoMoments: [TrackPhotoMoment] {
        TodayPhotoTrackService.moments(descriptors: photoDescriptors, sessions: todaySessions)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    dayHeader
                    recordingHero
                    summary
                    todayMap
                    quickActions
                    todayPhotoStory
                    secondBrainCard
                    AssistantFeatureCard(
                        context: .today,
                        title: "让 AI 分析今天的运动",
                        subtitle: "结合今日轨迹、停留与过去记录回答问题"
                    )
                    .padding(.horizontal)
                    activityBreakdown
                }
                .padding(.vertical, 12)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("今日")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showMarkdownExportSheet = true } label: {
                            Label("导出今日 Markdown 日记", systemImage: "doc.text.badge.plus")
                        }
                        Button { showDestinationSearch = true } label: {
                            Label("高德导航", systemImage: "location.north.line")
                        }
                        Button {
                            markCurrentLocation()
                        } label: {
                            Label("标记当前位置", systemImage: "mappin.circle.fill")
                        }
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showMarkdownExportSheet) {
                DailyMarkdownExportSheet(date: Date(), photoDescriptors: photoDescriptors)
            }
            .sheet(item: $placeDraft) { draft in
                PlaceEditorView(coordinate: draft.coordinate)
            }
            .sheet(isPresented: $showDestinationSearch) {
                DestinationSearchView { destination in
                    openAMapNavigation(to: destination.coordinate, name: destination.name)
                }
            }
            .sheet(isPresented: $showActivityPicker) {
                ActivityPickerSheet(selection: manualActivity) { activity in
                    selectActivity(activity)
                    showActivityPicker = false
                }
                .presentationDetents([.height(360)])
                .presentationDragIndicator(.visible)
            }
            .sheet(item: $selectedTrackPhoto) { item in
                PhotoDetailView(item: item) { identifier in
                    photoDescriptors.removeAll { $0.id == identifier }
                }
            }
            .alert("未安装高德地图", isPresented: $showAmapUnavailable) {
                Button("好", role: .cancel) { }
            } message: {
                Text("安装高德地图后可开始导航。LifeTrack 会独立保存本地轨迹。")
            }
            .alert("操作未完成", isPresented: criticalErrorPresented) {
                if locationService.recordingState == .stopFailed {
                    Button("重试保存") { locationService.retryStopRecording() }
                }
                if locationService.authorizationStatus == .denied ||
                    locationService.authorizationStatus == .restricted {
                    Button("打开系统设置") { openSystemSettings() }
                }
                Button("好", role: .cancel) { locationService.clearCriticalError() }
            } message: {
                Text(locationService.lastCriticalError ?? "请稍后重试。")
            }
            .navigationDestination(isPresented: $showTodayTrackDetail) {
                TodayTrackDetailView(sessions: todaySessions,
                                     places: places,
                                     currentLocation: locationService.currentLocation,
                                     photoMoments: todayPhotoMoments,
                                     onLongPress: { coordinate in
                                         placeDraft = PlaceDraft(coordinate: coordinate)
                                     })
            }
            .onChange(of: locationService.currentLocation) { _, location in
                guard pendingPlaceFromCurrentLocation, let coordinate = location?.coordinate else { return }
                pendingPlaceFromCurrentLocation = false
                placeDraft = PlaceDraft(coordinate: coordinate)
            }
            .task { await loadTodayPhotos(requestAccess: false) }
            .onReceive(NotificationCenter.default.publisher(for: .lifeTrackPhotoLibraryDidChange)) { _ in
                Task { await loadTodayPhotos(requestAccess: false) }
            }
        }
    }

    private var dayHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Date.now.formatted(.dateTime.month().day().weekday(.wide)))
                    .font(.title3.weight(.semibold))
                Text(todaySessions.isEmpty ? "从一次轻松的移动开始" : "今天的足迹正在慢慢成形")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(todaySessions.isEmpty ? "尚未开始" : "\(todaySessions.count) 次记录")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
        }
        .padding(.horizontal)
    }

    private var recordingHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: statusSymbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(locationService.activeSession == nil ? Color.indigo : Color.red)
                    .frame(width: 38, height: 38)
                    .background((locationService.activeSession == nil ? Color.indigo : Color.red).opacity(0.1), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(locationService.activeSession == nil ? "轨迹与运动数据仅保存在这台设备" : "保持移动，LifeTrack 正在记录你的路线")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button {
                    showActivityPicker = true
                } label: {
                    HStack(spacing: 5) {
                        Text(manualActivity?.displayName ?? "自动识别")
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .foregroundStyle(.primary)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("选择活动类型")
            }

            recordingAction

            if locationService.needsBackgroundWarning {
                VStack(alignment: .leading, spacing: 8) {
                    Label("锁屏后轨迹可能中断", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                    Text("当前只有“使用 App 时”定位权限。若需要后台持续记录，请升级为“始终允许”。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("允许后台持续记录") {
                        locationService.requestBackgroundAuthorization()
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.orange)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        }
        .padding(.horizontal)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: locationService.activeSession != nil)
    }

    @ViewBuilder
    private var recordingAction: some View {
        if locationService.recordingState == .stopping {
            HStack {
                ProgressView().tint(.indigo)
                Text("正在安全结束记录…")
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(.secondary)
            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        } else if locationService.recordingState == .stopFailed {
            Button { locationService.retryStopRecording() } label: {
                Label("重试结束保存", systemImage: "arrow.clockwise.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .background(.red, in: RoundedRectangle(cornerRadius: 12))
        } else if locationService.activeSession == nil {
            Button { locationService.startRecording(manualActivity: manualActivity) } label: {
                Label("开始记录", systemImage: "record.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .background(.indigo, in: RoundedRectangle(cornerRadius: 12))
        } else {
            Button(role: .destructive) { locationService.stopRecording() } label: {
                Label("结束并保存", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .background(.red, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var todayMap: some View {
        ZStack {
            TrackMapView(points: todayMapPoints,
                         places: places,
                         currentLocation: locationService.currentLocation,
                         cameraRequest: mapCameraRequest,
                         photoMoments: todayPhotoMoments,
                         onPhotoTap: showPhoto,
                         onLongPress: { coordinate in
                             placeDraft = PlaceDraft(coordinate: coordinate)
                         })
            .frame(height: 210)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("今日轨迹")
                        .font(.subheadline.weight(.semibold))
                    Text(todayMapPoints.isEmpty ? "开始记录后，路线会出现在这里" : "已记录 \(todayMapPoints.count) 个轨迹点")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.94), in: RoundedRectangle(cornerRadius: 12))
                .padding(8)
            }
            .overlay(alignment: .topTrailing) {
                MapControlsPanel {
                    MapControlButton(symbol: "location.fill", title: "定位到当前位置") {
                        focusCurrentLocation()
                    }

                    MapControlButton(symbol: "point.3.connected.trianglepath.dotted", title: "显示完整轨迹") {
                        showFullTrack()
                    }

                    MapControlButton(symbol: "plus.circle.fill", title: "标记当前位置") {
                        markCurrentLocation()
                    }
                }
                .padding(8)
            }
        }
        .padding(.horizontal)
    }

    private var quickActions: some View {
        HStack(spacing: 10) {
            NavigationLink {
                TodayTrackDetailView(sessions: todaySessions,
                                     places: places,
                                     currentLocation: locationService.currentLocation,
                                     photoMoments: todayPhotoMoments,
                                     onLongPress: { coordinate in
                                         placeDraft = PlaceDraft(coordinate: coordinate)
                                     })
            } label: {
                Label("查看今日轨迹", systemImage: "point.3.connected.trianglepath.dotted")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(HomeActionButtonStyle(tint: .indigo))

            Button {
                showDestinationSearch = true
            } label: {
                Label("高德导航", systemImage: "location.north.line")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(HomeActionButtonStyle(tint: .orange))
        }
        .padding(.horizontal)
    }

    private var criticalErrorPresented: Binding<Bool> {
        Binding(
            get: { locationService.lastCriticalError != nil },
            set: { isPresented in
                if !isPresented { locationService.clearCriticalError() }
            }
        )
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                SummaryMetric(title: "距离", value: Formatters.distance(totalDistance), symbol: "arrow.left.and.right", tint: .indigo)
                SummaryMetric(title: "时长", value: Formatters.duration(activeDuration), symbol: "clock.fill", tint: .blue)
                SummaryMetric(title: "停留", value: "\(todaySessions.flatMap(\.stayRecords).count)", symbol: "mappin.circle.fill", tint: .orange)
                SummaryMetric(title: "照片", value: "\(todayPhotoMoments.count)", symbol: "photo.fill", tint: .pink)
            }
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal)
    }

    @ViewBuilder
    private var todayPhotoStory: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("今日足迹故事").font(.headline)
                    Text("GPS 描绘路线，照片补全沿途时刻")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isLoadingPhotos { ProgressView().controlSize(.small) }
            }

            if !todayPhotoMoments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(todayPhotoMoments) { moment in
                            Button { showPhoto(moment.assetIdentifier) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    PhotoGalleryThumbnailView(assetIdentifier: moment.assetIdentifier,
                                                              cornerRadius: 10)
                                        .frame(width: 86, height: 86)
                                    Text(moment.creationDate, style: .time)
                                        .font(.caption.weight(.medium))
                                    Label(moment.usesPhotoLocation ? "照片定位" : "按时间匹配",
                                          systemImage: moment.usesPhotoLocation ? "mappin" : "clock")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 86, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                switch photoAuthorization {
                case .notDetermined:
                    Button { Task { await loadTodayPhotos(requestAccess: true) } } label: {
                        Label("允许照片参与今日轨迹", systemImage: "photo.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                case .denied, .restricted:
                    Button("到系统设置允许照片访问", action: openSystemSettings)
                        .buttonStyle(.bordered)
                default:
                    Text(todaySessions.isEmpty ? "开始记录运动后，沿途照片会自动出现在对应轨迹节点。" : "今天还没有与运动时间和路线匹配的照片。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
    }

    private var secondBrainCard: some View {
        Button {
            showMarkdownExportSheet = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(colors: [Color.indigo, Color.purple.opacity(0.85)],
                                           startPoint: .topLeading,
                                           endPoint: .bottomTrailing)
                        )
                        .frame(width: 42, height: 42)
                    Image(systemName: "doc.plaintext.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("联动第二大脑")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text("Obsidian / Notion")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.indigo.opacity(0.08), in: Capsule())
                    }
                    Text("一键复制或导出今日标准 Markdown 日记与时间线")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color.indigo.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.03), radius: 6, x: 0, y: 2)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    private var activityBreakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("活动分布").font(.headline)
            ForEach([ActivityType.walking, .running, .cycling, .automotive, .transit]) { type in
                let value = distance(for: type)
                HStack {
                    Image(systemName: type.symbolName).frame(width: 24)
                    Text(type.displayName)
                    Spacer()
                    Text(Formatters.distance(value)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
    }

    private func distance(for activity: ActivityType) -> Double {
        todaySessions.reduce(0) { total, session in
            let points = session.trackPoints
                .filter { $0.activityType == activity && $0.isUsableForAnalysis }
                .sorted { $0.timestamp < $1.timestamp }
            guard points.count > 1 else { return total }
            let distance = zip(points, points.dropFirst()).reduce(0) { partial, pair in
                let interval = pair.1.timestamp.timeIntervalSince(pair.0.timestamp)
                guard interval > 0, interval <= 30 * 60 else { return partial }
                let segment = CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                    .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
                guard segment / interval <= 55 else { return partial }
                return partial + segment
            }
            return total + distance
        }
    }

    private var statusTitle: String {
        if locationService.activeSession != nil {
            return "正在记录 \(locationService.currentActivity.displayName)"
        }
        if let manualActivity {
            return "准备记录 \(manualActivity.displayName)"
        }
        return "未记录"
    }

    private var statusSymbol: String {
        if locationService.activeSession != nil {
            return locationService.currentActivity.symbolName
        }
        return manualActivity?.symbolName ?? "pause.circle"
    }

    private func selectActivity(_ activity: ActivityType?) {
        manualActivity = activity
        locationService.setManualActivity(activity)
    }

    private func focusCurrentLocation() {
        locationService.requestCurrentLocation()
        mapCameraRequest = MapCameraRequest(target: .currentLocation)
    }

    private func showFullTrack() {
        if todayPoints.isEmpty {
            showTodayTrackDetail = true
        } else {
            mapCameraRequest = MapCameraRequest(target: .route)
        }
    }

    private func markCurrentLocation() {
        if let coordinate = locationService.currentLocation?.coordinate {
            placeDraft = PlaceDraft(coordinate: coordinate)
        } else {
            pendingPlaceFromCurrentLocation = true
            locationService.requestCurrentLocation()
            mapCameraRequest = MapCameraRequest(target: .currentLocation)
        }
    }

    private func openAMapNavigation(to coordinate: CLLocationCoordinate2D, name: String) {
        if AMapLauncher.canOpen() {
            AMapLauncher.openRoutePlan(to: coordinate, name: name)
        } else {
            showAmapUnavailable = true
        }
    }

    private func showPhoto(_ identifier: String) {
        guard let descriptor = photoDescriptors.first(where: { $0.id == identifier }) else { return }
        let coordinate: CLLocationCoordinate2D?
        if let latitude = descriptor.originalLatitude, let longitude = descriptor.originalLongitude {
            coordinate = .init(latitude: latitude, longitude: longitude)
        } else {
            coordinate = nil
        }
        selectedTrackPhoto = PhotoDetailItem(assetIdentifier: descriptor.id,
                                             creationDate: descriptor.creationDate,
                                             coordinate: coordinate)
    }

    private func loadTodayPhotos(requestAccess: Bool) async {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if requestAccess && status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { continuation.resume(returning: $0) }
            }
            PhotoLibraryScanCache.invalidate()
        }
        photoAuthorization = status
        guard status == .authorized || status == .limited else {
            photoDescriptors = []
            return
        }
        guard !isLoadingPhotos else { return }
        isLoadingPhotos = true
        PhotoLibraryChangeMonitor.shared.ensureRegistered()
        let generation = PhotoLibraryChangeMonitor.shared.generation
        let descriptors = await Task.detached(priority: .utility) {
            PhotoLibraryScanCache.descriptors(currentGeneration: generation)
        }.value
        photoDescriptors = descriptors.filter { Calendar.current.isDateInToday($0.creationDate) }
        isLoadingPhotos = false
    }
}

private struct TodayTrackDetailView: View {
    let sessions: [ActivitySession]
    let places: [CustomPlace]
    let currentLocation: CLLocation?
    let photoMoments: [TrackPhotoMoment]
    let onLongPress: (CLLocationCoordinate2D) -> Void

    @State private var showDestinationSearch = false
    @State private var showAmapUnavailable = false
    @State private var mapCameraRequest: MapCameraRequest?
    @State private var selectedPhoto: PhotoDetailItem?

    private var points: [TrackPoint] {
        sessions.flatMap(\.trackPoints).sorted { $0.timestamp < $1.timestamp }
    }

    private var mapPoints: [TrackMapPoint] {
        let recordedPoints = points.map(TrackMapPoint.init)
        return recordedPoints.isEmpty ? Self.sampleTrackPoints(near: currentLocation?.coordinate) : recordedPoints
    }

    private var isShowingSampleTrack: Bool {
        points.isEmpty
    }

    private var totalDistance: Double {
        sessions.reduce(0) { $0 + $1.distance }
    }

    private var duration: TimeInterval {
        sessions.reduce(0) { $0 + $1.duration }
    }

    private var displayDistance: Double {
        isShowingSampleTrack ? Self.distance(for: mapPoints) : totalDistance
    }

    private var displayDuration: TimeInterval {
        isShowingSampleTrack ? 2_280 : duration
    }

    private var latestCoordinate: CLLocationCoordinate2D? {
        if let point = points.last {
            return CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        }
        return isShowingSampleTrack ? mapPoints.last?.coordinate : currentLocation?.coordinate
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                vividTrackMap

                HStack(spacing: 10) {
                    Button {
                        showDestinationSearch = true
                    } label: {
                        Label("导航到目的地", systemImage: "location.north.line")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        guard let latestCoordinate else { return }
                        openAMapNavigation(to: latestCoordinate, name: "今日轨迹终点")
                    } label: {
                        Label("导航到终点", systemImage: "flag.checkered")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(latestCoordinate == nil)
                }
                .padding(.horizontal)

                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        StatisticTile(title: "今日距离", value: Formatters.distance(displayDistance), symbol: "arrow.left.and.right")
                        StatisticTile(title: "今日时长", value: Formatters.duration(displayDuration), symbol: "clock")
                    }
                    GridRow {
                        StatisticTile(title: "轨迹点", value: "\(points.count)", symbol: "point.3.connected.trianglepath.dotted")
                        StatisticTile(title: "记录次数", value: "\(sessions.count)", symbol: "figure.walk")
                    }
                }
                .padding(.horizontal)

                sessionList
                if !photoMoments.isEmpty { photoTimeline }
            }
            .padding(.vertical)
        }
        .navigationTitle("今日轨迹")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDestinationSearch) {
            DestinationSearchView { destination in
                openAMapNavigation(to: destination.coordinate, name: destination.name)
            }
        }
        .alert("未安装高德地图", isPresented: $showAmapUnavailable) {
            Button("好", role: .cancel) { }
        } message: {
            Text("安装高德地图后可开始导航。LifeTrack 会独立保存本地轨迹。")
        }
        .sheet(item: $selectedPhoto) { item in PhotoDetailView(item: item) }
    }

    private var vividTrackMap: some View {
        ZStack(alignment: .bottomLeading) {
            TrackMapView(points: mapPoints,
                         places: places,
                         currentLocation: currentLocation,
                         cameraRequest: mapCameraRequest,
                         style: .vivid,
                         photoMoments: photoMoments,
                         onPhotoTap: showPhoto,
                         onLongPress: onLongPress)
            .frame(height: 420)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            TrackMapMetricRibbon(distance: Formatters.distance(displayDistance),
                                 duration: Formatters.duration(displayDuration),
                                 points: mapPoints.count,
                                 isSample: isShowingSampleTrack)
            .padding(12)

            TrackTypeLegend()
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

            vividMapControls
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .padding(.horizontal)
    }

    private var vividMapControls: some View {
        MapControlsPanel {
            MapControlButton(symbol: "location.fill", title: "定位到当前位置") {
                if currentLocation != nil {
                    mapCameraRequest = MapCameraRequest(target: .currentLocation)
                }
            }

            MapControlButton(symbol: "point.3.connected.trianglepath.dotted", title: "显示完整轨迹") {
                mapCameraRequest = MapCameraRequest(target: .route)
            }
        }
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("今日记录").font(.headline)
            if sessions.isEmpty {
                ContentUnavailableView("暂无今日轨迹", systemImage: "point.3.connected.trianglepath.dotted", description: Text("开始记录后会在这里查看今日轨迹。"))
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ForEach(sessions) { session in
                    NavigationLink {
                        SessionDetailView(session: session)
                    } label: {
                        SessionRow(session: session)
                            .padding(12)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal)
    }

    private var photoTimeline: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("沿途照片").font(.headline)
            ForEach(photoMoments) { moment in
                Button { showPhoto(moment.assetIdentifier) } label: {
                    HStack(spacing: 12) {
                        PhotoGalleryThumbnailView(assetIdentifier: moment.assetIdentifier,
                                                  cornerRadius: 9)
                            .frame(width: 58, height: 58)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(moment.creationDate, style: .time)
                                .font(.subheadline.weight(.semibold))
                            Text(moment.usesPhotoLocation ? "照片位置与 GPS 轨迹匹配" : "拍摄时间与 GPS 轨迹匹配")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }

    private func showPhoto(_ identifier: String) {
        guard let moment = photoMoments.first(where: { $0.assetIdentifier == identifier }) else { return }
        selectedPhoto = PhotoDetailItem(assetIdentifier: moment.assetIdentifier,
                                        creationDate: moment.creationDate,
                                        coordinate: moment.usesPhotoLocation ? moment.coordinate : nil)
    }

    private func openAMapNavigation(to coordinate: CLLocationCoordinate2D, name: String) {
        if AMapLauncher.canOpen() {
            AMapLauncher.openRoutePlan(to: coordinate, name: name)
        } else {
            showAmapUnavailable = true
        }
    }

    private static func sampleTrackPoints(near coordinate: CLLocationCoordinate2D?) -> [TrackMapPoint] {
        let center = coordinate ?? CLLocationCoordinate2D(latitude: 32.0415, longitude: 118.7950)
        let routes: [[(Double, Double, ActivityType)]] = [
            [(-0.015, -0.012, .walking), (-0.015, -0.008, .walking), (-0.012, -0.008, .walking), (-0.012, -0.004, .walking), (-0.009, -0.004, .walking), (-0.009, 0.000, .walking), (-0.006, 0.000, .walking)],
            [(-0.006, 0.000, .running), (-0.003, 0.000, .running), (-0.003, 0.004, .running), (0.001, 0.004, .running), (0.001, 0.008, .running), (0.005, 0.008, .running), (0.005, 0.011, .running)],
            [(-0.017, 0.011, .cycling), (-0.013, 0.011, .cycling), (-0.013, 0.007, .cycling), (-0.008, 0.007, .cycling), (-0.008, 0.003, .cycling), (-0.004, 0.003, .cycling), (-0.004, -0.001, .cycling)],
            [(0.009, -0.015, .automotive), (0.006, -0.015, .automotive), (0.006, -0.010, .automotive), (0.003, -0.010, .automotive), (0.003, -0.005, .automotive), (0.000, -0.005, .automotive), (0.000, 0.001, .automotive)],
            [(-0.002, -0.013, .walking), (-0.005, -0.013, .walking), (-0.005, -0.009, .walking), (-0.007, -0.009, .walking), (-0.007, -0.005, .walking), (-0.010, -0.005, .walking)],
            [(0.011, 0.012, .cycling), (0.008, 0.012, .cycling), (0.008, 0.008, .cycling), (0.004, 0.008, .cycling), (0.004, 0.004, .cycling), (0.000, 0.004, .cycling)],
            [(-0.010, 0.014, .running), (-0.006, 0.014, .running), (-0.006, 0.010, .running), (-0.002, 0.010, .running), (-0.002, 0.006, .running), (0.002, 0.006, .running)],
            [(0.012, -0.006, .automotive), (0.009, -0.006, .automotive), (0.009, -0.002, .automotive), (0.006, -0.002, .automotive), (0.006, 0.002, .automotive), (0.003, 0.002, .automotive)],
            [(-0.004, 0.014, .walking), (-0.001, 0.014, .walking), (-0.001, 0.011, .walking), (0.002, 0.011, .walking), (0.002, 0.014, .walking), (0.005, 0.014, .walking), (0.005, 0.011, .walking)]
        ]

        var points: [TrackMapPoint] = []
        var index = 0
        for (routeIndex, route) in routes.enumerated() {
            for item in route {
                points.append(TrackMapPoint(coordinate: CLLocationCoordinate2D(latitude: center.latitude + item.0,
                                                                               longitude: center.longitude + item.1),
                                            timestamp: Date().addingTimeInterval(Double(index) * 90),
                                            activityType: item.2,
                                            segmentID: routeIndex))
                index += 1
            }
        }
        return points
    }

    private static func distance(for points: [TrackMapPoint]) -> Double {
        guard points.count > 1 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { partial, pair in
            guard pair.0.segmentID == pair.1.segmentID else { return partial }
            let start = CLLocation(latitude: pair.0.coordinate.latitude, longitude: pair.0.coordinate.longitude)
            let end = CLLocation(latitude: pair.1.coordinate.latitude, longitude: pair.1.coordinate.longitude)
            let distance = start.distance(from: end)
            return distance < 1_800 ? partial + distance : partial
        }
    }
}

private struct MapControlButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(Color(uiColor: .secondarySystemBackground).opacity(0.94), in: Circle())
                .overlay {
                    Circle().stroke(Color.primary.opacity(0.06), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .frame(width: 52, height: 52)
        .contentShape(Rectangle())
        .accessibilityLabel(title)
    }
}

private struct SummaryMetric: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.11), in: Circle())
            Text(value)
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct HomeActionButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.vertical, 12)
            .background(tint.opacity(configuration.isPressed ? 0.16 : 0.1), in: RoundedRectangle(cornerRadius: 14))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct MapControlsPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 4) {
            content
        }
        .padding(4)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.94), in: Capsule())
        .overlay {
            Capsule().stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .allowsHitTesting(true)
    }
}

private struct TrackTypeLegend: View {
    private let types: [ActivityType] = [.walking, .running, .cycling, .automotive, .transit]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(types) { type in
                HStack(spacing: 6) {
                    Circle()
                        .fill(type.trackColor)
                        .frame(width: 7, height: 7)
                    Text(type.displayName)
                        .font(.caption2.weight(.medium))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        }
    }
}

private struct TrackMapMetricRibbon: View {
    let distance: String
    let duration: String
    let points: Int
    var isSample = false

    var body: some View {
        HStack(spacing: 14) {
            if isSample {
                Label("示例", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Divider().frame(height: 26)
            }
            TrackMapMetric(value: distance, title: "距离")
            Divider().frame(height: 26)
            TrackMapMetric(value: duration, title: "时长")
            Divider().frame(height: 26)
            TrackMapMetric(value: "\(points)", title: "点位")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.28), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }
}

private struct TrackMapMetric: View {
    let value: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ActivityPickerSheet: View {
    let selection: ActivityType?
    let onSelect: (ActivityType?) -> Void

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onSelect(nil)
                } label: {
                    ActivityChoiceRow(title: "自动识别", symbol: "sparkles", isSelected: selection == nil)
                }

                ForEach(ActivityType.allCases.filter { $0 != .stationary }) { type in
                    Button {
                        onSelect(type)
                    } label: {
                        ActivityChoiceRow(title: type.displayName, symbol: type.symbolName, isSelected: selection == type)
                    }
                }
            }
            .navigationTitle("活动类型")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ActivityChoiceRow: View {
    let title: String
    let symbol: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 24)
            Text(title)
                .foregroundStyle(.primary)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
    }
}

struct StatisticTile: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.02), radius: 4, x: 0, y: 2)
        )
    }
}
