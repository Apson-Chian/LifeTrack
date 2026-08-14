import CoreLocation
import Foundation

/// 把照片作为运动轨迹的“时刻节点”，而不是用照片替代 GPS 或凭照片生成路线。
/// 有定位的照片必须与轨迹相距不超过 2 km；无定位照片必须在运动时段附近，
/// 再使用时间最近的 GPS 点作为展示位置。全部计算只在本机完成。
@MainActor
enum TodayPhotoTrackService {
    private static let maximumPhotoDistance: CLLocationDistance = 2_000
    private static let maximumUnlocatedTimeGap: TimeInterval = 90 * 60

    static func moments(descriptors: [PhotoLibraryAssetDescriptor],
                        sessions: [ActivitySession],
                        calendar: Calendar = .current) -> [TrackPhotoMoment] {
        let todayDescriptors = descriptors.filter { calendar.isDateInToday($0.creationDate) }
        guard !todayDescriptors.isEmpty, !sessions.isEmpty else { return [] }
        let snapshots = PhotoTrackAssociationService.snapshots(from: sessions)
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        return todayDescriptors.compactMap { descriptor in
            guard let sessionID = PhotoTrackAssociationService.bestSessionID(for: descriptor,
                                                                              sessions: snapshots),
                  let session = sessionsByID[sessionID] else { return nil }
            let points = session.trackPoints.filter(\.isUsableForAnalysis)
                .sorted { $0.timestamp < $1.timestamp }
            guard !points.isEmpty else { return nil }

            if let latitude = descriptor.originalLatitude,
               let longitude = descriptor.originalLongitude {
                let photoLocation = CLLocation(latitude: latitude, longitude: longitude)
                let nearestDistance = points.map {
                    photoLocation.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
                }.min() ?? .greatestFiniteMagnitude
                guard nearestDistance <= maximumPhotoDistance else { return nil }
                let coordinate = CLLocationCoordinate2D(latitude: descriptor.displayLatitude ?? latitude,
                                                        longitude: descriptor.displayLongitude ?? longitude)
                return TrackPhotoMoment(assetIdentifier: descriptor.id,
                                        creationDate: descriptor.creationDate,
                                        coordinate: coordinate,
                                        sessionID: sessionID,
                                        usesPhotoLocation: true)
            }

            guard let nearestPoint = points.min(by: {
                abs($0.timestamp.timeIntervalSince(descriptor.creationDate)) <
                    abs($1.timestamp.timeIntervalSince(descriptor.creationDate))
            }),
            abs(nearestPoint.timestamp.timeIntervalSince(descriptor.creationDate)) <= maximumUnlocatedTimeGap else {
                return nil
            }
            return TrackPhotoMoment(assetIdentifier: descriptor.id,
                                    creationDate: descriptor.creationDate,
                                    coordinate: .init(latitude: nearestPoint.latitude,
                                                      longitude: nearestPoint.longitude),
                                    sessionID: sessionID,
                                    usesPhotoLocation: false)
        }
        .sorted { $0.creationDate < $1.creationDate }
    }
}
