import Foundation
import Photos
import Vision
import UIKit
import CoreLocation
import ImageIO
import CoreML

struct PhotoLibraryAssetDescriptor: Identifiable, Sendable {
    let id: String
    let creationDate: Date
    let displayLatitude: Double?
    let displayLongitude: Double?
    let originalLatitude: Double?
    let originalLongitude: Double?
    let isSelfie: Bool
}

struct PhotoVisionAnalysisResult: Sendable {
    let categories: [PhotoSmartCategory]
    let topLabels: [String]
    let confidence: Double
    let faceCount: Int
    let state: PhotoAnalysisState
}

struct TravelSessionSnapshot: Sendable {
    let id: UUID
    let startTime: Date
    let endTime: Date
    let points: [TravelTrackPointSnapshot]
}

struct TravelTrackPointSnapshot: Sendable {
    let latitude: Double
    let longitude: Double
}

enum PhotoLibraryScanner {
    static func descriptors() -> [PhotoLibraryAssetDescriptor] {
        autoreleasepool {
            let selfieIDs = fetchSelfieIdentifiers()
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
            let assets = PHAsset.fetchAssets(with: options)
            var result: [PhotoLibraryAssetDescriptor] = []
            result.reserveCapacity(assets.count)

            assets.enumerateObjects { asset, _, _ in
                guard let date = asset.creationDate ?? asset.modificationDate else { return }
                let original = asset.location?.coordinate
                let display = original.map(ChinaMapCoordinateTransform.displayCoordinate(forPhotoCoordinate:))
                result.append(PhotoLibraryAssetDescriptor(id: asset.localIdentifier,
                                                          creationDate: date,
                                                          displayLatitude: display?.latitude,
                                                          displayLongitude: display?.longitude,
                                                          originalLatitude: original?.latitude,
                                                          originalLongitude: original?.longitude,
                                                          isSelfie: selfieIDs.contains(asset.localIdentifier)))
            }
            return result
        }
    }

    private static func fetchSelfieIdentifiers() -> Set<String> {
        guard let collection = PHAssetCollection.fetchAssetCollections(with: .smartAlbum,
                                                                        subtype: .smartAlbumSelfPortraits,
                                                                        options: nil).firstObject else { return [] }
        let assets = PHAsset.fetchAssets(in: collection, options: nil)
        var identifiers: Set<String> = []
        identifiers.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            identifiers.insert(asset.localIdentifier)
        }
        return identifiers
    }
}

enum PhotoVisionAnalysisService {
    // Vision sees only this small PhotoKit rendition. Originals never leave Photos or enter the analyzer.
    private static let thumbnailSize = CGSize(width: 384, height: 384)

    /// 蜂窝网络下默认不联网下载，避免消耗流量；用户在设置中开启后才允许。
    private static var isNetworkDownloadAllowed: Bool {
        !NetworkStatusService.shared.isCellular || NetworkStatusService.allowsCellularPhotoDownload
    }

    static func analyze(_ descriptor: PhotoLibraryAssetDescriptor) async -> PhotoVisionAnalysisResult {
        guard let thumbnail = await requestThumbnail(for: descriptor.id) else {
            return PhotoVisionAnalysisResult(categories: [.other],
                                             topLabels: [],
                                             confidence: 0,
                                             faceCount: 0,
                                             state: .thumbnailUnavailable)
        }

        return await Task.detached(priority: .utility) {
            autoreleasepool {
                analyzeLocally(thumbnail, isSelfie: descriptor.isSelfie)
            }
        }.value
    }

    private static func requestThumbnail(for identifier: String) async -> UIImage? {
        await withCheckedContinuation { continuation in
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
                continuation.resume(returning: nil)
                return
            }

            let request = PhotoThumbnailRequest(continuation: continuation)

            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isSynchronous = false
            // 蜂窝网络下默认不从 iCloud 下载缩略图，避免消耗流量（用户可在设置中开启）。
            options.isNetworkAccessAllowed = Self.isNetworkDownloadAllowed

            PHImageManager.default().requestImage(for: asset,
                                                  targetSize: thumbnailSize,
                                                  contentMode: .aspectFill,
                                                  options: options) { image, info in
                let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                let error = info?[PHImageErrorKey] as? Error
                if cancelled || error != nil {
                    request.finish(with: nil)
                } else if let image {
                    // A degraded callback is already a small PhotoKit rendition and is sufficient for classification.
                    request.finish(with: image)
                } else if (info?[PHImageResultIsInCloudKey] as? Bool) != true {
                    request.finish(with: nil)
                }
            }

            // An iCloud placeholder can first callback with no image and later deliver the requested rendition.
            // Bound the wait so an unreachable asset never stalls the whole batch.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) {
                request.finish(with: nil)
            }
        }
    }

    private static func analyzeLocally(_ image: UIImage, isSelfie: Bool) -> PhotoVisionAnalysisResult {
        guard let handler = visionHandler(for: image) else {
            return PhotoVisionAnalysisResult(categories: [.other],
                                             topLabels: [],
                                             confidence: 0,
                                             faceCount: 0,
                                             state: .failed)
        }

        let classificationRequest = VNClassifyImageRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()
#if targetEnvironment(simulator)
        // The simulator has no Neural Engine and can fail to create Vision's Espresso context.
        // Keep production devices on Vision's automatic low-power compute selection.
        forceCPUCompute(on: classificationRequest)
        forceCPUCompute(on: faceRequest)
#endif
        do {
            try handler.perform([classificationRequest, faceRequest])
            let observations = (classificationRequest.results ?? []).prefix(20)
            let faceCount = faceRequest.results?.count ?? 0
            return classify(observations: Array(observations), faceCount: faceCount, isSelfie: isSelfie)
        } catch {
            return PhotoVisionAnalysisResult(categories: [.other],
                                             topLabels: [],
                                             confidence: 0,
                                             faceCount: 0,
                                             state: .failed)
        }
    }

    private static func visionHandler(for image: UIImage) -> VNImageRequestHandler? {
        let orientation = image.imageOrientation.cgImageOrientation
        if let cgImage = image.cgImage {
            return VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        }
        if let ciImage = image.ciImage {
            return VNImageRequestHandler(ciImage: ciImage, orientation: orientation, options: [:])
        }

        // PhotoKit can return a UIImage backed by an internal decoded surface. Repaint only the
        // already downsized rendition so Vision still never sees or decodes the original asset.
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let cgImage = rendered.cgImage else { return nil }
        return VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
    }

#if targetEnvironment(simulator)
    private static func forceCPUCompute(on request: VNRequest) {
        guard let cpuDevice = MLComputeDevice.allComputeDevices.first(where: {
            if case .cpu = $0 { return true }
            return false
        }), let stages = try? request.supportedComputeStageDevices else { return }

        for (stage, devices) in stages where devices.contains(cpuDevice) {
            request.setComputeDevice(cpuDevice, for: stage)
        }
    }
#endif

    private static func classify(observations: [VNClassificationObservation],
                                 faceCount: Int,
                                 isSelfie: Bool) -> PhotoVisionAnalysisResult {
        var scores: [PhotoSmartCategory: Float] = [:]
        var topLabels: [String] = []

        for observation in observations where observation.confidence >= 0.06 {
            let label = observation.identifier.lowercased()
            topLabels.append("\(observation.identifier)|\(String(format: "%.3f", observation.confidence))")
            for category in PhotoSmartCategory.allCases where category != .other {
                if keywords[category, default: []].contains(where: { label.contains($0) }) {
                    scores[category] = max(scores[category] ?? 0, observation.confidence)
                }
            }
        }

        if faceCount > 0 {
            scores[.people] = max(scores[.people] ?? 0, min(0.62 + Float(faceCount - 1) * 0.05, 0.82))
        }
        if isSelfie {
            scores[.selfie] = 1
            scores[.people] = max(scores[.people] ?? 0, 0.8)
        }

        var categories = scores
            .filter { $0.value >= 0.14 }
            .sorted {
                if $0.value == $1.value { return categoryPriority($0.key) < categoryPriority($1.key) }
                return $0.value > $1.value
            }
            .map(\.key)

        if isSelfie {
            categories.removeAll { $0 == .selfie }
            categories.insert(.selfie, at: 0)
        }
        if categories.isEmpty { categories = [.other] }

        let confidence = Double(scores[categories[0]] ?? (categories[0] == .other ? 0 : 0.5))
        return PhotoVisionAnalysisResult(categories: Array(categories.prefix(4)),
                                         topLabels: Array(topLabels.prefix(10)),
                                         confidence: confidence,
                                         faceCount: faceCount,
                                         state: .completed)
    }

    private static func categoryPriority(_ category: PhotoSmartCategory) -> Int {
        PhotoSmartCategory.allCases.firstIndex(of: category) ?? Int.max
    }

    private static let keywords: [PhotoSmartCategory: [String]] = [
        .landscape: ["landscape", "mountain", "hill", "valley", "canyon", "lake", "river", "waterfall", "ocean", "sea", "beach", "coast", "island", "sky", "cloud", "sunset", "sunrise", "scenery", "outdoor", "horizon", "snow", "desert", "countryside"],
        .architecture: ["architecture", "building", "skyscraper", "tower", "bridge", "castle", "palace", "temple", "church", "cathedral", "monument", "museum", "stadium", "house", "apartment", "interior", "room", "street", "city", "urban", "campus"],
        .food: ["food", "dish", "meal", "cuisine", "breakfast", "lunch", "dinner", "restaurant", "dessert", "cake", "bread", "fruit", "vegetable", "meat", "seafood", "noodle", "rice", "pizza", "burger", "drink", "coffee", "tea", "snack"],
        .people: ["person", "people", "portrait", "human", "face", "crowd", "family", "friend", "wedding", "child", "baby", "man", "woman", "group"],
        .animal: ["animal", "pet", "dog", "cat", "bird", "fish", "horse", "cow", "sheep", "rabbit", "insect", "butterfly", "zoo", "wildlife", "deer", "elephant", "panda", "tiger", "lion"],
        .plant: ["plant", "flower", "blossom", "tree", "leaf", "garden", "grass", "forest", "woodland", "botanical", "bouquet", "succulent", "vegetation"],
        .sport: ["sport", "athlete", "running", "jogging", "cycling", "bicycle", "football", "soccer", "basketball", "baseball", "tennis", "badminton", "swimming", "skiing", "skating", "gym", "workout", "hiking", "climbing", "fitness"],
        .selfie: ["selfie", "self portrait", "self-portrait"],
        .night: ["night", "nighttime", "nightscape", "darkness", "moon", "star", "astronomy", "firework", "neon", "low light", "city lights"],
        .other: []
    ]
}

private final class PhotoThumbnailRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?

    init(continuation: CheckedContinuation<UIImage?, Never>) {
        self.continuation = continuation
    }

    func finish(with image: UIImage?) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: image)
    }
}

enum PhotoTrackAssociationService {
    static func snapshots(from sessions: [ActivitySession]) -> [TravelSessionSnapshot] {
        sessions.map { session in
            let ordered = session.trackPoints
                .filter(\.isUsableForAnalysis)
                .sorted { $0.timestamp < $1.timestamp }
            let stride = max(ordered.count / 160, 1)
            let sampled: [TravelTrackPointSnapshot] = ordered.enumerated().compactMap { index, point in
                guard index % stride == 0 || index == ordered.count - 1 else { return nil }
                return TravelTrackPointSnapshot(latitude: point.latitude, longitude: point.longitude)
            }
            return TravelSessionSnapshot(id: session.id,
                                         startTime: session.startTime,
                                         endTime: session.endTime ?? session.startTime.addingTimeInterval(session.duration),
                                         points: sampled)
        }
    }

    static func bestSessionID(for descriptor: PhotoLibraryAssetDescriptor,
                              sessions: [TravelSessionSnapshot]) -> UUID? {
        bestSessionID(date: descriptor.creationDate,
                      latitude: descriptor.originalLatitude,
                      longitude: descriptor.originalLongitude,
                      sessions: sessions)
    }

    static func bestSessionID(date: Date,
                              latitude: Double?,
                              longitude: Double?,
                              sessions: [TravelSessionSnapshot]) -> UUID? {
        var best: (id: UUID, score: Double)?
        for session in sessions {
            let timeGap: TimeInterval
            if date >= session.startTime && date <= session.endTime {
                timeGap = 0
            } else {
                timeGap = min(abs(date.timeIntervalSince(session.startTime)),
                              abs(date.timeIntervalSince(session.endTime)))
            }
            guard timeGap <= 8 * 60 * 60 else { continue }

            var distance = 0.0
            if let latitude, let longitude, !session.points.isEmpty {
                let photoLocation = CLLocation(latitude: latitude, longitude: longitude)
                distance = session.points.map {
                    photoLocation.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
                }.min() ?? .greatestFiniteMagnitude
                guard distance <= 12_000 else { continue }
            } else {
                guard timeGap <= 90 * 60 else { continue }
            }

            let score = timeGap / 3_600 + distance / 2_500
            if best == nil || score < best!.score {
                best = (session.id, score)
            }
        }
        return best?.id
    }
}

private extension UIImage.Orientation {
    var cgImageOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
