import CoreLocation
import Foundation
import SwiftData

enum BackupServiceError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidFile(String)
    case fileTooLarge
    case persistence

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            "此备份使用版本 \(version)，当前 LifeTrack 仅支持版本 \(LifeTrackBackup.currentVersion)。"
        case .invalidFile(let detail):
            "备份文件无效：\(detail)"
        case .fileTooLarge:
            "备份文件超过 200 MB，无法恢复。"
        case .persistence:
            "备份已读取，但部分数据无法保存。请保留原文件并稍后重试。"
        }
    }
}

struct BackupRestoreResult {
    let insertedSessions: Int
    let insertedTrackPoints: Int
    let insertedPlaces: Int
    let insertedStays: Int
    let insertedOtherRecords: Int

    var totalInserted: Int {
        insertedSessions + insertedTrackPoints + insertedPlaces + insertedStays + insertedOtherRecords
    }
}

@MainActor
enum BackupService {
    static let lastBackupDateKey = "lastSuccessfulBackupDate"
    private static let maximumFileSize = 200 * 1024 * 1024
    private static let maximumSessionCount = 250_000
    private static let maximumTrackPointCount = 2_000_000
    private static let maximumPlaceCount = 100_000
    private static let maximumStayCount = 1_000_000
    private static let maximumOtherRecordCount = 1_000_000

    static var lastBackupDate: Date? {
        UserDefaults.standard.object(forKey: lastBackupDateKey) as? Date
    }

    static func createBackup(from context: ModelContext) async throws -> URL {
        let backup = LifeTrackBackup(
            backupVersion: LifeTrackBackup.currentVersion,
            createdAt: .now,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            sessions: try context.fetch(FetchDescriptor<ActivitySession>()).map(SessionBackup.init),
            trackPoints: try context.fetch(FetchDescriptor<TrackPoint>()).map(TrackPointBackup.init),
            places: try context.fetch(FetchDescriptor<CustomPlace>()).map(CustomPlaceBackup.init),
            geofences: try context.fetch(FetchDescriptor<PlaceGeofence>()).map(PlaceGeofenceBackup.init),
            stays: try context.fetch(FetchDescriptor<StayRecord>()).map(StayRecordBackup.init),
            dailySummaries: try context.fetch(FetchDescriptor<DailySummary>()).map(DailySummaryBackup.init),
            photoRecords: try context.fetch(FetchDescriptor<PhotoAnalysisRecord>()).map(PhotoAnalysisBackup.init),
            timelineTrips: try context.fetch(FetchDescriptor<TravelTimelineTrip>()).map(TimelineTripBackup.init),
            timelineNodes: try context.fetch(FetchDescriptor<TravelTimelineNode>()).map(TimelineNodeBackup.init),
            journeys: try context.fetch(FetchDescriptor<JourneyRecord>()).map(JourneyBackup.init),
            travelArchives: try context.fetch(FetchDescriptor<TravelArchiveRecord>()).map(TravelArchiveBackup.init)
        )

        // 编码整库备份随数据量线性增长且 CPU 密集，放到后台队列执行，避免大备份冻结 UI。
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    let encoded = try encoder.encode(backup)
                    continuation.resume(returning: encoded)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LifeTrack-Backup-\(fileDate(.now)).lifetrackbackup.json")
        try data.write(to: url, options: .atomic)
        UserDefaults.standard.set(Date.now, forKey: lastBackupDateKey)
        return url
    }

    static func restoreBackup(at url: URL, into destinationContext: ModelContext) throws -> BackupRestoreResult {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess { url.stopAccessingSecurityScopedResource() }
        }

        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard resourceValues.isRegularFile != false else {
            throw BackupServiceError.invalidFile("请选择普通备份文件")
        }
        if let fileSize = resourceValues.fileSize, fileSize > maximumFileSize {
            throw BackupServiceError.fileTooLarge
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumFileSize else { throw BackupServiceError.fileTooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup: LifeTrackBackup
        do {
            backup = try decoder.decode(LifeTrackBackup.self, from: data)
        } catch {
            throw BackupServiceError.invalidFile(error.localizedDescription)
        }
        guard backup.backupVersion == LifeTrackBackup.currentVersion else {
            throw BackupServiceError.unsupportedVersion(backup.backupVersion)
        }
        try validate(backup)

        let context = ModelContext(destinationContext.container)
        context.autosaveEnabled = false

        var insertedSessions = 0
        var insertedTrackPoints = 0
        var insertedPlaces = 0
        var insertedStays = 0
        var insertedOtherRecords = 0

        var sessionsByID = Dictionary(uniqueKeysWithValues:
            try context.fetch(FetchDescriptor<ActivitySession>()).map { ($0.id, $0) })
        let existingPointIDs = Set(try context.fetch(FetchDescriptor<TrackPoint>()).map(\.id))
        let existingPlaceIDs = Set(try context.fetch(FetchDescriptor<CustomPlace>()).map(\.id))
        let existingGeofencePlaceIDs = Set(try context.fetch(FetchDescriptor<PlaceGeofence>()).map(\.placeID))
        let existingStayIDs = Set(try context.fetch(FetchDescriptor<StayRecord>()).map(\.id))
        let existingDailyIDs = Set(try context.fetch(FetchDescriptor<DailySummary>()).map(\.id))
        let existingPhotoIDs = Set(try context.fetch(FetchDescriptor<PhotoAnalysisRecord>()).map(\.assetIdentifier))

        for value in backup.places where !existingPlaceIDs.contains(value.id) {
            let place = CustomPlace(shortName: value.shortName,
                                    officialName: value.officialName,
                                    note: value.note,
                                    latitude: value.latitude,
                                    longitude: value.longitude,
                                    radius: value.radius,
                                    category: PlaceCategory(rawValue: value.categoryRawValue) ?? .other,
                                    symbolName: value.symbolName,
                                    isFavorite: value.isFavorite,
                                    isAlwaysVisible: value.isAlwaysVisible,
                                    isCampusPlace: value.isCampusPlace,
                                    priority: value.priority)
            place.id = value.id
            place.createdAt = value.createdAt
            place.updatedAt = value.updatedAt
            context.insert(place)
            insertedPlaces += 1
        }

        for value in backup.geofences ?? [] where !existingGeofencePlaceIDs.contains(value.placeID) {
            guard existingPlaceIDs.contains(value.placeID) || backup.places.contains(where: { $0.id == value.placeID }) else { continue }
            let vertices = value.vertices.compactMap { pair -> CLLocationCoordinate2D? in
                guard pair.count == 2 else { return nil }
                let coordinate = CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
                return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
            }
            context.insert(PlaceGeofence(placeID: value.placeID,
                                         areaType: PlaceAreaType(rawValue: value.areaTypeRawValue) ?? .ordinary,
                                         vertices: vertices))
            insertedOtherRecords += 1
        }

        for value in backup.sessions where sessionsByID[value.id] == nil {
            let session = ActivitySession(activityType: ActivityType(rawValue: value.activityTypeRawValue) ?? .unknown,
                                          source: value.sourceRawValue,
                                          startTime: value.startTime)
            session.id = value.id
            session.endTime = value.endTime
            session.distance = value.distance
            session.duration = value.duration
            // Restores are merge-only. Incomplete rows are safely closed below instead of silently starting sensors.
            session.isActive = false
            session.destinationName = value.destinationName
            session.destinationLatitude = value.destinationLatitude
            session.destinationLongitude = value.destinationLongitude
            session.manualActivityTypeRawValue = value.manualActivityTypeRawValue
            session.importFingerprint = value.importFingerprint
            context.insert(session)
            sessionsByID[value.id] = session
            insertedSessions += 1
        }

        var latestRestoredPoint: [UUID: Date] = [:]
        for value in backup.trackPoints where !existingPointIDs.contains(value.id) {
            guard let session = value.sessionID.flatMap({ sessionsByID[$0] }) else { continue }
            let point = TrackPoint(latitude: value.latitude,
                                   longitude: value.longitude,
                                   altitude: value.altitude,
                                   speed: value.speed,
                                   course: value.course,
                                   horizontalAccuracy: value.horizontalAccuracy,
                                   timestamp: value.timestamp,
                                   activityType: ActivityType(rawValue: value.activityTypeRawValue) ?? .unknown,
                                   isAnomaly: value.isAnomaly,
                                   anomalyReason: value.anomalyReasonRawValue.flatMap(TrackPointAnomalyReason.init(rawValue:)),
                                   session: session)
            point.id = value.id
            context.insert(point)
            insertedTrackPoints += 1
            latestRestoredPoint[session.id] = max(latestRestoredPoint[session.id] ?? .distantPast,
                                                  point.timestamp)
        }

        for value in backup.sessions where value.isActive {
            guard let session = sessionsByID[value.id], session.endTime == nil else { continue }
            let end = max(latestRestoredPoint[value.id] ?? value.startTime, value.startTime)
            session.endTime = end
            session.duration = max(0, end.timeIntervalSince(session.startTime))
            session.isActive = false
        }

        for value in backup.stays where !existingStayIDs.contains(value.id) {
            guard let session = value.sessionID.flatMap({ sessionsByID[$0] }) else { continue }
            let stay = StayRecord(customPlaceID: value.customPlaceID,
                                  detectedName: value.detectedName,
                                  latitude: value.latitude,
                                  longitude: value.longitude,
                                  arrivalTime: value.arrivalTime,
                                  radius: value.radius,
                                  pointCount: value.pointCount,
                                  confidence: value.confidence,
                                  source: StayRecordSource(rawValue: value.sourceRawValue) ?? .automaticDetection,
                                  session: session)
            stay.id = value.id
            stay.departureTime = value.departureTime
            stay.duration = value.duration
            context.insert(stay)
            insertedStays += 1
        }

        for value in backup.dailySummaries where !existingDailyIDs.contains(value.id) {
            let summary = DailySummary(date: value.date)
            summary.id = value.id
            summary.totalDistance = value.totalDistance
            summary.walkingDistance = value.walkingDistance
            summary.runningDistance = value.runningDistance
            summary.cyclingDistance = value.cyclingDistance
            summary.automotiveDistance = value.automotiveDistance
            summary.activeDuration = value.activeDuration
            summary.stayCount = value.stayCount
            context.insert(summary)
            insertedOtherRecords += 1
        }

        for value in backup.photoRecords where !existingPhotoIDs.contains(value.assetIdentifier) {
            let record = PhotoAnalysisRecord(assetIdentifier: value.assetIdentifier,
                                             creationDate: value.creationDate,
                                             latitude: value.latitude,
                                             longitude: value.longitude,
                                             originalLatitude: value.originalLatitude,
                                             originalLongitude: value.originalLongitude,
                                             categories: value.categoryRawValues.split(separator: ",")
                                                .compactMap { PhotoSmartCategory(rawValue: String($0)) },
                                             topLabels: value.topLabelsRawValue.split(separator: "\n").map(String.init),
                                             confidence: value.confidence,
                                             faceCount: value.faceCount,
                                             state: PhotoAnalysisState(rawValue: value.analysisStateRawValue) ?? .failed,
                                             linkedSessionID: value.linkedSessionID)
            record.primaryCategoryRawValue = value.primaryCategoryRawValue
            record.categoryRawValues = value.categoryRawValues
            record.topLabelsRawValue = value.topLabelsRawValue
            record.analyzedAt = value.analyzedAt
            context.insert(record)
            insertedOtherRecords += 1
        }

        var timelineTripsByID = Dictionary(uniqueKeysWithValues:
            try context.fetch(FetchDescriptor<TravelTimelineTrip>()).map { ($0.id, $0) })
        var existingTimelineKeys = Set(timelineTripsByID.values.map(\.stableKey))
        for value in backup.timelineTrips
            where timelineTripsByID[value.id] == nil && !existingTimelineKeys.contains(value.stableKey) {
            let trip = TravelTimelineTrip(stableKey: value.stableKey,
                                          title: value.title,
                                          startTime: value.startTime,
                                          endTime: value.endTime,
                                          totalDistance: value.totalDistance,
                                          sourceFingerprint: value.sourceFingerprint,
                                          routePoints: [])
            trip.id = value.id
            trip.generatedAt = value.generatedAt
            trip.routeData = value.routeData
            context.insert(trip)
            timelineTripsByID[value.id] = trip
            existingTimelineKeys.insert(value.stableKey)
            insertedOtherRecords += 1
        }

        let existingNodeIDs = Set(try context.fetch(FetchDescriptor<TravelTimelineNode>()).map(\.id))
        for value in backup.timelineNodes where !existingNodeIDs.contains(value.id) {
            guard let trip = value.tripID.flatMap({ timelineTripsByID[$0] }) else { continue }
            let node = TravelTimelineNode(stableKey: value.stableKey,
                                          kind: TravelTimelineNodeKind(rawValue: value.kindRawValue) ?? .stay,
                                          startTime: value.startTime,
                                          endTime: value.endTime,
                                          coordinate: CLLocationCoordinate2D(latitude: value.latitude,
                                                                             longitude: value.longitude),
                                          endCoordinate: value.endCoordinate,
                                          distance: value.distance,
                                          activityType: ActivityType(rawValue: value.activityTypeRawValue) ?? .unknown,
                                          photoIdentifiers: value.photoIdentifiersRawValue.isEmpty
                                            ? [] : value.photoIdentifiersRawValue.split(separator: "\n").map(String.init),
                                          categories: value.categoryRawValues.split(separator: ",")
                                            .compactMap { PhotoSmartCategory(rawValue: String($0)) },
                                          trip: trip)
            node.id = value.id
            node.placeName = value.placeName
            node.endPlaceName = value.endPlaceName
            context.insert(node)
            insertedOtherRecords += 1
        }

        var existingJourneyIDs = Set(try context.fetch(FetchDescriptor<JourneyRecord>()).map(\.id))
        var existingJourneyKeys = Set(try context.fetch(FetchDescriptor<JourneyRecord>()).map(\.stableKey))
        for value in backup.journeys ?? []
            where !existingJourneyIDs.contains(value.id) && !existingJourneyKeys.contains(value.stableKey) {
            let journey = JourneyRecord(stableKey: value.stableKey,
                                        startTime: value.startTime,
                                        endTime: value.endTime,
                                        startPlace: value.startPlace,
                                        endPlace: value.endPlace,
                                        totalDistance: value.totalDistance,
                                        primaryActivity: ActivityType(rawValue: value.primaryActivityRawValue) ?? .unknown,
                                        sessionIDs: value.sessionIDs,
                                        stayRecordIDs: value.stayRecordIDs,
                                        generationVersion: value.generationVersion)
            journey.id = value.id
            journey.generatedAt = value.generatedAt
            context.insert(journey)
            existingJourneyIDs.insert(value.id)
            existingJourneyKeys.insert(value.stableKey)
            insertedOtherRecords += 1
        }

        var existingArchiveIDs = Set(try context.fetch(FetchDescriptor<TravelArchiveRecord>()).map(\.id))
        var existingArchiveKeys = Set(try context.fetch(FetchDescriptor<TravelArchiveRecord>()).map(\.sourceFingerprint))
        for value in backup.travelArchives ?? []
            where !existingArchiveIDs.contains(value.id) && !existingArchiveKeys.contains(value.sourceFingerprint) {
            let record = TravelArchiveRecord(sourceFingerprint: value.sourceFingerprint,
                                             title: value.title,
                                             startTime: value.startTime,
                                             endTime: value.endTime,
                                             photoCount: value.photoCount,
                                             placeCount: value.placeCount,
                                             totalDistance: value.totalDistance,
                                             mainPlaces: value.mainPlaces)
            record.id = value.id
            record.createdAt = value.createdAt
            record.updatedAt = value.updatedAt
            context.insert(record)
            existingArchiveIDs.insert(value.id)
            existingArchiveKeys.insert(value.sourceFingerprint)
            insertedOtherRecords += 1
        }

        guard PersistenceService.save(context,
                                      operation: "恢复 LifeTrack 备份",
                                      failureRecovery: .rollback) else {
            throw BackupServiceError.persistence
        }
        JourneyGenerationService.refresh(in: context)
        LocationService.shared.refreshPlaceCache()
        return BackupRestoreResult(insertedSessions: insertedSessions,
                                   insertedTrackPoints: insertedTrackPoints,
                                   insertedPlaces: insertedPlaces,
                                   insertedStays: insertedStays,
                                   insertedOtherRecords: insertedOtherRecords)
    }

    private static func validate(_ backup: LifeTrackBackup) throws {
        guard backup.sessions.count <= maximumSessionCount else {
            throw BackupServiceError.invalidFile("运动记录数量超过安全上限")
        }
        guard backup.trackPoints.count <= maximumTrackPointCount else {
            throw BackupServiceError.invalidFile("轨迹点数量超过安全上限")
        }
        guard backup.places.count <= maximumPlaceCount else {
            throw BackupServiceError.invalidFile("地点数量超过安全上限")
        }
        guard backup.stays.count <= maximumStayCount else {
            throw BackupServiceError.invalidFile("停留记录数量超过安全上限")
        }
        let otherCount = backup.dailySummaries.count + backup.photoRecords.count +
            backup.timelineTrips.count + backup.timelineNodes.count +
            (backup.geofences?.count ?? 0) +
            (backup.journeys?.count ?? 0) + (backup.travelArchives?.count ?? 0)
        guard otherCount <= maximumOtherRecordCount else {
            throw BackupServiceError.invalidFile("其他记录数量超过安全上限")
        }

        try requireUnique(backup.sessions.map(\.id), name: "ActivitySession UUID")
        try requireUnique(backup.trackPoints.map(\.id), name: "TrackPoint UUID")
        try requireUnique(backup.places.map(\.id), name: "CustomPlace UUID")
        try requireUnique((backup.geofences ?? []).map(\.placeID), name: "地点边界 Place UUID")
        try requireUnique(backup.stays.map(\.id), name: "StayRecord UUID")
        try requireUnique(backup.dailySummaries.map(\.id), name: "DailySummary UUID")
        try requireUnique(backup.photoRecords.map(\.assetIdentifier), name: "照片标识")
        try requireUnique(backup.timelineTrips.map(\.id), name: "TravelTimelineTrip UUID")
        try requireUnique(backup.timelineNodes.map(\.id), name: "TravelTimelineNode UUID")
        try requireUnique((backup.journeys ?? []).map(\.id), name: "JourneyRecord UUID")
        try requireUnique((backup.travelArchives ?? []).map(\.id), name: "TravelArchive UUID")

        let sessionIDs = Set(backup.sessions.map(\.id))
        let placeIDs = Set(backup.places.map(\.id))
        let stayIDs = Set(backup.stays.map(\.id))
        let tripIDs = Set(backup.timelineTrips.map(\.id))

        for geofence in backup.geofences ?? [] {
            guard placeIDs.contains(geofence.placeID) else {
                throw BackupServiceError.invalidFile("地点边界关联了不存在的地点")
            }
            guard geofence.vertices.isEmpty || (3...1_000).contains(geofence.vertices.count) else {
                throw BackupServiceError.invalidFile("手绘地点边界点数无效")
            }
            for pair in geofence.vertices {
                guard pair.count == 2 else {
                    throw BackupServiceError.invalidFile("手绘地点边界坐标格式无效")
                }
                try requireCoordinate(latitude: pair[0], longitude: pair[1], field: "手绘地点边界")
            }
        }

        for value in backup.sessions {
            try requireValidDate(value.startTime, field: "运动开始时间")
            if let end = value.endTime {
                try requireValidDate(end, field: "运动结束时间")
                guard end >= value.startTime else {
                    throw BackupServiceError.invalidFile("运动结束时间早于开始时间")
                }
            }
            try requireNonnegative(value.distance, field: "运动距离")
            try requireNonnegative(value.duration, field: "运动时长")
            try requireOptionalCoordinate(latitude: value.destinationLatitude,
                                          longitude: value.destinationLongitude,
                                          field: "目的地坐标")
        }

        for value in backup.trackPoints {
            try requireCoordinate(latitude: value.latitude, longitude: value.longitude, field: "轨迹点坐标")
            guard value.altitude.isFinite, value.speed.isFinite, value.course.isFinite,
                  value.horizontalAccuracy.isFinite, value.horizontalAccuracy >= 0 else {
                throw BackupServiceError.invalidFile("轨迹点包含 NaN、Infinity 或非法精度")
            }
            try requireValidDate(value.timestamp, field: "轨迹点时间")
            guard let sessionID = value.sessionID, sessionIDs.contains(sessionID) else {
                throw BackupServiceError.invalidFile("轨迹点关联了不存在的运动记录")
            }
        }

        for value in backup.places {
            try requireCoordinate(latitude: value.latitude, longitude: value.longitude, field: "地点坐标")
            guard value.radius.isFinite, value.radius > 0 else {
                throw BackupServiceError.invalidFile("地点半径无效")
            }
            try requireValidDate(value.createdAt, field: "地点创建时间")
            try requireValidDate(value.updatedAt, field: "地点更新时间")
        }

        for value in backup.stays {
            try requireCoordinate(latitude: value.latitude, longitude: value.longitude, field: "停留坐标")
            try requireValidDate(value.arrivalTime, field: "到达时间")
            if let departure = value.departureTime {
                try requireValidDate(departure, field: "离开时间")
                guard departure >= value.arrivalTime else {
                    throw BackupServiceError.invalidFile("停留离开时间早于到达时间")
                }
            }
            try requireNonnegative(value.duration, field: "停留时长")
            try requireNonnegative(value.radius, field: "停留半径")
            guard value.pointCount >= 0, value.confidence.isFinite,
                  (0...1).contains(value.confidence) else {
                throw BackupServiceError.invalidFile("停留统计数值无效")
            }
            guard let sessionID = value.sessionID, sessionIDs.contains(sessionID) else {
                throw BackupServiceError.invalidFile("停留记录关联了不存在的运动记录")
            }
        }

        for value in backup.dailySummaries {
            try requireValidDate(value.date, field: "每日汇总日期")
            for (number, field) in [(value.totalDistance, "每日总距离"),
                                    (value.walkingDistance, "步行距离"),
                                    (value.runningDistance, "跑步距离"),
                                    (value.cyclingDistance, "骑行距离"),
                                    (value.automotiveDistance, "驾车距离"),
                                    (value.activeDuration, "活动时长")] {
                try requireNonnegative(number, field: field)
            }
            guard value.stayCount >= 0 else {
                throw BackupServiceError.invalidFile("每日停留次数无效")
            }
        }

        for value in backup.photoRecords {
            try requireValidDate(value.creationDate, field: "照片创建时间")
            try requireValidDate(value.analyzedAt, field: "照片分析时间")
            try requireOptionalCoordinate(latitude: value.latitude, longitude: value.longitude, field: "照片坐标")
            try requireOptionalCoordinate(latitude: value.originalLatitude,
                                          longitude: value.originalLongitude,
                                          field: "照片原始坐标")
            guard value.confidence.isFinite, (0...1).contains(value.confidence), value.faceCount >= 0 else {
                throw BackupServiceError.invalidFile("照片分析数值无效")
            }
            if let linkedSessionID = value.linkedSessionID, !sessionIDs.contains(linkedSessionID) {
                throw BackupServiceError.invalidFile("照片关联了不存在的运动记录")
            }
        }

        for value in backup.timelineTrips {
            try requireTimeRange(start: value.startTime, end: value.endTime, field: "旅行时间轴")
            try requireNonnegative(value.totalDistance, field: "旅行时间轴距离")
            let route: [TravelTimelineRoutePoint]
            do {
                route = try JSONDecoder().decode([TravelTimelineRoutePoint].self, from: value.routeData)
            } catch {
                throw BackupServiceError.invalidFile("时间轴路线数据无法解析")
            }
            for point in route {
                try requireCoordinate(latitude: point.latitude, longitude: point.longitude, field: "时间轴路线坐标")
                try requireValidDate(point.timestamp, field: "时间轴路线时间")
            }
        }

        for value in backup.timelineNodes {
            try requireTimeRange(start: value.startTime, end: value.endTime, field: "时间轴节点")
            try requireCoordinate(latitude: value.latitude, longitude: value.longitude, field: "时间轴节点坐标")
            try requireOptionalCoordinate(latitude: value.endLatitude,
                                          longitude: value.endLongitude,
                                          field: "时间轴节点结束坐标")
            try requireNonnegative(value.distance, field: "时间轴节点距离")
            guard let tripID = value.tripID, tripIDs.contains(tripID) else {
                throw BackupServiceError.invalidFile("时间轴节点关联了不存在的旅行")
            }
        }

        for value in backup.journeys ?? [] {
            try requireTimeRange(start: value.startTime, end: value.endTime, field: "Journey")
            try requireNonnegative(value.totalDistance, field: "Journey 距离")
            guard !value.sessionIDs.isEmpty,
                  value.sessionIDs.allSatisfy(sessionIDs.contains),
                  value.stayRecordIDs.allSatisfy(stayIDs.contains) else {
                throw BackupServiceError.invalidFile("Journey 关联 ID 不完整")
            }
        }

        for value in backup.travelArchives ?? [] {
            try requireTimeRange(start: value.startTime, end: value.endTime, field: "旅行归档")
            try requireNonnegative(value.totalDistance, field: "旅行归档距离")
            guard value.photoCount >= 0, value.placeCount >= 0 else {
                throw BackupServiceError.invalidFile("旅行归档计数无效")
            }
            try requireValidDate(value.createdAt, field: "归档创建时间")
            try requireValidDate(value.updatedAt, field: "归档更新时间")
        }
    }

    private static func requireUnique<T: Hashable>(_ values: [T], name: String) throws {
        guard Set(values).count == values.count else {
            throw BackupServiceError.invalidFile("\(name) 存在重复")
        }
    }

    private static func requireCoordinate(latitude: Double, longitude: Double, field: String) throws {
        guard latitude.isFinite, longitude.isFinite,
              CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) else {
            throw BackupServiceError.invalidFile("\(field)无效")
        }
    }

    private static func requireOptionalCoordinate(latitude: Double?,
                                                  longitude: Double?,
                                                  field: String) throws {
        switch (latitude, longitude) {
        case (nil, nil):
            return
        case let (latitude?, longitude?):
            try requireCoordinate(latitude: latitude, longitude: longitude, field: field)
        default:
            throw BackupServiceError.invalidFile("\(field)不完整")
        }
    }

    private static func requireNonnegative(_ value: Double, field: String) throws {
        guard value.isFinite, value >= 0 else {
            throw BackupServiceError.invalidFile("\(field)包含负数、NaN 或 Infinity")
        }
    }

    private static func requireValidDate(_ value: Date, field: String) throws {
        guard value.timeIntervalSinceReferenceDate.isFinite else {
            throw BackupServiceError.invalidFile("\(field)无效")
        }
    }

    private static func requireTimeRange(start: Date, end: Date, field: String) throws {
        try requireValidDate(start, field: "\(field)开始时间")
        try requireValidDate(end, field: "\(field)结束时间")
        guard end >= start else {
            throw BackupServiceError.invalidFile("\(field)结束时间早于开始时间")
        }
    }

    private static func fileDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

private struct LifeTrackBackup: Codable {
    static let currentVersion = 1

    let backupVersion: Int
    let createdAt: Date
    let appVersion: String
    let sessions: [SessionBackup]
    let trackPoints: [TrackPointBackup]
    let places: [CustomPlaceBackup]
    let geofences: [PlaceGeofenceBackup]?
    let stays: [StayRecordBackup]
    let dailySummaries: [DailySummaryBackup]
    let photoRecords: [PhotoAnalysisBackup]
    let timelineTrips: [TimelineTripBackup]
    let timelineNodes: [TimelineNodeBackup]
    let journeys: [JourneyBackup]?
    let travelArchives: [TravelArchiveBackup]?
}

private struct PlaceGeofenceBackup: Codable {
    let placeID: UUID
    let areaTypeRawValue: String
    let vertices: [[Double]]

    init(_ value: PlaceGeofence) {
        placeID = value.placeID
        areaTypeRawValue = value.areaTypeRawValue
        vertices = value.vertices.map { [$0.latitude, $0.longitude] }
    }
}

private struct SessionBackup: Codable {
    let id: UUID
    let activityTypeRawValue: String
    let sourceRawValue: String
    let startTime: Date
    let endTime: Date?
    let distance: Double
    let duration: TimeInterval
    let isActive: Bool
    let destinationName: String?
    let destinationLatitude: Double?
    let destinationLongitude: Double?
    let manualActivityTypeRawValue: String?
    let importFingerprint: String?

    init(_ value: ActivitySession) {
        id = value.id
        activityTypeRawValue = value.activityTypeRawValue
        sourceRawValue = value.sourceRawValue
        startTime = value.startTime
        endTime = value.endTime
        distance = value.distance
        duration = value.duration
        isActive = value.isActive
        destinationName = value.destinationName
        destinationLatitude = value.destinationLatitude
        destinationLongitude = value.destinationLongitude
        manualActivityTypeRawValue = value.manualActivityTypeRawValue
        importFingerprint = value.importFingerprint
    }
}

private struct TrackPointBackup: Codable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let speed: Double
    let course: Double
    let horizontalAccuracy: Double
    let timestamp: Date
    let activityTypeRawValue: String
    let isAnomaly: Bool
    let anomalyReasonRawValue: String?
    let sessionID: UUID?

    init(_ value: TrackPoint) {
        id = value.id
        latitude = value.latitude
        longitude = value.longitude
        altitude = value.altitude
        speed = value.speed
        course = value.course
        horizontalAccuracy = value.horizontalAccuracy
        timestamp = value.timestamp
        activityTypeRawValue = value.activityTypeRawValue
        isAnomaly = value.isAnomaly
        anomalyReasonRawValue = value.anomalyReasonRawValue
        sessionID = value.session?.id
    }
}

private struct CustomPlaceBackup: Codable {
    let id: UUID
    let shortName: String
    let officialName: String?
    let note: String?
    let latitude: Double
    let longitude: Double
    let radius: Double
    let categoryRawValue: String
    let symbolName: String
    let isFavorite: Bool
    let isAlwaysVisible: Bool
    let isCampusPlace: Bool
    let priority: Int
    let createdAt: Date
    let updatedAt: Date

    init(_ value: CustomPlace) {
        id = value.id
        shortName = value.shortName
        officialName = value.officialName
        note = value.note
        latitude = value.latitude
        longitude = value.longitude
        radius = value.radius
        categoryRawValue = value.categoryRawValue
        symbolName = value.symbolName
        isFavorite = value.isFavorite
        isAlwaysVisible = value.isAlwaysVisible
        isCampusPlace = value.isCampusPlace
        priority = value.priority
        createdAt = value.createdAt
        updatedAt = value.updatedAt
    }
}

private struct StayRecordBackup: Codable {
    let id: UUID
    let customPlaceID: UUID?
    let detectedName: String?
    let latitude: Double
    let longitude: Double
    let arrivalTime: Date
    let departureTime: Date?
    let duration: TimeInterval
    let radius: Double
    let pointCount: Int
    let confidence: Double
    let sourceRawValue: String
    let sessionID: UUID?

    init(_ value: StayRecord) {
        id = value.id
        customPlaceID = value.customPlaceID
        detectedName = value.detectedName
        latitude = value.latitude
        longitude = value.longitude
        arrivalTime = value.arrivalTime
        departureTime = value.departureTime
        duration = value.duration
        radius = value.radius
        pointCount = value.pointCount
        confidence = value.confidence
        sourceRawValue = value.sourceRawValue
        sessionID = value.session?.id
    }
}

private struct DailySummaryBackup: Codable {
    let id: UUID
    let date: Date
    let totalDistance: Double
    let walkingDistance: Double
    let runningDistance: Double
    let cyclingDistance: Double
    let automotiveDistance: Double
    let activeDuration: TimeInterval
    let stayCount: Int

    init(_ value: DailySummary) {
        id = value.id
        date = value.date
        totalDistance = value.totalDistance
        walkingDistance = value.walkingDistance
        runningDistance = value.runningDistance
        cyclingDistance = value.cyclingDistance
        automotiveDistance = value.automotiveDistance
        activeDuration = value.activeDuration
        stayCount = value.stayCount
    }
}

private struct PhotoAnalysisBackup: Codable {
    let assetIdentifier: String
    let creationDate: Date
    let latitude: Double?
    let longitude: Double?
    let originalLatitude: Double?
    let originalLongitude: Double?
    let primaryCategoryRawValue: String
    let categoryRawValues: String
    let topLabelsRawValue: String
    let confidence: Double
    let faceCount: Int
    let analysisStateRawValue: String
    let analyzedAt: Date
    let linkedSessionID: UUID?

    init(_ value: PhotoAnalysisRecord) {
        assetIdentifier = value.assetIdentifier
        creationDate = value.creationDate
        latitude = value.latitude
        longitude = value.longitude
        originalLatitude = value.originalLatitude
        originalLongitude = value.originalLongitude
        primaryCategoryRawValue = value.primaryCategoryRawValue
        categoryRawValues = value.categoryRawValues
        topLabelsRawValue = value.topLabelsRawValue
        confidence = value.confidence
        faceCount = value.faceCount
        analysisStateRawValue = value.analysisStateRawValue
        analyzedAt = value.analyzedAt
        linkedSessionID = value.linkedSessionID
    }
}

private struct TimelineTripBackup: Codable {
    let id: UUID
    let stableKey: String
    let title: String
    let startTime: Date
    let endTime: Date
    let totalDistance: Double
    let sourceFingerprint: String
    let generatedAt: Date
    let routeData: Data

    init(_ value: TravelTimelineTrip) {
        id = value.id
        stableKey = value.stableKey
        title = value.title
        startTime = value.startTime
        endTime = value.endTime
        totalDistance = value.totalDistance
        sourceFingerprint = value.sourceFingerprint
        generatedAt = value.generatedAt
        routeData = value.routeData
    }
}

private struct TimelineNodeBackup: Codable {
    let id: UUID
    let stableKey: String
    let kindRawValue: String
    let startTime: Date
    let endTime: Date
    let latitude: Double
    let longitude: Double
    let endLatitude: Double?
    let endLongitude: Double?
    let placeName: String?
    let endPlaceName: String?
    let distance: Double
    let activityTypeRawValue: String
    let photoIdentifiersRawValue: String
    let categoryRawValues: String
    let tripID: UUID?

    var endCoordinate: CLLocationCoordinate2D? {
        guard let endLatitude, let endLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: endLatitude, longitude: endLongitude)
    }

    init(_ value: TravelTimelineNode) {
        id = value.id
        stableKey = value.stableKey
        kindRawValue = value.kindRawValue
        startTime = value.startTime
        endTime = value.endTime
        latitude = value.latitude
        longitude = value.longitude
        endLatitude = value.endLatitude
        endLongitude = value.endLongitude
        placeName = value.placeName
        endPlaceName = value.endPlaceName
        distance = value.distance
        activityTypeRawValue = value.activityTypeRawValue
        photoIdentifiersRawValue = value.photoIdentifiersRawValue
        categoryRawValues = value.categoryRawValues
        tripID = value.trip?.id
    }
}

private struct JourneyBackup: Codable {
    let id: UUID
    let stableKey: String
    let startTime: Date
    let endTime: Date
    let startPlace: String?
    let endPlace: String?
    let totalDistance: Double
    let primaryActivityRawValue: String
    let sessionIDs: [UUID]
    let stayRecordIDs: [UUID]
    let generatedAt: Date
    let generationVersion: Int

    init(_ value: JourneyRecord) {
        id = value.id
        stableKey = value.stableKey
        startTime = value.startTime
        endTime = value.endTime
        startPlace = value.startPlace
        endPlace = value.endPlace
        totalDistance = value.totalDistance
        primaryActivityRawValue = value.primaryActivityRawValue
        sessionIDs = value.sessionIDs
        stayRecordIDs = value.stayRecordIDs
        generatedAt = value.generatedAt
        generationVersion = value.generationVersion
    }
}

private struct TravelArchiveBackup: Codable {
    let id: UUID
    let sourceFingerprint: String
    let title: String
    let startTime: Date
    let endTime: Date
    let photoCount: Int
    let placeCount: Int
    let totalDistance: Double
    let mainPlaces: [String]
    let createdAt: Date
    let updatedAt: Date

    init(_ value: TravelArchiveRecord) {
        id = value.id
        sourceFingerprint = value.sourceFingerprint
        title = value.title
        startTime = value.startTime
        endTime = value.endTime
        photoCount = value.photoCount
        placeCount = value.placeCount
        totalDistance = value.totalDistance
        mainPlaces = value.mainPlaces
        createdAt = value.createdAt
        updatedAt = value.updatedAt
    }
}
