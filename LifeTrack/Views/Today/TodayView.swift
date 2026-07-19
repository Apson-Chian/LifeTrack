import SwiftUI
import SwiftData
import CoreLocation

struct TodayView: View {
    @ObservedObject var locationService: LocationService
    @Query(sort: \ActivitySession.startTime, order: .reverse) private var sessions: [ActivitySession]
    @Query(sort: \CustomPlace.shortName) private var places: [CustomPlace]
    @State private var placeDraft: PlaceDraft?
    @State private var showDestinationSearch = false
    @State private var manualActivity: ActivityType?
    @State private var showActivityPicker = false
    @State private var showAmapUnavailable = false
    @State private var mapCameraRequest: MapCameraRequest?

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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    todayMap

                    quickActions
                    recordingControls
                    summary
                    activityBreakdown
                }
                .padding(.vertical)
            }
            .navigationTitle("今日")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showDestinationSearch = true } label: { Label("高德导航", systemImage: "location.north.line") }
                        Button {
                            guard let coordinate = locationService.currentLocation?.coordinate else { return }
                            placeDraft = PlaceDraft(coordinate: coordinate)
                        } label: { Label("标记当前位置", systemImage: "mappin.badge.plus") }
                    } label: { Image(systemName: "plus") }
                }
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
            .alert("未安装高德地图", isPresented: $showAmapUnavailable) {
                Button("好", role: .cancel) { }
            } message: {
                Text("安装高德地图后可开始导航。LifeTrack 会独立保存本地轨迹。")
            }
        }
    }

    private var todayMap: some View {
        ZStack(alignment: .topTrailing) {
            TrackMapView(points: todayMapPoints,
                         places: places,
                         currentLocation: locationService.currentLocation,
                         cameraRequest: mapCameraRequest) { coordinate in
                placeDraft = PlaceDraft(coordinate: coordinate)
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(spacing: 8) {
                MapControlButton(symbol: "location.fill", title: "定位到当前位置") {
                    locationService.requestCurrentLocation()
                    mapCameraRequest = MapCameraRequest(target: .currentLocation)
                }

                MapControlButton(symbol: "point.3.connected.trianglepath.dotted", title: "显示完整轨迹") {
                    mapCameraRequest = MapCameraRequest(target: .route)
                }
                .disabled(todayPoints.isEmpty)

                MapControlButton(symbol: "mappin.badge.plus", title: "标记当前位置") {
                    guard let coordinate = locationService.currentLocation?.coordinate else { return }
                    placeDraft = PlaceDraft(coordinate: coordinate)
                }
                .disabled(locationService.currentLocation == nil)
            }
            .padding(10)
        }
        .padding(.horizontal)
    }

    private var quickActions: some View {
        HStack(spacing: 10) {
            NavigationLink {
                TodayTrackDetailView(sessions: todaySessions,
                                     places: places,
                                     currentLocation: locationService.currentLocation,
                                     onLongPress: { coordinate in
                                         placeDraft = PlaceDraft(coordinate: coordinate)
                                     })
            } label: {
                Label("查看今日轨迹", systemImage: "point.3.connected.trianglepath.dotted")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                showDestinationSearch = true
            } label: {
                Label("高德导航", systemImage: "location.north.line")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
    }

    private var recordingControls: some View {
        VStack(spacing: 10) {
            HStack {
                Label(statusTitle, systemImage: statusSymbol)
                    .foregroundStyle(locationService.activeSession == nil ? Color.secondary : Color.red)
                Spacer()
                Button(manualActivity?.displayName ?? "活动") { showActivityPicker = true }
                    .buttonStyle(.bordered)
            }
            if locationService.activeSession == nil {
                Button { locationService.startRecording(manualActivity: manualActivity) } label: {
                    Label("开始记录", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(role: .destructive) { locationService.stopRecording() } label: {
                    Label("结束记录", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal)
    }

    private var summary: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow { StatisticTile(title: "移动距离", value: Formatters.distance(totalDistance), symbol: "arrow.left.and.right")
                StatisticTile(title: "运动时长", value: Formatters.duration(activeDuration), symbol: "clock") }
            GridRow { StatisticTile(title: "停留地点", value: "\(todaySessions.flatMap(\.stayRecords).count)", symbol: "mappin")
                StatisticTile(title: "记录次数", value: "\(todaySessions.count)", symbol: "figure.walk") }
        }
        .padding(.horizontal)
    }

    private var activityBreakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("活动分布").font(.headline)
            ForEach([ActivityType.walking, .running, .cycling, .automotive]) { type in
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
        let points = todayPoints.filter { $0.activityType == activity }
        guard points.count > 1 else { return 0 }
        return zip(points, points.dropFirst()).reduce(0) { partial, pair in
            partial + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude).distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
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

    private func openAMapNavigation(to coordinate: CLLocationCoordinate2D, name: String) {
        if AMapLauncher.canOpen() {
            AMapLauncher.openRoutePlan(to: coordinate, name: name)
        } else {
            showAmapUnavailable = true
        }
    }
}

private struct TodayTrackDetailView: View {
    let sessions: [ActivitySession]
    let places: [CustomPlace]
    let currentLocation: CLLocation?
    let onLongPress: (CLLocationCoordinate2D) -> Void

    @State private var showDestinationSearch = false
    @State private var showAmapUnavailable = false
    @State private var mapCameraRequest: MapCameraRequest?

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
    }

    private var vividTrackMap: some View {
        ZStack(alignment: .bottomLeading) {
            TrackMapView(points: mapPoints,
                         places: places,
                         currentLocation: currentLocation,
                         cameraRequest: mapCameraRequest,
                         style: .vivid,
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

            VStack(spacing: 8) {
                MapControlButton(symbol: "location.fill", title: "定位到当前位置") {
                    mapCameraRequest = MapCameraRequest(target: .currentLocation)
                }
                .disabled(currentLocation == nil)

                MapControlButton(symbol: "point.3.connected.trianglepath.dotted", title: "显示完整轨迹") {
                    mapCameraRequest = MapCameraRequest(target: .route)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .padding(.horizontal)
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
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle().stroke(.white.opacity(0.28), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct TrackTypeLegend: View {
    private let types: [ActivityType] = [.walking, .running, .cycling, .automotive]

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
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }
}
