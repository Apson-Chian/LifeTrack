import Foundation
import Photos
import SwiftData

struct PhotoDeletionResult {
    let cacheCleanupSucceeded: Bool
}

enum PhotoLibraryMutationError: LocalizedError {
    case permissionDenied
    case assetUnavailable
    case deletionFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "没有照片图库的读写权限，请在系统设置中允许 LifeTrack 访问照片。"
        case .assetUnavailable:
            "这张照片已不在当前可访问的照片图库中。"
        case let .deletionFailed(message):
            "无法从系统相册删除照片：\(message)"
        }
    }
}

extension Notification.Name {
    static let lifeTrackPhotoLibraryDidChange = Notification.Name("LifeTrackPhotoLibraryDidChange")
}

@MainActor
enum PhotoLibraryMutationService {
    static func deletePhoto(assetIdentifier: String,
                            container: ModelContainer) async throws -> PhotoDeletionResult {
        let authorization = await authorizationStatus()
        guard authorization == .authorized || authorization == .limited else {
            throw PhotoLibraryMutationError.permissionDenied
        }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
        guard let asset = fetchResult.firstObject else {
            let cleaned = cleanCache(assetIdentifier: assetIdentifier, container: container)
            NotificationCenter.default.post(name: .lifeTrackPhotoLibraryDidChange,
                                            object: nil,
                                            userInfo: ["assetIdentifier": assetIdentifier])
            if cleaned { return PhotoDeletionResult(cacheCleanupSucceeded: true) }
            throw PhotoLibraryMutationError.assetUnavailable
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets([asset] as NSArray)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    let message = error?.localizedDescription ?? "照片图库拒绝了删除请求"
                    continuation.resume(throwing: PhotoLibraryMutationError.deletionFailed(message))
                }
            }
        }

        let cacheCleanupSucceeded = cleanCache(assetIdentifier: assetIdentifier,
                                                container: container)
        NotificationCenter.default.post(name: .lifeTrackPhotoLibraryDidChange,
                                        object: nil,
                                        userInfo: ["assetIdentifier": assetIdentifier])
        return PhotoDeletionResult(cacheCleanupSucceeded: cacheCleanupSucceeded)
    }

    private static func authorizationStatus() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    static func cleanCache(assetIdentifier: String,
                           container: ModelContainer) -> Bool {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            let identifier = assetIdentifier
            let descriptor = FetchDescriptor<PhotoAnalysisRecord>(
                predicate: #Predicate { $0.assetIdentifier == identifier }
            )
            for record in try context.fetch(descriptor) {
                context.delete(record)
            }

            for node in try context.fetch(FetchDescriptor<TravelTimelineNode>())
                where node.photoIdentifiers.contains(assetIdentifier) {
                node.photoIdentifiersRawValue = node.photoIdentifiers
                    .filter { $0 != assetIdentifier }
                    .joined(separator: "\n")
            }
            try context.save()
            return true
        } catch {
            context.rollback()
            return false
        }
    }
}
