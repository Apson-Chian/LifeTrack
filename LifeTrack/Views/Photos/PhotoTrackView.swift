import SwiftUI
import Photos
import CoreLocation

struct PhotoTrackView: View {
    @State private var photoPoints: [PhotoLocationPoint] = []
    @State private var scannedPhotoCount = 0
    @State private var isLoading = false
    @State private var authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var cameraRequest: MapCameraRequest?

    private var mapPoints: [TrackMapPoint] {
        photoPoints.map {
            TrackMapPoint(coordinate: $0.coordinate,
                          timestamp: $0.date,
                          activityType: .unknown,
                          segmentID: 0,
                          horizontalAccuracy: 1,
                          source: .photo)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    photoTrackMap
                    controls
                    stats
                    pointList
                }
                .padding(.vertical)
            }
            .navigationTitle("照片轨迹")
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
                await loadPhotoLocations()
            }
        }
    }

    private var photoTrackMap: some View {
        ZStack {
            if mapPoints.count > 1 {
                TrackMapView(points: mapPoints,
                             places: [],
                             currentLocation: nil,
                             cameraRequest: cameraRequest,
                             style: .photoDots) { _ in }
                .frame(height: 460)
                .clipShape(RoundedRectangle(cornerRadius: 12))
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
                ContentUnavailableView(emptyTitle, systemImage: "photo.badge.map", description: Text(emptyDescription))
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
                photoPoints = []
                scannedPhotoCount = 0
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
                StatisticTile(title: "已跳过", value: "\(max(scannedPhotoCount - photoPoints.count, 0))", symbol: "photo.badge.exclamationmark")
                StatisticTile(title: "状态", value: statusText, symbol: "checkmark.circle")
            }
        }
        .padding(.horizontal)
    }

    private var pointList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("定位点").font(.headline)
            if photoPoints.isEmpty {
                Text("没有读取到照片定位点。")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            } else {
                ForEach(Array(photoPoints.prefix(80).enumerated()), id: \.element.id) { index, point in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.blue, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(point.date, format: .dateTime.year().month().day().hour().minute())
                                .font(.subheadline.weight(.semibold))
                            Text(String(format: "%.5f, %.5f", point.coordinate.latitude, point.coordinate.longitude))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                }
                if photoPoints.count > 80 {
                    Text("已显示前 80 个定位点，地图包含全部点。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    @MainActor
    private func loadPhotoLocations() async {
        isLoading = true
        defer { isLoading = false }

        let status = await requestPhotoAccessIfNeeded()
        authorizationStatus = status
        guard status == .authorized || status == .limited else {
            photoPoints = []
            scannedPhotoCount = 0
            return
        }

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        fetchOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let assets = PHAsset.fetchAssets(with: fetchOptions)

        var importedPoints: [PhotoLocationPoint] = []
        assets.enumerateObjects { asset, _, _ in
            guard let location = asset.location else { return }
            importedPoints.append(PhotoLocationPoint(coordinate: location.coordinate,
                                                     date: asset.creationDate ?? Date.distantPast))
        }

        scannedPhotoCount = assets.count
        photoPoints = importedPoints.sorted { $0.date < $1.date }
        if photoPoints.count > 1 {
            cameraRequest = MapCameraRequest(target: .route)
        }
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

private struct PhotoLocationPoint: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let date: Date
}
