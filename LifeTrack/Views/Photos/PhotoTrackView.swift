import SwiftUI
import Photos
import CoreLocation

struct PhotoTrackView: View {
    @State private var photoAssets: [PhotoAssetRecord] = []
    @State private var photoPoints: [PhotoLocationPoint] = []
    @State private var mapPoints: [TrackMapPoint] = []
    @State private var photoMemory = PhotoMemorySummary(points: [])
    @State private var scannedPhotoCount = 0
    @State private var isLoading = false
    @State private var hasLoadedPhotoLocations = false
    @State private var authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var cameraRequest: MapCameraRequest?
    @State private var timelineScope: PhotoTimelineScope = .all
    @State private var placeDraft: PlaceDraft?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                photoTrackMap
                timelineScopePicker
                photoFeatures
                controls
                stats
                lifeOverview
            }
            .padding(.vertical)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await loadPhotoLocations() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .accessibilityLabel("重新扫描照片")
            }
        }
        .task {
            guard !hasLoadedPhotoLocations else { return }
            hasLoadedPhotoLocations = true
            await loadPhotoLocations()
        }
        .onChange(of: timelineScope) { _, scope in
            Task { await applyTimelineScope(scope) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lifeTrackPhotoLibraryDidChange)) { _ in
            Task { await loadPhotoLocations() }
        }
        .sheet(item: $placeDraft) { draft in
            PlaceEditorView(coordinate: draft.coordinate)
        }
    }

    private var photoFeatures: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("照片功能")
                .font(.headline)

            NavigationLink {
                PhotoSmartOrganizerView()
            } label: {
                PhotoFeatureRow(title: "照片智能整理",
                                subtitle: "Vision 本地分类 · SwiftData 缓存 · 轨迹关联",
                                symbol: "sparkles.rectangle.stack.fill",
                                tint: .indigo,
                                value: "隐私分析")
            }

            NavigationLink {
                PhotoPlacesView(points: photoPoints)
            } label: {
                PhotoFeatureRow(title: "地点相册",
                                subtitle: "按拍摄地点分类，在地图上查看照片",
                                symbol: "map.fill",
                                tint: .blue,
                                value: photoPoints.isEmpty ? nil : "\(PhotoLocationGroup.build(from: photoPoints).count) 个地点")
            }
            .disabled(photoPoints.isEmpty)

            HStack(spacing: 10) {
                NavigationLink {
                    PhotoFootprintView(points: photoPoints)
                } label: {
                    PhotoFeatureTile(title: "足迹图",
                                     subtitle: photoPoints.isEmpty ? "暂无定位照片" : "\(photoPoints.count) 个足迹",
                                     symbol: "shoeprints.fill",
                                     tint: .teal)
                }
                .disabled(photoPoints.isEmpty)

                NavigationLink {
                    PhotoTravelTimelineView()
                } label: {
                    PhotoFeatureTile(title: "旅行时间轴",
                                     subtitle: photoAssets.isEmpty ? "暂无可用照片" : "\(photoAssets.count) 张照片",
                                     symbol: "point.topleft.down.to.point.bottomright.curvepath",
                                     tint: .orange)
                }
                .disabled(photoAssets.isEmpty)
            }
        }
        .padding(.horizontal)
    }

    private var timelineScopePicker: some View {
        Picker("时间范围", selection: $timelineScope) {
            ForEach(PhotoTimelineScope.allCases) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .disabled(isLoading || photoPoints.isEmpty)
    }

    private var photoTrackMap: some View {
        ZStack {
            if !mapPoints.isEmpty {
                TrackMapView(points: mapPoints,
                             places: [],
                             currentLocation: nil,
                             cameraRequest: cameraRequest,
                             style: .photoDots) { coordinate in
                    placeDraft = PlaceDraft(coordinate: coordinate)
                }
                .frame(height: 460)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottomTrailing) {
                    Label("长按添加地点", systemImage: "mappin.badge.plus")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(12)
                }
                .overlay(alignment: .topTrailing) {
                    Button {
                        cameraRequest = MapCameraRequest(target: .route)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
                    .padding(12)
                    .accessibilityLabel("适配全部照片轨迹")
                }
            } else {
                ContentUnavailableView(emptyTitle, systemImage: "photo.on.rectangle.angled", description: Text(emptyDescription))
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                Task { await loadPhotoLocations() }
            } label: {
                Label(isLoading ? "扫描中" : "扫描全部照片", systemImage: "photo.stack")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isLoading)

            Button {
                photoAssets = []
                photoPoints = []
                mapPoints = []
                photoMemory = PhotoMemorySummary(points: [])
                scannedPhotoCount = 0
                cameraRequest = nil
            } label: {
                Label("清空", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(photoPoints.isEmpty && scannedPhotoCount == 0)
        }
        .padding(.horizontal)
    }

    private var stats: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                StatisticTile(title: "定位照片", value: "\(photoPoints.count)", symbol: "mappin.and.ellipse")
                StatisticTile(title: "扫描照片", value: "\(scannedPhotoCount)", symbol: "photo")
            }
            GridRow {
                StatisticTile(title: "无定位", value: "\(max(scannedPhotoCount - photoPoints.count, 0))", symbol: "photo.badge.exclamationmark")
                StatisticTile(title: "状态", value: statusText, symbol: "checkmark.circle")
            }
            GridRow {
                StatisticTile(title: "地图校正", value: "国内", symbol: "scope")
                StatisticTile(title: "显示方式", value: "光粒子", symbol: "sparkles")
            }
        }
        .padding(.horizontal)
    }

    private var lifeOverview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("生活回顾").font(.headline)
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    StatisticTile(title: "活跃天数", value: "\(photoMemory.activeDayCount)", symbol: "calendar")
                    StatisticTile(title: "时间跨度", value: photoMemory.dateSpanText, symbol: "clock.arrow.circlepath")
                }
                GridRow {
                    StatisticTile(title: "高频月份", value: photoMemory.busiestMonthText, symbol: "calendar.badge.clock")
                    StatisticTile(title: "热点区域", value: "\(photoMemory.hotspots.count)", symbol: "circle.hexagongrid")
                }
            }

            if !photoMemory.hotspots.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("常出现的位置").font(.subheadline.weight(.semibold))
                    ForEach(Array(photoMemory.hotspots.prefix(4).enumerated()), id: \.element.id) { index, hotspot in
                        NavigationLink {
                            PhotoLocationGalleryView(title: "常出现的位置 \(index + 1)",
                                                     points: hotspot.points)
                        } label: {
                            HStack(spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 24, height: 24)
                                    .background(Color.teal, in: Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(hotspot.count) 张照片")
                                        .font(.subheadline.weight(.semibold))
                                    Text(hotspot.dateRangeText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(12)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal)
    }

    private var emptyTitle: String {
        switch authorizationStatus {
        case .authorized, .limited:
            return "暂无照片轨迹"
        case .notDetermined:
            return "需要照片权限"
        case .denied, .restricted:
            return "无法访问照片"
        @unknown default:
            return "无法读取照片"
        }
    }

    private var emptyDescription: String {
        switch authorizationStatus {
        case .authorized:
            return "相册里没有读取到带定位信息的照片。"
        case .limited:
            return "当前只允许访问部分照片，只会扫描已授权照片。"
        case .notDetermined:
            return "允许访问照片后会自动扫描带定位信息的照片。"
        case .denied, .restricted:
            return "请在系统设置里允许 LifeTrack 访问照片。"
        @unknown default:
            return "照片权限状态未知。"
        }
    }

    private var statusText: String {
        if isLoading { return "扫描中" }
        switch authorizationStatus {
        case .authorized: return "全部"
        case .limited: return "部分"
        case .notDetermined: return "待授权"
        case .denied, .restricted: return "无权限"
        @unknown default: return "未知"
        }
    }

    private func loadPhotoLocations() async {
        let canStart = await MainActor.run {
            guard !isLoading else { return false }
            isLoading = true
            return true
        }
        guard canStart else { return }

        let status = await requestPhotoAccessIfNeeded()
        await MainActor.run {
            authorizationStatus = status
        }
        guard status == .authorized || status == .limited else {
            await MainActor.run {
                photoPoints = []
                photoAssets = []
                mapPoints = []
                photoMemory = PhotoMemorySummary(points: [])
                scannedPhotoCount = 0
                cameraRequest = nil
                isLoading = false
            }
            return
        }

        let result = await Task.detached(priority: .userInitiated) {
            scanPhotoLibrary()
        }.value

        let presentation = await makePhotoPresentation(from: result.points, scope: timelineScope)

        await MainActor.run {
            scannedPhotoCount = result.scannedCount
            photoAssets = result.assets
            photoPoints = result.points
            mapPoints = presentation.mapPoints
            photoMemory = presentation.memory
            cameraRequest = presentation.mapPoints.isEmpty ? nil : MapCameraRequest(target: .route)
            isLoading = false
        }
    }

    private func applyTimelineScope(_ scope: PhotoTimelineScope) async {
        let points = photoPoints
        guard !points.isEmpty else { return }
        let presentation = await makePhotoPresentation(from: points, scope: scope)
        guard timelineScope == scope else { return }
        mapPoints = presentation.mapPoints
        photoMemory = presentation.memory
        cameraRequest = presentation.mapPoints.isEmpty ? nil : MapCameraRequest(target: .route)
    }

    private func requestPhotoAccessIfNeeded() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }
}

private func scanPhotoLibrary() -> PhotoScanResult {
    autoreleasepool {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let assets = PHAsset.fetchAssets(with: fetchOptions)

        var importedAssets: [PhotoAssetRecord] = []
        var importedPoints: [PhotoLocationPoint] = []
        assets.enumerateObjects { asset, _, _ in
            guard let date = asset.creationDate ?? asset.modificationDate else { return }
            let rawCoordinate = asset.location?.coordinate
            let displayCoordinate = rawCoordinate.map(ChinaMapCoordinateTransform.displayCoordinate(forPhotoCoordinate:))
            importedAssets.append(PhotoAssetRecord(id: asset.localIdentifier,
                                                   date: date,
                                                   coordinate: displayCoordinate))
            guard let rawCoordinate, let displayCoordinate else { return }
            importedPoints.append(PhotoLocationPoint(id: asset.localIdentifier,
                                                     coordinate: displayCoordinate,
                                                     originalCoordinate: rawCoordinate,
                                                     date: date))
        }

        let sortedAssets = importedAssets.sorted { $0.date < $1.date }
        let sortedPoints = importedPoints.sorted { $0.date < $1.date }
        return PhotoScanResult(scannedCount: assets.count, assets: sortedAssets, points: sortedPoints)
    }
}

private struct PhotoScanResult {
    let scannedCount: Int
    let assets: [PhotoAssetRecord]
    let points: [PhotoLocationPoint]
}

private struct PhotoPresentation {
    let mapPoints: [TrackMapPoint]
    let memory: PhotoMemorySummary

    init(points: [PhotoLocationPoint]) {
        mapPoints = points.map {
            TrackMapPoint(coordinate: $0.coordinate,
                          timestamp: $0.date,
                          activityType: .unknown,
                          segmentID: 0,
                          horizontalAccuracy: 1,
                          source: .photo)
        }
        self.memory = PhotoMemorySummary(points: points)
    }
}

private func makePhotoPresentation(from points: [PhotoLocationPoint], scope: PhotoTimelineScope) async -> PhotoPresentation {
    await Task.detached(priority: .userInitiated) {
        PhotoPresentation(points: points.filter { scope.includes($0.date) })
    }.value
}

private enum PhotoTimelineScope: String, CaseIterable, Identifiable {
    case all
    case recentMonth
    case currentYear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .recentMonth: "近 30 天"
        case .currentYear: "今年"
        }
    }

    func includes(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Bool {
        switch self {
        case .all:
            true
        case .recentMonth:
            date >= calendar.date(byAdding: .day, value: -30, to: now) ?? now
        case .currentYear:
            calendar.isDate(date, equalTo: now, toGranularity: .year)
        }
    }
}

struct PhotoLocationPoint: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let originalCoordinate: CLLocationCoordinate2D
    let date: Date
}

private struct PhotoMemorySummary {
    let activeDayCount: Int
    let dateSpanText: String
    let busiestMonthText: String
    let hotspots: [PhotoHotspot]

    init(points: [PhotoLocationPoint], calendar: Calendar = .current) {
        let sortedPoints = points.sorted { $0.date < $1.date }
        let activeDays = Set(sortedPoints.map { calendar.startOfDay(for: $0.date) })
        activeDayCount = activeDays.count

        if let first = sortedPoints.first?.date, let last = sortedPoints.last?.date {
            let days = max(calendar.dateComponents([.day], from: calendar.startOfDay(for: first), to: calendar.startOfDay(for: last)).day ?? 0, 0) + 1
            dateSpanText = "\(days) 天"
        } else {
            dateSpanText = "--"
        }

        let monthGroups = Dictionary(grouping: sortedPoints) { point in
            let components = calendar.dateComponents([.year, .month], from: point.date)
            return MonthKey(year: components.year ?? 0, month: components.month ?? 0)
        }
        if let busiest = monthGroups.max(by: { lhs, rhs in
            if lhs.value.count == rhs.value.count {
                return lhs.key.sortValue < rhs.key.sortValue
            }
            return lhs.value.count < rhs.value.count
        }) {
            busiestMonthText = "\(busiest.key.displayText) \(busiest.value.count)"
        } else {
            busiestMonthText = "--"
        }

        hotspots = PhotoHotspot.build(from: sortedPoints)
    }
}

private struct MonthKey: Hashable {
    let year: Int
    let month: Int

    var sortValue: Int { year * 100 + month }
    var displayText: String { "\(year).\(month)" }
}

private struct PhotoHotspot: Identifiable {
    let id = UUID()
    let points: [PhotoLocationPoint]
    let firstDate: Date
    let lastDate: Date

    var count: Int { points.count }

    var dateRangeText: String {
        if Calendar.current.isDate(firstDate, inSameDayAs: lastDate) {
            return firstDate.formatted(.dateTime.year().month().day())
        }
        return "\(firstDate.formatted(.dateTime.year().month().day())) - \(lastDate.formatted(.dateTime.year().month().day()))"
    }

    static func build(from points: [PhotoLocationPoint]) -> [PhotoHotspot] {
        var clusters: [PhotoHotspotCluster] = []
        var clusterIndexesByCell: [PhotoHotspotCell: [Int]] = [:]
        for point in points {
            let cell = PhotoHotspotCell(coordinate: point.coordinate)
            var nearestIndex: Int?
            var nearestDistance = CLLocationDistance.greatestFiniteMagnitude
            for nearbyCell in cell.neighbors {
                for index in clusterIndexesByCell[nearbyCell] ?? [] {
                    let distance = clusters[index].distance(to: point.coordinate)
                    guard distance <= 260, distance < nearestDistance else { continue }
                    nearestIndex = index
                    nearestDistance = distance
                }
            }
            if let index = nearestIndex {
                clusters[index].add(point)
            } else {
                clusters.append(PhotoHotspotCluster(point: point))
                clusterIndexesByCell[cell, default: []].append(clusters.count - 1)
            }
        }
        return clusters
            .filter { $0.count >= 2 }
            .sorted {
                if $0.count == $1.count {
                    return $0.lastDate > $1.lastDate
                }
                return $0.count > $1.count
            }
            .map {
                PhotoHotspot(points: $0.points,
                             firstDate: $0.firstDate,
                             lastDate: $0.lastDate)
            }
    }
}

private struct PhotoHotspotCell: Hashable {
    private static let size = 0.003
    let latitude: Int
    let longitude: Int

    init(coordinate: CLLocationCoordinate2D) {
        latitude = Int(floor(coordinate.latitude / Self.size))
        longitude = Int(floor(coordinate.longitude / Self.size))
    }

    var neighbors: [PhotoHotspotCell] {
        (-1...1).flatMap { latitudeOffset in
            (-1...1).map { longitudeOffset in
                PhotoHotspotCell(latitude: latitude + latitudeOffset, longitude: longitude + longitudeOffset)
            }
        }
    }

    private init(latitude: Int, longitude: Int) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

private struct PhotoHotspotCluster {
    private var latitudeSum: Double
    private var longitudeSum: Double
    private(set) var points: [PhotoLocationPoint]
    private(set) var firstDate: Date
    private(set) var lastDate: Date

    init(point: PhotoLocationPoint) {
        latitudeSum = point.coordinate.latitude
        longitudeSum = point.coordinate.longitude
        points = [point]
        firstDate = point.date
        lastDate = point.date
    }

    var count: Int { points.count }

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitudeSum / Double(count),
                               longitude: longitudeSum / Double(count))
    }

    mutating func add(_ point: PhotoLocationPoint) {
        latitudeSum += point.coordinate.latitude
        longitudeSum += point.coordinate.longitude
        points.append(point)
        firstDate = min(firstDate, point.date)
        lastDate = max(lastDate, point.date)
    }

    func distance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: center.latitude, longitude: center.longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }
}

enum ChinaMapCoordinateTransform {
    private static let earthRadius = 6_378_245.0
    private static let eccentricity = 0.00669342162296594323

    static func displayCoordinate(forPhotoCoordinate coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard isInMainlandChina(coordinate) else { return coordinate }
        return wgs84ToGCJ02(coordinate)
    }

    private static func isInMainlandChina(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.longitude >= 72.004
            && coordinate.longitude <= 137.8347
            && coordinate.latitude >= 0.8293
            && coordinate.latitude <= 55.8271
    }

    private static func wgs84ToGCJ02(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        var dLat = transformLatitude(coordinate.longitude - 105.0, coordinate.latitude - 35.0)
        var dLon = transformLongitude(coordinate.longitude - 105.0, coordinate.latitude - 35.0)
        let radLat = coordinate.latitude / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1 - eccentricity * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((earthRadius * (1 - eccentricity)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180.0) / (earthRadius / sqrtMagic * cos(radLat) * .pi)
        return CLLocationCoordinate2D(latitude: coordinate.latitude + dLat,
                                      longitude: coordinate.longitude + dLon)
    }

    private static func transformLatitude(_ x: Double, _ y: Double) -> Double {
        var result = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        result += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        result += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        result += (160.0 * sin(y / 12.0 * .pi) + 320 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return result
    }

    private static func transformLongitude(_ x: Double, _ y: Double) -> Double {
        var result = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        result += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        result += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        result += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return result
    }
}
