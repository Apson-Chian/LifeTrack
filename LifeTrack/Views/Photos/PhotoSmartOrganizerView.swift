import SwiftUI
import SwiftData
import Photos
import CoreLocation

struct PhotoSmartOrganizerView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PhotoAnalysisRecord.creationDate, order: .reverse) private var records: [PhotoAnalysisRecord]
    @Query(sort: \ActivitySession.startTime, order: .reverse) private var sessions: [ActivitySession]

    @State private var libraryDescriptors: [PhotoLibraryAssetDescriptor] = []
    @State private var authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var isRefreshing = false
    @State private var isAnalyzing = false
    @State private var completedInCurrentRun = 0
    @State private var totalInCurrentRun = 0
    @State private var analysisTask: Task<Void, Never>?
    @State private var statusMessage: String?
    @State private var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

    private var cachedIdentifiers: Set<String> {
        Set(records.map(\.assetIdentifier))
    }

    private var displayedRecords: [PhotoAnalysisRecord] {
        guard authorizationStatus == .limited, !libraryDescriptors.isEmpty else { return records }
        let visibleIdentifiers = Set(libraryDescriptors.map(\.id))
        return records.filter { visibleIdentifiers.contains($0.assetIdentifier) }
    }

    private var pendingDescriptors: [PhotoLibraryAssetDescriptor] {
        libraryDescriptors.filter { !cachedIdentifiers.contains($0.id) }
    }

    private var retryDescriptors: [PhotoLibraryAssetDescriptor] {
        let unavailableIDs = Set(records.filter { $0.analysisState != .completed }.map(\.assetIdentifier))
        return libraryDescriptors.filter { unavailableIDs.contains($0.id) }
    }

    private var descriptorsForNextRun: [PhotoLibraryAssetDescriptor] {
        pendingDescriptors.isEmpty ? retryDescriptors : pendingDescriptors
    }

    private var completedRecords: [PhotoAnalysisRecord] {
        displayedRecords.filter { $0.analysisState == .completed }
    }

    private var unavailableCount: Int {
        displayedRecords.filter { $0.analysisState != .completed }.count
    }

    private var linkedCount: Int {
        displayedRecords.filter { $0.linkedSessionID != nil }.count
    }

    private var progress: Double {
        guard totalInCurrentRun > 0 else { return 0 }
        return Double(completedInCurrentRun) / Double(totalInCurrentRun)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                privacyCard
                analysisControls
                overview
                smartDestinations
                categoryBrowser
            }
            .padding()
        }
        .navigationTitle("照片智能整理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refreshLibrary() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isRefreshing || isAnalyzing)
                .accessibilityLabel("刷新照片库")
            }
        }
        .task {
            if libraryDescriptors.isEmpty {
                await refreshLibrary()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            if isLowPowerModeEnabled { analysisTask?.cancel() }
        }
    }

    private var privacyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                Text("全程在设备上完成")
                    .font(.headline)
                Spacer()
                Text("Vision")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.16), in: Capsule())
            }
            Text("只向 Apple Vision 提供 384px 缩略图，不上传分析数据，不把原图交给分析器。每张成功分类的照片只分析一次。")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(16)
        .background(
            LinearGradient(colors: [Color.indigo, Color.purple.opacity(0.82)],
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18)
        )
    }

    private var analysisControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isAnalyzing ? "正在本地整理" : analysisTitle)
                        .font(.headline)
                    Text(analysisSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isRefreshing {
                    ProgressView()
                }
            }

            if isAnalyzing {
                ProgressView(value: progress)
                    .tint(.indigo)
                HStack {
                    Text("\(completedInCurrentRun)/\(totalInCurrentRun)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("暂停") {
                        analysisTask?.cancel()
                    }
                    .font(.caption.weight(.semibold))
                }
            } else {
                Button {
                    startAnalysis()
                } label: {
                    Label(analysisButtonTitle,
                          systemImage: descriptorsForNextRun.isEmpty ? "checkmark.circle.fill" : "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .disabled(descriptorsForNextRun.isEmpty || isRefreshing || isLowPowerModeEnabled)
            }

            if isLowPowerModeEnabled && !descriptorsForNextRun.isEmpty {
                Label("已检测到低电量模式，暂停新的 Vision 分析。",
                      systemImage: "battery.25percent")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var analysisTitle: String {
        if isRefreshing { return "正在读取照片元数据" }
        if pendingDescriptors.isEmpty, !retryDescriptors.isEmpty { return "\(retryDescriptors.count) 张上次整理未完成" }
        if descriptorsForNextRun.isEmpty, !libraryDescriptors.isEmpty { return "智能整理已是最新" }
        return "发现 \(pendingDescriptors.count) 张待整理照片"
    }

    private var analysisButtonTitle: String {
        if !pendingDescriptors.isEmpty { return "整理 \(pendingDescriptors.count) 张新照片" }
        if !retryDescriptors.isEmpty { return "重试 \(retryDescriptors.count) 张未完成照片" }
        return "已完成整理"
    }

    private var analysisSubtitle: String {
        switch authorizationStatus {
        case .authorized: "已授权的全部照片库"
        case .limited: "只整理你允许访问的照片"
        case .denied, .restricted: "请先在系统设置中允许访问照片"
        case .notDetermined: "需要照片访问权限"
        @unknown default: "照片权限状态未知"
        }
    }

    private var overview: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                StatisticTile(title: "已缓存", value: "\(displayedRecords.count)", symbol: "externaldrive.fill.badge.checkmark")
                StatisticTile(title: "已分类", value: "\(completedRecords.count)", symbol: "square.grid.2x2.fill")
            }
            GridRow {
                StatisticTile(title: "关联轨迹", value: "\(linkedCount)", symbol: "point.3.connected.trianglepath.dotted")
                StatisticTile(title: "待重试", value: "\(unavailableCount)", symbol: "arrow.clockwise.circle")
            }
        }
    }

    private var smartDestinations: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("智能回忆")
                .font(.headline)

            NavigationLink {
                SmartTravelAlbumsView(records: completedRecords, sessions: sessions)
            } label: {
                PhotoFeatureRow(title: "智能旅行相册",
                                subtitle: "结合 EXIF 时间、GPS 和运动轨迹自动分组",
                                symbol: "suitcase.rolling.fill",
                                tint: .indigo,
                                value: displayedRecords.isEmpty ? nil : "自动生成")
            }
            .disabled(completedRecords.isEmpty)

            NavigationLink {
                PhotoTravelTimelineView()
            } label: {
                PhotoFeatureRow(title: "智能照片时间轴",
                                subtitle: "按拍摄时间还原行程，保留轨迹关联",
                                symbol: "point.topleft.down.to.point.bottomright.curvepath",
                                tint: .orange,
                                value: displayedRecords.isEmpty ? nil : "\(displayedRecords.count) 张")
            }
            .disabled(displayedRecords.isEmpty)
        }
    }

    private var categoryBrowser: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("按内容浏览")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                ForEach(PhotoSmartCategory.allCases.filter { $0 != .other || categoryCount($0) > 0 }) { category in
                    NavigationLink {
                        SmartCategoryPhotosView(category: category,
                                                records: completedRecords.filter { $0.categories.contains(category) })
                    } label: {
                        SmartCategoryCard(category: category, count: categoryCount(category))
                    }
                    .buttonStyle(.plain)
                    .disabled(categoryCount(category) == 0)
                }
            }
        }
    }

    private func categoryCount(_ category: PhotoSmartCategory) -> Int {
        completedRecords.filter { $0.categories.contains(category) }.count
    }

    private func refreshLibrary() async {
        guard !isRefreshing, !isAnalyzing else { return }
        isRefreshing = true
        statusMessage = nil

        let status = await requestPhotoAccessIfNeeded()
        authorizationStatus = status
        guard status == .authorized || status == .limited else {
            isRefreshing = false
            return
        }

        let descriptors = await Task.detached(priority: .utility) {
            PhotoLibraryScanner.descriptors()
        }.value
        libraryDescriptors = descriptors
        synchronizeCache(with: descriptors, removeMissing: status == .authorized)
        relinkCachedRecords(using: descriptors)
        statusMessage = pendingDescriptors.isEmpty
            ? "已直接读取本地缓存，没有重复分析。"
            : "PhotoKit 只会向分析器交付小尺寸图像，Vision 推理全程在本机完成。"
        isRefreshing = false
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

    private func synchronizeCache(with descriptors: [PhotoLibraryAssetDescriptor], removeMissing: Bool) {
        guard removeMissing else { return }
        let identifiers = Set(descriptors.map(\.id))
        for record in records where !identifiers.contains(record.assetIdentifier) {
            modelContext.delete(record)
        }
        try? modelContext.save()
    }

    private func relinkCachedRecords(using descriptors: [PhotoLibraryAssetDescriptor]) {
        let descriptorByID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
        let snapshots = PhotoTrackAssociationService.snapshots(from: sessions)
        var didChange = false
        for record in records {
            let linkedID: UUID?
            if let descriptor = descriptorByID[record.assetIdentifier] {
                linkedID = PhotoTrackAssociationService.bestSessionID(for: descriptor, sessions: snapshots)
            } else {
                linkedID = PhotoTrackAssociationService.bestSessionID(date: record.creationDate,
                                                                       latitude: record.originalLatitude,
                                                                       longitude: record.originalLongitude,
                                                                       sessions: snapshots)
            }
            if record.linkedSessionID != linkedID {
                record.linkedSessionID = linkedID
                didChange = true
            }
        }
        if didChange { try? modelContext.save() }
    }

    private func startAnalysis() {
        guard !isAnalyzing,
              !descriptorsForNextRun.isEmpty,
              !isLowPowerModeEnabled else { return }
        let descriptors = descriptorsForNextRun
        let snapshots = PhotoTrackAssociationService.snapshots(from: sessions)
        totalInCurrentRun = descriptors.count
        completedInCurrentRun = 0
        isAnalyzing = true
        statusMessage = nil

        analysisTask = Task {
            for descriptor in descriptors {
                guard !Task.isCancelled else { break }
                let result = await PhotoVisionAnalysisService.analyze(descriptor)
                guard !Task.isCancelled else { break }

                let linkedSessionID = PhotoTrackAssociationService.bestSessionID(for: descriptor, sessions: snapshots)
                if let cached = records.first(where: { $0.assetIdentifier == descriptor.id }) {
                    cached.update(categories: result.categories,
                                  topLabels: result.topLabels,
                                  confidence: result.confidence,
                                  faceCount: result.faceCount,
                                  state: result.state,
                                  linkedSessionID: linkedSessionID)
                } else {
                    let record = PhotoAnalysisRecord(assetIdentifier: descriptor.id,
                                                     creationDate: descriptor.creationDate,
                                                     latitude: descriptor.displayLatitude,
                                                     longitude: descriptor.displayLongitude,
                                                     originalLatitude: descriptor.originalLatitude,
                                                     originalLongitude: descriptor.originalLongitude,
                                                     categories: result.categories,
                                                     topLabels: result.topLabels,
                                                     confidence: result.confidence,
                                                     faceCount: result.faceCount,
                                                     state: result.state,
                                                     linkedSessionID: linkedSessionID)
                    modelContext.insert(record)
                }
                completedInCurrentRun += 1

                if completedInCurrentRun % 10 == 0 {
                    try? modelContext.save()
                    await yieldForEnergyAndThermals()
                }
            }

            try? modelContext.save()
            let wasCancelled = Task.isCancelled
            isAnalyzing = false
            analysisTask = nil
            statusMessage = wasCancelled
                ? "已暂停，下次只会继续分析未缓存的照片。"
                : "整理完成；后续浏览将直接读取 SwiftData 缓存。"
        }
    }

    private func yieldForEnergyAndThermals() async {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            try? await Task.sleep(nanoseconds: 800_000_000)
        case .fair:
            try? await Task.sleep(nanoseconds: 180_000_000)
        case .nominal:
            await Task.yield()
        @unknown default:
            await Task.yield()
        }
    }
}

private struct SmartCategoryCard: View {
    let category: PhotoSmartCategory
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: category.symbolName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(category.tint)
            Text(category.title)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(count == 0 ? "暂无照片" : "\(count) 张")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .opacity(count == 0 ? 0.58 : 1)
    }
}

struct SmartCategoryPhotosView: View {
    let category: PhotoSmartCategory
    let records: [PhotoAnalysisRecord]

    private let columns = [GridItem(.flexible(), spacing: 3),
                           GridItem(.flexible(), spacing: 3),
                           GridItem(.flexible())]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(records.sorted { $0.creationDate > $1.creationDate }) { record in
                    ZStack(alignment: .bottomLeading) {
                        PhotoThumbnailView(assetIdentifier: record.assetIdentifier, cornerRadius: 4)
                            .aspectRatio(1, contentMode: .fit)
                        if record.linkedSessionID != nil {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(.black.opacity(0.48), in: Circle())
                                .padding(5)
                        }
                    }
                }
            }
            .padding(3)
        }
        .navigationTitle("\(category.title) · \(records.count)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SmartTravelAlbumsView: View {
    let records: [PhotoAnalysisRecord]
    let sessions: [ActivitySession]

    @State private var placeNames: [String: String] = [:]

    private var albums: [SmartTravelAlbum] {
        SmartTravelAlbumBuilder.build(records: records, sessions: sessions)
    }

    var body: some View {
        ScrollView {
            if albums.isEmpty {
                ContentUnavailableView("还没有可生成的旅行相册",
                                       systemImage: "suitcase.rolling",
                                       description: Text("有 GPS 的照片，或在运动轨迹前后拍摄的照片，会自动聚合成旅行相册。"))
                    .frame(minHeight: 480)
                    .padding()
            } else {
                LazyVStack(spacing: 14) {
                    ForEach(albums) { album in
                        NavigationLink {
                            SmartTravelAlbumDetailView(album: album)
                        } label: {
                            SmartTravelAlbumCard(album: album,
                                                 placeName: placeNames[album.id])
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("智能旅行相册")
        .navigationBarTitleDisplayMode(.inline)
        .task { await resolvePlaceNames() }
    }

    private func resolvePlaceNames() async {
        let geocoder = GeocodingService()
        for album in albums.prefix(40) where placeNames[album.id] == nil {
            guard !Task.isCancelled, let coordinate = album.originalCenter else { continue }
            if let name = await geocoder.reverseGeocode(coordinate), !name.isEmpty {
                placeNames[album.id] = name
            }
        }
    }
}

private struct SmartTravelAlbumCard: View {
    let album: SmartTravelAlbum
    let placeName: String?

    var body: some View {
        HStack(spacing: 13) {
            PhotoThumbnailView(assetIdentifier: album.records.first?.assetIdentifier ?? "",
                               cornerRadius: 12)
                .frame(width: 92, height: 92)

            VStack(alignment: .leading, spacing: 6) {
                Text(placeName ?? album.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(album.dateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Label("\(album.records.count) 张", systemImage: "photo.stack")
                    if album.linkedSessionCount > 0 {
                        Label("\(album.linkedSessionCount) 段轨迹", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct SmartTravelAlbumDetailView: View {
    let album: SmartTravelAlbum

    private let columns = [GridItem(.flexible(), spacing: 3),
                           GridItem(.flexible(), spacing: 3),
                           GridItem(.flexible())]

    private var photoMapPoints: [TrackMapPoint] {
        album.records.compactMap { record in
            guard let latitude = record.latitude, let longitude = record.longitude else { return nil }
            return TrackMapPoint(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                                 timestamp: record.creationDate,
                                 activityType: .unknown,
                                 horizontalAccuracy: 1,
                                 source: .photo)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !photoMapPoints.isEmpty {
                    TrackMapView(points: photoMapPoints,
                                 places: [],
                                 currentLocation: nil,
                                 cameraRequest: MapCameraRequest(target: .route),
                                 style: .photoDots) { _ in }
                        .frame(height: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(album.title)
                            .font(.title3.weight(.semibold))
                        Text(album.dateText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if album.linkedSessionCount > 0 {
                        Label("\(album.linkedSessionCount) 段轨迹", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.indigo)
                    }
                }

                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(album.records.sorted { $0.creationDate > $1.creationDate }) { record in
                        PhotoThumbnailView(assetIdentifier: record.assetIdentifier, cornerRadius: 4)
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("旅行相册")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SmartTravelAlbum: Identifiable {
    let id: String
    let title: String
    let records: [PhotoAnalysisRecord]
    let linkedSessionCount: Int
    let displayCenter: CLLocationCoordinate2D?
    let originalCenter: CLLocationCoordinate2D?

    var dateText: String {
        guard let first = records.map(\.creationDate).min(),
              let last = records.map(\.creationDate).max() else { return "--" }
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return first.formatted(.dateTime.year().month().day().weekday(.wide))
        }
        return "\(first.formatted(.dateTime.year().month().day())) – \(last.formatted(.dateTime.year().month().day()))"
    }
}

enum SmartTravelAlbumBuilder {
    static func build(records: [PhotoAnalysisRecord], sessions: [ActivitySession]) -> [SmartTravelAlbum] {
        let sessionByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var groups: [String: [PhotoAnalysisRecord]] = [:]

        for record in records {
            if let sessionID = record.linkedSessionID {
                groups["session:\(sessionID.uuidString)", default: []].append(record)
                continue
            }
            guard let latitude = record.originalLatitude,
                  let longitude = record.originalLongitude else { continue }
            let day = Calendar.current.startOfDay(for: record.creationDate).timeIntervalSince1970
            let latitudeBucket = Int(floor(latitude * 5))
            let longitudeBucket = Int(floor(longitude * 5))
            groups["place:\(Int(day)):\(latitudeBucket):\(longitudeBucket)", default: []].append(record)
        }

        return groups.compactMap { key, groupRecords in
            let linkedIDs = Set(groupRecords.compactMap(\.linkedSessionID))
            guard !linkedIDs.isEmpty || groupRecords.count >= 2 else { return nil }

            let displayCenter = center(records: groupRecords, original: false)
            let originalCenter = center(records: groupRecords, original: true)
            let title: String
            if let sessionID = linkedIDs.first, let session = sessionByID[sessionID] {
                title = "\(session.startTime.formatted(.dateTime.month().day()))·\(session.activityType.displayName)行程"
            } else if let date = groupRecords.map(\.creationDate).min() {
                title = "\(date.formatted(.dateTime.month().day()))旅行记忆"
            } else {
                title = "旅行记忆"
            }

            return SmartTravelAlbum(id: key,
                                    title: title,
                                    records: groupRecords.sorted { $0.creationDate < $1.creationDate },
                                    linkedSessionCount: linkedIDs.count,
                                    displayCenter: displayCenter,
                                    originalCenter: originalCenter)
        }
        .sorted {
            ($0.records.last?.creationDate ?? .distantPast) > ($1.records.last?.creationDate ?? .distantPast)
        }
    }

    private static func center(records: [PhotoAnalysisRecord], original: Bool) -> CLLocationCoordinate2D? {
        let coordinates = records.compactMap { record -> CLLocationCoordinate2D? in
            let latitude = original ? record.originalLatitude : record.latitude
            let longitude = original ? record.originalLongitude : record.longitude
            guard let latitude, let longitude else { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        guard !coordinates.isEmpty else { return nil }
        return CLLocationCoordinate2D(latitude: coordinates.map(\.latitude).reduce(0, +) / Double(coordinates.count),
                                      longitude: coordinates.map(\.longitude).reduce(0, +) / Double(coordinates.count))
    }
}

private extension PhotoAnalysisRecord {
    var timelineAsset: PhotoAssetRecord {
        let coordinate: CLLocationCoordinate2D?
        if let latitude, let longitude {
            coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        } else {
            coordinate = nil
        }
        return PhotoAssetRecord(id: assetIdentifier,
                                date: creationDate,
                                coordinate: coordinate,
                                linkedSessionID: linkedSessionID)
    }
}

private extension PhotoSmartCategory {
    var tint: Color {
        switch self {
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
}
