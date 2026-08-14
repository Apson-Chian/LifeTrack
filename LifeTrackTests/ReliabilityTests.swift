import Foundation
import CoreLocation
import SwiftData
import XCTest
@testable import LifeTrack

@MainActor
final class ReliabilityTests: XCTestCase {
    func testPersistenceFailurePoliciesPreserveOrRollbackChanges() throws {
        try withReadOnlyContainer { container in
            let context = container.mainContext
            context.insert(CustomPlace(shortName: "待重试",
                                       latitude: 31.2,
                                       longitude: 121.4))
            XCTAssertFalse(PersistenceService.save(context,
                                                   operation: "普通保存",
                                                   failureRecovery: .preserveChanges))
            XCTAssertTrue(context.hasChanges)
        }

        try withReadOnlyContainer { container in
            let context = container.mainContext
            context.insert(CustomPlace(shortName: "应回滚",
                                       latitude: 31.2,
                                       longitude: 121.4))
            XCTAssertFalse(PersistenceService.save(context,
                                                   operation: "关键保存",
                                                   failureRecovery: .rollback))
            XCTAssertFalse(context.hasChanges)
        }
    }

    func testGPXImportsMissingOptionalFieldsAndSkipsBadPoints() throws {
        let container = try makeContainer()
        let url = try writeTemporaryFile(
            named: "mixed.gpx",
            contents: """
            <?xml version="1.0" encoding="UTF-8"?>
            <gpx version="1.1"><trk><trkseg>
              <trkpt lat="31.2000" lon="121.4000" />
              <trkpt lat="NaN" lon="121.4100"><time>2024-01-01T00:01:00Z</time></trkpt>
              <trkpt lat="31.2010" lon="121.4010"><ele>12.5</ele><time>2024-01-01T00:02:00Z</time></trkpt>
              <trkpt lat="95" lon="121.4"><time>2024-01-01T00:03:00Z</time></trkpt>
            </trkseg></trk></gpx>
            """
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let session = try GPXService.importFile(at: url, into: container.mainContext)
        XCTAssertEqual(session.trackPoints.count, 2)
        XCTAssertEqual(session.trackPoints.map(\.altitude).sorted(), [0, 12.5])
        XCTAssertFalse(session.isActive)
    }

    func testGPXRejectsDuplicateAndOversizedFiles() throws {
        let container = try makeContainer()
        let normalURL = try writeTemporaryFile(
            named: "duplicate.gpx",
            contents: gpx(pointCount: 2)
        )
        defer { try? FileManager.default.removeItem(at: normalURL) }
        _ = try GPXService.importFile(at: normalURL, into: container.mainContext)
        XCTAssertThrowsError(try GPXService.importFile(at: normalURL, into: container.mainContext)) { error in
            guard case GPXServiceError.duplicate = error else {
                return XCTFail("Expected duplicate, got \(error)")
            }
        }

        let largeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("oversized-\(UUID().uuidString).gpx")
        defer { try? FileManager.default.removeItem(at: largeURL) }
        try Data(repeating: 0, count: 50 * 1024 * 1024 + 1).write(to: largeURL)
        XCTAssertThrowsError(try GPXService.importFile(at: largeURL, into: container.mainContext)) { error in
            guard case GPXServiceError.fileTooLarge = error else {
                return XCTFail("Expected fileTooLarge, got \(error)")
            }
        }
    }

    func testGPXStopsWhenPointLimitIsExceeded() throws {
        let container = try makeContainer()
        let url = try writeTemporaryFile(named: "too-many.gpx", contents: gpx(pointCount: 300_001))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try GPXService.importFile(at: url, into: container.mainContext)) { error in
            guard case GPXServiceError.tooManyPoints = error else {
                return XCTFail("Expected tooManyPoints, got \(error)")
            }
        }
    }

    func testBackupRestoreIsValidatedDeduplicatedAndAtomic() throws {
        let source = try makeContainer()
        try insertSampleSession(into: source.mainContext)
        source.mainContext.insert(CustomPlace(shortName: "家", latitude: 31.2, longitude: 121.4))
        try source.mainContext.save()
        let backupURL = try BackupService.createBackup(from: source.mainContext)
        defer { try? FileManager.default.removeItem(at: backupURL) }

        let destination = try makeContainer()
        let first = try BackupService.restoreBackup(at: backupURL, into: destination.mainContext)
        XCTAssertEqual(first.insertedSessions, 1)
        XCTAssertEqual(first.insertedTrackPoints, 3)
        XCTAssertEqual(first.insertedPlaces, 1)
        let second = try BackupService.restoreBackup(at: backupURL, into: destination.mainContext)
        XCTAssertEqual(second.totalInserted, 0)

        try withReadOnlyContainer { readOnlyDestination in
            XCTAssertThrowsError(try BackupService.restoreBackup(at: backupURL,
                                                                 into: readOnlyDestination.mainContext)) { error in
                guard case BackupServiceError.persistence = error else {
                    return XCTFail("Expected persistence error, got \(error)")
                }
            }
            XCTAssertEqual(try readOnlyDestination.mainContext.fetchCount(FetchDescriptor<ActivitySession>()), 0)
        }
    }

    func testBackupRejectsCorruptionWrongVersionBadCoordinatesAndLargeFile() throws {
        let source = try makeContainer()
        try insertSampleSession(into: source.mainContext)
        try source.mainContext.save()
        let validURL = try BackupService.createBackup(from: source.mainContext)
        defer { try? FileManager.default.removeItem(at: validURL) }
        let destination = try makeContainer()

        let corruptURL = try writeTemporaryFile(named: "corrupt.json", contents: "{not-json")
        defer { try? FileManager.default.removeItem(at: corruptURL) }
        XCTAssertThrowsError(try BackupService.restoreBackup(at: corruptURL, into: destination.mainContext))

        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: validURL)) as? [String: Any])
        root["backupVersion"] = 999
        let wrongVersionURL = try writeJSON(root, name: "wrong-version.json")
        defer { try? FileManager.default.removeItem(at: wrongVersionURL) }
        XCTAssertThrowsError(try BackupService.restoreBackup(at: wrongVersionURL,
                                                             into: destination.mainContext)) { error in
            guard case BackupServiceError.unsupportedVersion = error else {
                return XCTFail("Expected unsupportedVersion, got \(error)")
            }
        }

        root["backupVersion"] = 1
        var points = try XCTUnwrap(root["trackPoints"] as? [[String: Any]])
        points[0]["latitude"] = 999
        root["trackPoints"] = points
        let badCoordinateURL = try writeJSON(root, name: "bad-coordinate.json")
        defer { try? FileManager.default.removeItem(at: badCoordinateURL) }
        XCTAssertThrowsError(try BackupService.restoreBackup(at: badCoordinateURL,
                                                             into: destination.mainContext)) { error in
            guard case BackupServiceError.invalidFile = error else {
                return XCTFail("Expected invalidFile, got \(error)")
            }
        }

        let largeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("oversized-backup-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: largeURL) }
        try Data(repeating: 0, count: 200 * 1024 * 1024 + 1).write(to: largeURL)
        XCTAssertThrowsError(try BackupService.restoreBackup(at: largeURL,
                                                             into: destination.mainContext)) { error in
            guard case BackupServiceError.fileTooLarge = error else {
                return XCTFail("Expected fileTooLarge, got \(error)")
            }
        }
    }

    func testUnversionedStoreOpensWithMigrationPlan() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-\(UUID().uuidString).store")
        defer { removeStoreFiles(at: url) }
        let legacySchema = Schema(LifeTrackSchemaV1.models)
        var legacyContainer: ModelContainer? = try ModelContainer(
            for: legacySchema,
            configurations: [ModelConfiguration("Legacy", schema: legacySchema, url: url,
                                                cloudKitDatabase: .none)]
        )
        legacyContainer?.mainContext.insert(CustomPlace(shortName: "旧数据",
                                                        latitude: 31.2,
                                                        longitude: 121.4))
        try legacyContainer?.mainContext.save()
        legacyContainer = nil

        let versionedSchema = Schema(versionedSchema: LifeTrackSchemaV3.self)
        let migrated = try ModelContainer(
            for: versionedSchema,
            migrationPlan: LifeTrackMigrationPlan.self,
            configurations: [ModelConfiguration("Versioned", schema: versionedSchema, url: url,
                                                cloudKitDatabase: .none)]
        )
        XCTAssertEqual(try migrated.mainContext.fetchCount(FetchDescriptor<CustomPlace>()), 1)
    }

    func testCourseSchemaMigratesFromV2ToV3() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("course-migration-\(UUID().uuidString).store")
        defer { removeStoreFiles(at: url) }

        let oldSchema = Schema(versionedSchema: LifeTrackSchemaV2.self)
        var oldContainer: ModelContainer? = try ModelContainer(
            for: oldSchema,
            configurations: [ModelConfiguration("CourseV2", schema: oldSchema, url: url,
                                                cloudKitDatabase: .none)]
        )
        oldContainer?.mainContext.insert(LifeTrackSchemaV2.CourseEvent(weekday: 1,
                                                                       startMinutes: 8 * 60,
                                                                       endMinutes: 9 * 60 + 35,
                                                                       name: "高等数学",
                                                                       locationName: "博学楼101"))
        try oldContainer?.mainContext.save()
        oldContainer = nil

        let currentSchema = Schema(versionedSchema: LifeTrackSchemaV3.self)
        let migrated = try ModelContainer(
            for: currentSchema,
            migrationPlan: LifeTrackMigrationPlan.self,
            configurations: [ModelConfiguration("CourseV3", schema: currentSchema, url: url,
                                                cloudKitDatabase: .none)]
        )
        let courses = try migrated.mainContext.fetch(FetchDescriptor<CourseEvent>())
        XCTAssertEqual(courses.count, 1)
        XCTAssertEqual(courses[0].name, "高等数学")
        XCTAssertEqual(courses[0].weekStart, 1)
        XCTAssertEqual(courses[0].weekEnd, 18)
        XCTAssertEqual(courses[0].weekRangesText, "")
    }

    func testGridTimetableParsesCourseWeeksAndSectionTimes() throws {
        let grid = [
            ["节次", "周一", "周二", "周三", "周四", "周五", "周六", "周日"],
            ["1-2", "高等数学\n张老师\n1-12([周])[1-2节]\n博学楼101", "", "", "", "", "", ""]
        ]

        let items = TimetableImportService.parseGrid(grid)
        let course = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(course.name, "高等数学")
        XCTAssertEqual(course.weekday, 1)
        XCTAssertEqual(course.startMinutes, 8 * 60)
        XCTAssertEqual(course.endMinutes, 9 * 60 + 35)
        XCTAssertEqual(course.location, "博学楼101")
        XCTAssertEqual(course.weekRangesText, "1-12")
    }

    func testRealisticStudentTimetableParsesStackedCellsAndRanges() throws {
        // 复刻真实“河海大学学生个人课表”.xls 网格：同一单元格堆叠多门课，
        // 且含逗号周次范围(1-3,5-11,13-18)与跨多小节(3-4-5节)写法。
        let grid = [
            ["", "周一", "周二", "周三", "周四", "周五", "周六", "周日"],
            ["第一大节",
             "\n编译原理\n邹阳\n2-11([周])[1-2节]\n地点A\n\n操作系统\n曹碧薇,张鹏程\n1-4([周])[3-4节]\n地点B\n",
             "\n算法设计与分析\n唐斌,屈志昊\n1-3,5-11,13-18([周])[8-9节]\n地点C\n",
             "",
             "\n物联网技术与应用\n李旭杰\n1-8([周])[3-4-5节]\n地点D\n",
             "", "", ""]
        ]

        let items = TimetableImportService.parseGrid(grid)
        XCTAssertEqual(items.count, 4)

        let algorithm = try XCTUnwrap(items.first { $0.name == "算法设计与分析" })
        XCTAssertEqual(algorithm.weekday, 2)
        XCTAssertEqual(algorithm.weekRangesText, "1-3,5-11,13-18")
        XCTAssertEqual(algorithm.startMinutes, 15 * 60 + 50) // 第 8 小节开始
        XCTAssertEqual(algorithm.endMinutes, 17 * 60 + 25)   // 第 9 小节结束

        let iot = try XCTUnwrap(items.first { $0.name == "物联网技术与应用" })
        XCTAssertEqual(iot.weekday, 4)
        XCTAssertEqual(iot.startMinutes, 9 * 60 + 50)  // 第 3 小节开始
        XCTAssertEqual(iot.endMinutes, 12 * 60 + 15)   // 第 5 小节结束
    }

    func testJourneyRequiresSpatialContinuity() throws {
        let container = try makeContainer()
        let firstStart = Date(timeIntervalSince1970: 1_700_000_000)
        insertSession(start: firstStart,
                      coordinates: [(31.0, 121.0), (31.003, 121.0)],
                      into: container.mainContext)
        insertSession(start: firstStart.addingTimeInterval(60 * 60),
                      coordinates: [(31.1, 121.0), (31.103, 121.0)],
                      into: container.mainContext)
        try container.mainContext.save()

        JourneyGenerationService.refresh(in: container.mainContext)
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<JourneyRecord>()), 2)
    }

    func testTrackTrimRecalculatesDerivedData() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let session = insertSession(start: start,
                                    coordinates: [
                                        (31.000, 121.0), (31.001, 121.0), (31.002, 121.0),
                                        (31.003, 121.0), (31.004, 121.0)
                                    ],
                                    into: context)
        try context.save()
        let firstID = try XCTUnwrap(session.trackPoints.min(by: { $0.timestamp < $1.timestamp })?.id)

        let result = try TrackEditingService.trim(session: session, removing: [firstID], in: context)
        XCTAssertEqual(result.removedPointCount, 1)
        XCTAssertEqual(session.trackPoints.count, 4)
        XCTAssertEqual(session.startTime, start.addingTimeInterval(60))
        XCTAssertEqual(session.duration, 180, accuracy: 0.001)
        XCTAssertGreaterThan(session.distance, 250)
    }

    func testPhotoDetailSnapshotPreservesAnalysisMetadata() {
        let creationDate = Date(timeIntervalSince1970: 1_700_000_000)
        let sessionID = UUID()
        let record = PhotoAnalysisRecord(assetIdentifier: "photo-detail-test",
                                         creationDate: creationDate,
                                         latitude: 31.21,
                                         longitude: 121.51,
                                         originalLatitude: 31.20,
                                         originalLongitude: 121.50,
                                         categories: [.landscape, .night],
                                         topLabels: ["sky|0.92", "city|0.80"],
                                         confidence: 0.92,
                                         faceCount: 2,
                                         state: .completed,
                                         linkedSessionID: sessionID)

        let item = PhotoDetailItem(record: record)

        XCTAssertEqual(item.assetIdentifier, "photo-detail-test")
        XCTAssertEqual(item.creationDate, creationDate)
        XCTAssertEqual(item.coordinate?.latitude, 31.20)
        XCTAssertEqual(item.coordinate?.longitude, 121.50)
        XCTAssertEqual(item.categories, [.landscape, .night])
        XCTAssertEqual(item.labels, ["sky", "city"])
        XCTAssertEqual(item.confidence, 0.92)
        XCTAssertEqual(item.faceCount, 2)
        XCTAssertEqual(item.linkedSessionID, sessionID)
    }

    func testPhotoCacheCleanupRemovesAnalysisAndTimelineReference() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(PhotoAnalysisRecord(assetIdentifier: "delete-me",
                                           creationDate: date,
                                           categories: [.food],
                                           topLabels: ["food|0.90"],
                                           confidence: 0.90,
                                           faceCount: 0,
                                           state: .completed))
        let trip = TravelTimelineTrip(stableKey: "photo-cleanup-trip",
                                      title: "Test",
                                      startTime: date,
                                      endTime: date.addingTimeInterval(60),
                                      totalDistance: 0,
                                      sourceFingerprint: "test",
                                      routePoints: [])
        context.insert(trip)
        context.insert(TravelTimelineNode(stableKey: "photo-cleanup-node",
                                          kind: .stay,
                                          startTime: date,
                                          endTime: date.addingTimeInterval(60),
                                          coordinate: .init(latitude: 31.2, longitude: 121.5),
                                          endCoordinate: nil,
                                          distance: 0,
                                          activityType: .unknown,
                                          photoIdentifiers: ["keep-me", "delete-me"],
                                          categories: [.food],
                                          trip: trip))
        try context.save()

        XCTAssertTrue(PhotoLibraryMutationService.cleanCache(assetIdentifier: "delete-me",
                                                              container: container))

        let verificationContext = ModelContext(container)
        let deletedID = "delete-me"
        let records = try verificationContext.fetch(FetchDescriptor<PhotoAnalysisRecord>(
            predicate: #Predicate { $0.assetIdentifier == deletedID }
        ))
        XCTAssertTrue(records.isEmpty)
        let nodes = try verificationContext.fetch(FetchDescriptor<TravelTimelineNode>())
        XCTAssertEqual(nodes.first?.photoIdentifiers, ["keep-me"])
    }

    func testAgentToolsCannotReadPhotoData() {
        let toolNames = Set(LifeAgentService.tools.map(\.name))
        XCTAssertFalse(toolNames.contains { $0.localizedCaseInsensitiveContains("photo") })
        XCTAssertEqual(toolNames, [
            "get_activity_summary",
            "get_stay_summary",
            "get_schedule",
            "get_study_stats",
            "get_travel_archives"
        ])
    }

    func testAgentSchemaMigratesFromV3ToV4() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-migration-\(UUID().uuidString).store")
        defer { removeStoreFiles(at: url) }

        let oldSchema = Schema(versionedSchema: LifeTrackSchemaV3.self)
        var oldContainer: ModelContainer? = try ModelContainer(
            for: oldSchema,
            configurations: [ModelConfiguration("AgentV3", schema: oldSchema, url: url,
                                                cloudKitDatabase: .none)]
        )
        oldContainer?.mainContext.insert(CustomPlace(shortName: "迁移保留地点",
                                                      latitude: 31.2,
                                                      longitude: 121.4))
        try oldContainer?.mainContext.save()
        oldContainer = nil

        let currentSchema = Schema(versionedSchema: LifeTrackSchemaV4.self)
        let migrated = try ModelContainer(
            for: currentSchema,
            migrationPlan: LifeTrackMigrationPlan.self,
            configurations: [ModelConfiguration("AgentV4", schema: currentSchema, url: url,
                                                cloudKitDatabase: .none)]
        )
        XCTAssertEqual(try migrated.mainContext.fetchCount(FetchDescriptor<CustomPlace>()), 1)
        migrated.mainContext.insert(LifeInsightRecord(kind: InsightKind.dailyReflection.rawValue,
                                                       title: "今日回顾",
                                                       content: "测试内容"))
        try migrated.mainContext.save()
        XCTAssertEqual(try migrated.mainContext.fetchCount(FetchDescriptor<LifeInsightRecord>()), 1)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(versionedSchema: LifeTrackSchemaV4.self)
        let configuration = ModelConfiguration(schema: schema,
                                               isStoredInMemoryOnly: true,
                                               cloudKitDatabase: .none)
        return try ModelContainer(for: schema,
                                  migrationPlan: LifeTrackMigrationPlan.self,
                                  configurations: [configuration])
    }

    private func withReadOnlyContainer<T>(_ body: (ModelContainer) throws -> T) throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("readonly-\(UUID().uuidString).store")
        let schema = Schema(versionedSchema: LifeTrackSchemaV4.self)
        var writable: ModelContainer? = try ModelContainer(
            for: schema,
            migrationPlan: LifeTrackMigrationPlan.self,
            configurations: [ModelConfiguration("Writable", schema: schema, url: url,
                                                cloudKitDatabase: .none)]
        )
        try writable?.mainContext.save()
        writable = nil
        var readOnly: ModelContainer? = try ModelContainer(
            for: schema,
            migrationPlan: LifeTrackMigrationPlan.self,
            configurations: [ModelConfiguration("ReadOnly", schema: schema, url: url,
                                                allowsSave: false, cloudKitDatabase: .none)]
        )
        do {
            let result = try body(try XCTUnwrap(readOnly))
            readOnly = nil
            removeStoreFiles(at: url)
            return result
        } catch {
            readOnly = nil
            removeStoreFiles(at: url)
            throw error
        }
    }

    @discardableResult
    private func insertSampleSession(into context: ModelContext) throws -> ActivitySession {
        insertSession(start: Date(timeIntervalSince1970: 1_700_000_000),
                      coordinates: [(31.2, 121.4), (31.201, 121.401), (31.202, 121.402)],
                      into: context)
    }

    @discardableResult
    private func insertSession(start: Date,
                               coordinates: [(Double, Double)],
                               into context: ModelContext) -> ActivitySession {
        let session = ActivitySession(activityType: .walking, source: "test", startTime: start)
        session.isActive = false
        session.endTime = start.addingTimeInterval(Double(max(0, coordinates.count - 1)) * 60)
        session.duration = session.endTime?.timeIntervalSince(start) ?? 0
        context.insert(session)
        for (index, coordinate) in coordinates.enumerated() {
            context.insert(TrackPoint(latitude: coordinate.0,
                                      longitude: coordinate.1,
                                      altitude: 0,
                                      speed: 1,
                                      course: 0,
                                      horizontalAccuracy: 5,
                                      timestamp: start.addingTimeInterval(Double(index) * 60),
                                      activityType: .walking,
                                      session: session))
        }
        let analysis = TrajectoryAnalysisService.analyze(session.trackPoints)
        session.distance = analysis.effectiveDistance
        return session
    }

    private func gpx(pointCount: Int) -> String {
        let point = "<trkpt lat=\"31.2\" lon=\"121.4\"><ele>1</ele></trkpt>"
        return "<?xml version=\"1.0\"?><gpx><trk><trkseg>" +
            String(repeating: point, count: pointCount) +
            "</trkseg></trk></gpx>"
    }

    private func writeTemporaryFile(named name: String, contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
        try Data(contents.utf8).write(to: url, options: .atomic)
        return url
    }

    private func writeJSON(_ object: [String: Any], name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)
        return url
    }

    private func removeStoreFiles(at url: URL) {
        for candidate in [url,
                          URL(fileURLWithPath: url.path + "-wal"),
                          URL(fileURLWithPath: url.path + "-shm")] {
            try? FileManager.default.removeItem(at: candidate)
        }
    }
}
