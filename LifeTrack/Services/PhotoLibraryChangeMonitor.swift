import Foundation
import Photos

/// 监听系统照片库变化，避免每次进入页面都全库重新扫描。
///
/// `PhotoLibraryScanner` 的扫描结果会按“库代次”缓存：只有照片库真正发生变化
/// （`photoLibraryDidChange` 触发）时才需要重新枚举相册。
final class PhotoLibraryChangeMonitor: NSObject, ObservableObject {
    static let shared = PhotoLibraryChangeMonitor()

    /// 单调递增的照片库代次，库内容变化时 +1。
    @Published private(set) var generation: Int = 0

    private let lock = NSLock()
    private var registered = false

    private override init() {
        super.init()
    }

    /// 注册为照片库观察者（幂等）。由需要扫描照片库的页面调用。
    func ensureRegistered() {
        lock.lock()
        let shouldRegister = !registered
        registered = true
        lock.unlock()

        guard shouldRegister else { return }
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }
}

extension PhotoLibraryChangeMonitor: PHPhotoLibraryChangeObserver {
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.generation += 1
        }
    }
}

/// 照片库扫描结果缓存：按代次缓存，代次不变则直接复用，避免重复全库扫描。
enum PhotoLibraryScanCache {
    private static let lock = NSLock()
    private static var cachedGeneration: Int?
    private static var cachedDescriptors: [PhotoLibraryAssetDescriptor]?

    /// 返回当前代次的描述符。若库未变化则复用缓存，否则重新扫描。
    static func descriptors(currentGeneration: Int) -> [PhotoLibraryAssetDescriptor] {
        lock.lock()
        defer { lock.unlock() }

        if let cachedGeneration, cachedGeneration == currentGeneration, let cachedDescriptors {
            return cachedDescriptors
        }

        let descriptors = PhotoLibraryScanner.descriptors()
        cachedGeneration = currentGeneration
        cachedDescriptors = descriptors
        return descriptors
    }

    /// 强制失效（例如授权状态变化、手动刷新时）。
    static func invalidate() {
        lock.lock()
        cachedGeneration = nil
        cachedDescriptors = nil
        lock.unlock()
    }
}
