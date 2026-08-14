import Foundation
import Network

/// 轻量网络状态探测：判断当前是否为蜂窝网络。
/// 用于避免在蜂窝网络下自动下载 iCloud 照片缩略图，节省流量。
final class NetworkStatusService: ObservableObject {
    static let shared = NetworkStatusService()

    @Published private(set) var isCellular: Bool = false
    @Published private(set) var isExpensive: Bool = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.lifetrack.network-status")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isCellular = path.usesInterfaceType(.cellular)
                self?.isExpensive = path.isExpensive
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

extension NetworkStatusService {
    private static let allowCellularPhotoDownloadKey = "allowCellularPhotoDownload"

    /// 是否允许在蜂窝网络下下载 iCloud 照片缩略图（默认关闭，省流量）。
    static var allowsCellularPhotoDownload: Bool {
        UserDefaults.standard.bool(forKey: allowCellularPhotoDownloadKey)
    }

    static func setAllowsCellularPhotoDownload(_ allowed: Bool) {
        UserDefaults.standard.set(allowed, forKey: allowCellularPhotoDownloadKey)
    }
}
