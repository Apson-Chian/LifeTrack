import CoreLocation
import Photos
import SwiftUI

// MARK: - 缩略图缓存（保留 PHCachingImageManager，避免加载原图）

/// 共享的 PHCachingImageManager，用于相册网格缩略图预取与缓存。
enum PhotoThumbnailCacheManager {
    static let shared = PHCachingImageManager()
    static let thumbnailSize = CGSize(width: 400, height: 400)
}

// MARK: - 瀑布流布局（双列，保持原图宽高比）

struct AspectRatioKey: LayoutValueKey {
    static let defaultValue: CGFloat = 1
}

/// 双列（可配置列数）瀑布流：每个子视图按自身宽高比放入当前最短的一列，
/// 高度由列宽 / 宽高比推导。配合 .layoutValue(key: AspectRatioKey.self) 使用。
struct WaterfallLayout: Layout {
    var columnCount: Int = 2
    var spacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        guard width > 0, !subviews.isEmpty else { return .zero }
        let colWidth = columnWidth(in: width)
        var heights = Array(repeating: CGFloat(0), count: max(columnCount, 1))
        for subview in subviews {
            let aspect = max(subview[AspectRatioKey.self], 0.3)
            let h = colWidth / aspect
            let col = shortestColumn(heights)
            heights[col] += h + spacing
        }
        let total = max(heights.max() ?? 0, 0)
        let trimmed = total > 0 ? total - spacing : 0
        return CGSize(width: width, height: trimmed)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let colWidth = columnWidth(in: bounds.width)
        var heights = Array(repeating: CGFloat(0), count: max(columnCount, 1))
        var xOffsets = [CGFloat]()
        for c in 0..<max(columnCount, 1) {
            xOffsets.append(bounds.minX + CGFloat(c) * (colWidth + spacing))
        }
        for subview in subviews {
            let aspect = max(subview[AspectRatioKey.self], 0.3)
            let h = colWidth / aspect
            let col = shortestColumn(heights)
            let x = xOffsets[col]
            let y = bounds.minY + heights[col]
            subview.place(at: CGPoint(x: x, y: y),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: colWidth, height: h))
            heights[col] += h + spacing
        }
    }

    private func columnWidth(in totalWidth: CGFloat) -> CGFloat {
        let c = max(columnCount, 1)
        return (totalWidth - CGFloat(c - 1) * spacing) / CGFloat(c)
    }

    private func shortestColumn(_ heights: [CGFloat]) -> Int {
        var idx = 0
        var min = heights.first ?? 0
        for i in 1..<heights.count where heights[i] < min {
            min = heights[i]
            idx = i
        }
        return idx
    }
}

// MARK: - 精选区 Mosaic 布局（按数量自动错落）

/// 顶部 1~6 张照片的 Mosaic 布局：根据照片数量选择预设的错落矩形，
/// 单张时按原图宽高比定高，多张时统一裁切填充（接近 Apple Photos 精选区）。
struct MosaicLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let (_, height) = layoutRects(count: subviews.count,
                                     aspect: subviews.first?[AspectRatioKey.self] ?? 1,
                                     width: width)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (rects, _) = layoutRects(count: subviews.count,
                                     aspect: subviews.first?[AspectRatioKey.self] ?? 1,
                                     width: bounds.width)
        for (index, subview) in subviews.enumerated() {
            guard index < rects.count else { continue }
            let r = rects[index]
            let x = bounds.minX + r.minX * bounds.width
            let y = bounds.minY + r.minY * bounds.height
            let w = r.width * bounds.width
            let h = r.height * bounds.height
            subview.place(at: CGPoint(x: x, y: y),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: w, height: h))
        }
    }

    /// 返回归一化矩形（0~1）与整体高度。
    private func layoutRects(count: Int, aspect: CGFloat, width: CGFloat) -> ([CGRect], CGFloat) {
        let c = min(max(count, 0), 6)
        let height: CGFloat
        let rects: [CGRect]
        switch c {
        case 0:
            return ([], 0)
        case 1:
            // 单张按原图宽高比（宽/高）定高，避免被裁切过多
            let a = min(max(aspect, 0.7), 1.6)
            height = width / a
            rects = [CGRect(x: 0, y: 0, width: 1, height: 1)]
        case 2:
            height = width * 0.5
            rects = [CGRect(x: 0, y: 0, width: 0.5, height: 1),
                     CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]
        case 3:
            height = width * 0.62
            rects = [CGRect(x: 0, y: 0, width: 0.666, height: 1),
                     CGRect(x: 0.666, y: 0, width: 0.334, height: 0.5),
                     CGRect(x: 0.666, y: 0.5, width: 0.334, height: 0.5)]
        case 4:
            height = width * 0.5
            rects = [CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                     CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5),
                     CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5),
                     CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
        case 5:
            height = width * 0.6
            rects = [CGRect(x: 0, y: 0, width: 0.6, height: 0.6),
                     CGRect(x: 0.6, y: 0, width: 0.4, height: 0.6),
                     CGRect(x: 0, y: 0.6, width: 0.3, height: 0.4),
                     CGRect(x: 0.3, y: 0.6, width: 0.3, height: 0.4),
                     CGRect(x: 0.6, y: 0.6, width: 0.4, height: 0.4)]
        default: // 6
            height = width * 0.6
            rects = [CGRect(x: 0, y: 0, width: 0.6, height: 0.6),
                     CGRect(x: 0.6, y: 0, width: 0.4, height: 0.3),
                     CGRect(x: 0.6, y: 0.3, width: 0.4, height: 0.3),
                     CGRect(x: 0, y: 0.6, width: 0.3, height: 0.4),
                     CGRect(x: 0.3, y: 0.6, width: 0.3, height: 0.4),
                     CGRect(x: 0.6, y: 0.6, width: 0.4, height: 0.4)]
        }
        return (rects, height)
    }
}

// MARK: - 网格缩略图（保持宽高比 + 渐变占位）

/// 单张缩略图：从 PHCachingImageManager 请求 400×400 缓存缩略图，
/// 按容器宽高比裁切填充；未加载时显示渐变占位，避免死灰/黑块。
struct PhotoGalleryThumbnailView: View {
    let assetIdentifier: String
    var cornerRadius: CGFloat = 3

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID = PHInvalidImageRequestID

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(LinearGradient(
                        colors: [Color(uiColor: .tertiarySystemBackground),
                                 Color(uiColor: .secondarySystemBackground)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing))
                Image(systemName: "photo")
                    .font(.title3)
                    .foregroundStyle(.quaternary)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onAppear(perform: request)
        .onDisappear(perform: cancel)
    }

    private func request() {
        guard image == nil,
              !assetIdentifier.isEmpty,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        requestID = PhotoThumbnailCacheManager.shared.requestImage(
            for: asset,
            targetSize: PhotoThumbnailCacheManager.thumbnailSize,
            contentMode: .aspectFill,
            options: options
        ) { result, _ in
            guard let result else { return }
            DispatchQueue.main.async { self.image = result }
        }
    }

    private func cancel() {
        guard requestID != PHInvalidImageRequestID else { return }
        PhotoThumbnailCacheManager.shared.cancelImageRequest(requestID)
        requestID = PHInvalidImageRequestID
    }
}

/// 统一的相册方格缩略图：先固定正方形布局，再让图片填充，避免原图比例影响父级布局。
struct PhotoSquareThumbnail: View {
    let assetIdentifier: String
    var cornerRadius: CGFloat = 14

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                PhotoGalleryThumbnailView(assetIdentifier: assetIdentifier,
                                           cornerRadius: cornerRadius)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - 画廊内容（Mosaic 精选区 + 双列瀑布流）

/// 照片分类结果的核心排版：统一双列方格，确保不同相册入口的视觉和布局一致。
/// 仅负责照片展示与排版，不触碰分类 / PhotoKit 读取 / 数据模型逻辑。
struct PhotoGalleryContentView: View {
    let items: [PhotoDetailItem]
    var featuredCount: Int = 5
    var spacing: CGFloat = 3
    var linkedBadge: Bool = false
    var onDelete: ((PhotoDetailItem) async -> Void)? = nil

    @State private var hiddenAssetIdentifiers: Set<String> = []
    @State private var aspectRatios: [String: CGFloat] = [:]
    @State private var selectedItem: PhotoDetailItem?
    /// 进入全屏时固化的照片列表快照，避免浏览中隐藏照片导致索引越界。
    @State private var viewerItems: [PhotoDetailItem] = []

    private var visibleItems: [PhotoDetailItem] {
        items.filter { !hiddenAssetIdentifiers.contains($0.assetIdentifier) }
    }

    var body: some View {
        Group {
            if visibleItems.isEmpty {
                ContentUnavailableView("暂无照片",
                                       systemImage: "photo.stack",
                                       description: Text("该分类中没有仍可访问的照片。"))
                    .frame(minHeight: 420)
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ], spacing: 10) {
                    ForEach(visibleItems) { item in
                        thumbnailButton(item, radius: 14)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .padding(.bottom, 96)
            }
        }
        .task { await loadAspectRatios() }
        .onDisappear(perform: stopPrefetch)
        .fullScreenCover(item: $selectedItem) { item in
            PhotoFullscreenViewer(
                items: viewerItems,
                startIndex: max(0, viewerItems.firstIndex(where: { $0.assetIdentifier == item.assetIdentifier }) ?? 0),
                onHide: { id in
                    hiddenAssetIdentifiers.insert(id)
                    if visibleItems.count <= 1 { selectedItem = nil }
                },
                onDelete: { target in
                    await onDelete?(target)
                    hiddenAssetIdentifiers.insert(target.assetIdentifier)
                    if visibleItems.count <= 1 { selectedItem = nil }
                }
            )
        }
    }

    private func thumbnailButton(_ item: PhotoDetailItem, radius: CGFloat) -> some View {
        Button {
            selectedItem = item
            viewerItems = visibleItems
        } label: {
            PhotoSquareThumbnail(assetIdentifier: item.assetIdentifier,
                                 cornerRadius: radius)
                .overlay(alignment: .bottomLeading) {
                    if linkedBadge, item.linkedSessionID != nil {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(.black.opacity(0.45), in: Circle())
                            .padding(5)
                    }
                }
        }
        .buttonStyle(.plain)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: radius))
    }

    // MARK: 宽高比（不加载原图，仅读 PHAsset 像素尺寸）

    private func loadAspectRatios() async {
        let identifiers = items.map(\.assetIdentifier)
        guard !identifiers.isEmpty else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var ratios: [String: CGFloat] = [:]
        assets.enumerateObjects { asset, _, _ in
            let w = asset.pixelWidth
            let h = asset.pixelHeight
            ratios[asset.localIdentifier] = (w > 0 && h > 0) ? CGFloat(w) / CGFloat(h) : 1
        }
        await MainActor.run { aspectRatios = ratios }
        prefetch(assets: assets)
    }

    private func prefetch(assets: PHFetchResult<PHAsset>) {
        var list: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in list.append(asset) }
        guard !list.isEmpty else { return }
        PhotoThumbnailCacheManager.shared.startCachingImages(
            for: list,
            targetSize: PhotoThumbnailCacheManager.thumbnailSize,
            contentMode: .aspectFill,
            options: nil)
    }

    private func stopPrefetch() {
        let identifiers = items.map(\.assetIdentifier)
        guard !identifiers.isEmpty else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var list: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in list.append(asset) }
        guard !list.isEmpty else { return }
        PhotoThumbnailCacheManager.shared.stopCachingImages(
            for: list,
            targetSize: PhotoThumbnailCacheManager.thumbnailSize,
            contentMode: .aspectFill,
            options: nil)
    }
}

// MARK: - 沉浸式全屏浏览（左右滑动）

struct PhotoFullscreenViewer: View {
    let items: [PhotoDetailItem]
    let startIndex: Int
    var onHide: (String) -> Void = { _ in }
    var onDelete: ((PhotoDetailItem) async -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var confirmsDeletion = false

    init(items: [PhotoDetailItem],
         startIndex: Int,
         onHide: @escaping (String) -> Void = { _ in },
         onDelete: ((PhotoDetailItem) async -> Void)? = nil) {
        self.items = items
        self.startIndex = startIndex
        self._currentIndex = State(initialValue: max(0, min(startIndex, items.count - 1)))
        self.onHide = onHide
        self.onDelete = onDelete
    }

    var body: some View {
        TabView(selection: $currentIndex) {
            ForEach(items.indices, id: \.self) { index in
                PhotoFullscreenPage(item: items[index])
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .background(.black)
        .ignoresSafeArea()
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .bottom) { bottomBar }
        .alert("从系统相册删除这张照片？", isPresented: $confirmsDeletion) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                Task {
                    await onDelete?(items[currentIndex])
                    if items.count <= 1 { dismiss() }
                }
            }
        } message: {
            Text("照片会同步从 Apple 照片图库移除，并移除 LifeTrack 的分类缓存。")
        }
    }

    private var topBar: some View {
        HStack(spacing: 22) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }
            Spacer()
            if onDelete != nil {
                Button { confirmsDeletion = true } label: {
                    Image(systemName: "trash")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
            }
            Button {
                let id = items[currentIndex].assetIdentifier
                onHide(id)
                if items.count <= 1 {
                    dismiss()
                } else if currentIndex >= items.count - 1 {
                    currentIndex = max(0, items.count - 2)
                }
            } label: {
                Image(systemName: "eye.slash")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(LinearGradient(colors: [.black.opacity(0.55), .clear],
                                   startPoint: .top,
                                   endPoint: .bottom))
    }

    private var bottomBar: some View {
        HStack {
            Text(items[currentIndex].creationDate.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.white)
            Spacer()
            Text("\(currentIndex + 1) / \(items.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                   startPoint: .top,
                                   endPoint: .bottom))
    }
}

private struct PhotoFullscreenPage: View {
    let item: PhotoDetailItem

    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var requestID: PHImageRequestID = PHInvalidImageRequestID

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if isLoading {
                ProgressView()
                    .tint(.white)
            } else {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .ignoresSafeArea()
        .onAppear(perform: load)
        .onDisappear(perform: cancel)
    }

    private func load() {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [item.assetIdentifier],
                                              options: nil).firstObject else {
            isLoading = false
            return
        }
        let scale = UIScreen.main.scale
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = !NetworkStatusService.shared.isCellular ||
            NetworkStatusService.allowsCellularPhotoDownload
        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 1_600 * scale, height: 1_600 * scale),
            contentMode: .aspectFit,
            options: options
        ) { result, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
            guard !cancelled else { return }
            DispatchQueue.main.async {
                if let result {
                    image = result
                    isLoading = false
                } else {
                    isLoading = false
                }
            }
        }
    }

    private func cancel() {
        guard requestID != PHInvalidImageRequestID else { return }
        PHImageManager.default().cancelImageRequest(requestID)
        requestID = PHInvalidImageRequestID
    }
}
