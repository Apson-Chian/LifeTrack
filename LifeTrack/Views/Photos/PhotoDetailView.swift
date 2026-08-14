import CoreLocation
import Photos
import SwiftData
import SwiftUI

struct PhotoDetailItem: Identifiable {
    let assetIdentifier: String
    let creationDate: Date
    let coordinate: CLLocationCoordinate2D?
    let categories: [PhotoSmartCategory]
    let labels: [String]
    let confidence: Double?
    let faceCount: Int?
    let linkedSessionID: UUID?

    var id: String { assetIdentifier }

    init(record: PhotoAnalysisRecord) {
        assetIdentifier = record.assetIdentifier
        creationDate = record.creationDate
        if let latitude = record.originalLatitude, let longitude = record.originalLongitude {
            coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        } else {
            coordinate = nil
        }
        categories = record.categories
        labels = record.topLabels.map { value in
            value.split(separator: "|", maxSplits: 1).first.map(String.init) ?? value
        }
        confidence = record.confidence
        faceCount = record.faceCount
        linkedSessionID = record.linkedSessionID
    }

    init(assetIdentifier: String,
         creationDate: Date,
         coordinate: CLLocationCoordinate2D?,
         linkedSessionID: UUID? = nil) {
        self.assetIdentifier = assetIdentifier
        self.creationDate = creationDate
        self.coordinate = coordinate
        categories = []
        labels = []
        confidence = nil
        faceCount = nil
        self.linkedSessionID = linkedSessionID
    }
}

private struct PhotoAssetMetadata {
    let creationDate: Date?
    let coordinate: CLLocationCoordinate2D?
    let pixelWidth: Int
    let pixelHeight: Int
    let isFavorite: Bool
}

struct PhotoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let item: PhotoDetailItem
    var onDeleted: (String) -> Void = { _ in }

    @State private var image: UIImage?
    @State private var metadata: PhotoAssetMetadata?
    @State private var isLoading = true
    @State private var isDeleting = false
    @State private var confirmsDeletion = false
    @State private var errorMessage: String?
    @State private var dismissesAfterMessage = false
    @State private var requestID: PHImageRequestID = PHInvalidImageRequestID

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    photo
                    information
                }
                .padding(.bottom, 28)
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("照片详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        confirmsDeletion = true
                    } label: {
                        if isDeleting {
                            ProgressView()
                        } else {
                            Image(systemName: "trash")
                        }
                    }
                    .disabled(isDeleting || image == nil)
                    .accessibilityLabel("从系统相册删除照片")
                }
            }
            .task { loadAsset() }
            .onDisappear(perform: cancelImageRequest)
            .alert("从系统相册删除这张照片？", isPresented: $confirmsDeletion) {
                Button("取消", role: .cancel) { }
                Button("删除", role: .destructive) {
                    Task { await deletePhoto() }
                }
            } message: {
                Text("照片会同步从 Apple 照片图库移到“最近删除”，并移除 LifeTrack 的分类缓存。")
            }
            .alert("照片操作", isPresented: errorPresented) {
                Button("好") {
                    errorMessage = nil
                    if dismissesAfterMessage { dismiss() }
                }
            } message: {
                Text(errorMessage ?? "请稍后重试。")
            }
        }
    }

    private var photo: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let ratio = photoAspectRatio
            let height = max(width * ratio, 200)
            ZStack {
                Color.black
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: width, height: height)
                } else if isLoading {
                    ProgressView("正在读取照片…")
                        .tint(.white)
                        .foregroundStyle(.white)
                } else {
                    ContentUnavailableView("照片不可用",
                                           systemImage: "photo.badge.exclamationmark",
                                           description: Text("照片可能已被删除，或不在当前授权范围内。"))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: width, height: height)
        }
    }

    private var photoAspectRatio: CGFloat {
        guard let metadata, metadata.pixelWidth > 0, metadata.pixelHeight > 0 else { return 1 }
        return CGFloat(metadata.pixelHeight) / CGFloat(metadata.pixelWidth)
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Label((metadata?.creationDate ?? item.creationDate).formatted(
                    date: .complete,
                    time: .standard
                ), systemImage: "calendar")

                if let metadata, metadata.pixelWidth > 0, metadata.pixelHeight > 0 {
                    Label("\(metadata.pixelWidth) × \(metadata.pixelHeight)",
                          systemImage: "aspectratio")
                }

                if let coordinate = metadata?.coordinate ?? item.coordinate {
                    Label(String(format: "%.5f, %.5f",
                                 coordinate.latitude,
                                 coordinate.longitude),
                          systemImage: "mappin.and.ellipse")
                }

                if metadata?.isFavorite == true {
                    Label("系统相册收藏", systemImage: "heart.fill")
                        .foregroundStyle(.pink)
                }

                if item.linkedSessionID != nil {
                    Label("已关联运动轨迹", systemImage: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(.indigo)
                }
            }
            .font(.subheadline)

            if !item.categories.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("内容分类").font(.headline)
                    FlowLayout(spacing: 7) {
                        ForEach(item.categories) { category in
                            Label(category.title, systemImage: category.symbolName)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .foregroundStyle(.indigo)
                                .background(Color.indigo.opacity(0.1), in: Capsule())
                        }
                    }
                    if let confidence = item.confidence {
                        Text("主要分类置信度 \(confidence.formatted(.percent.precision(.fractionLength(0))))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !item.labels.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("识别标签").font(.headline)
                    Text(item.labels.prefix(8).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let faceCount = item.faceCount, faceCount > 0 {
                Label("检测到 \(faceCount) 张人脸", systemImage: "face.smiling")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }

    private func loadAsset() {
        cancelImageRequest()
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.assetIdentifier],
                                              options: nil).firstObject else {
            isLoading = false
            return
        }
        metadata = PhotoAssetMetadata(creationDate: asset.creationDate,
                                      coordinate: asset.location?.coordinate,
                                      pixelWidth: asset.pixelWidth,
                                      pixelHeight: asset.pixelHeight,
                                      isFavorite: asset.isFavorite)

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        // 蜂窝网络下默认不联网下载，避免消耗流量。
        options.isNetworkAccessAllowed = !NetworkStatusService.shared.isCellular ||
            NetworkStatusService.allowsCellularPhotoDownload
        let scale = UIScreen.main.scale
        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 1_600 * scale, height: 1_600 * scale),
            contentMode: .aspectFit,
            options: options
        ) { result, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
            let error = info?[PHImageErrorKey] as? Error
            DispatchQueue.main.async {
                guard !cancelled else { return }
                if let result {
                    image = result
                    isLoading = false
                } else if error != nil || (info?[PHImageResultIsInCloudKey] as? Bool) != true {
                    isLoading = false
                }
            }
        }
    }

    private func cancelImageRequest() {
        guard requestID != PHInvalidImageRequestID else { return }
        PHImageManager.default().cancelImageRequest(requestID)
        requestID = PHInvalidImageRequestID
    }

    private func deletePhoto() async {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            let result = try await PhotoLibraryMutationService.deletePhoto(
                assetIdentifier: item.assetIdentifier,
                container: modelContext.container
            )
            onDeleted(item.assetIdentifier)
            if result.cacheCleanupSucceeded {
                dismiss()
            } else {
                dismissesAfterMessage = true
                errorMessage = "照片已从系统相册删除，但 LifeTrack 缓存暂时未清理成功；下次刷新照片库时会自动修复。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } })
    }
}

struct PhotoGridThumbnail: View {
    let assetIdentifier: String
    var cornerRadius: CGFloat = 5

    var body: some View {
        PhotoThumbnailView(assetIdentifier: assetIdentifier,
                           cornerRadius: cornerRadius)
            .aspectRatio(1, contentMode: .fill)
            .contentShape(Rectangle())
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ()) {
        let result = layout(proposal: ProposedViewSize(width: bounds.width,
                                                       height: proposal.height),
                            subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x,
                                              y: bounds.minY + point.y),
                                  proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize,
                        subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let width = proposal.width ?? 0
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), points)
    }
}
