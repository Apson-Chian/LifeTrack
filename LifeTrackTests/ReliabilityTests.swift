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

    func testBackupRestoreIsValidatedDeduplicatedAndAtomic() async throws {
        let source = try makeContainer()
        try insertSampleSession(into: source.mainContext)
        source.mainContext.insert(CustomPlace(shortName: "家", latitude: 31.2, longitude: 121.4))
        try source.mainContext.save()
        let backupURL = try await BackupService.createBackup(from: source.mainContext)
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

    func testBackupRejectsCorruptionWrongVersionBadCoordinatesAndLargeFile() async throws {
        let source = try makeContainer()
        try insertSampleSession(into: source.mainContext)
        try source.mainContext.save()
        let validURL = try await BackupService.createBackup(from: source.mainContext)
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

    func testAgentToolsCoverWholeAppWithSanitizedPhotoAccess() {
        let toolNames = Set(LifeAgentService.tools.map(\.name))
        XCTAssertEqual(toolNames, [
            "get_activity_summary",
            "get_activity_range",
            "get_stay_summary",
            "get_place_overview",
            "get_journey_summary",
            "get_schedule",
            "get_study_stats",
            "get_travel_archives",
            "get_travel_candidates",
            "search_location_history",
            "get_sanitized_photo_summary"
        ])
        let photoTool = LifeAgentService.tools.first { $0.name == "get_sanitized_photo_summary" }
        let properties = photoTool?.parameters["properties"] as? [String: Any]
        XCTAssertNotNil(properties?["start_date"])
        XCTAssertNotNil(properties?["end_date"])
        XCTAssertNotNil(properties?["location_query"])
    }

    func testAIProvidersUseFixedOfficialTextEndpoints() {
        XCTAssertEqual(AIProvider.agnes.baseURL, "https://apihub.agnes-ai.com/v1")
        XCTAssertEqual(AIProvider.deepSeek.baseURL, "https://api.deepseek.com")
        XCTAssertEqual(AIProvider.deepSeek.defaultModel, "deepseek-v4-flash")
        XCTAssertTrue(AIProvider.deepSeek.availableModels.contains("deepseek-v4-pro"))
        XCTAssertEqual(AIProvider.glm.baseURL, "https://open.bigmodel.cn/api/paas/v4")
        XCTAssertEqual(AIProvider.glm.defaultModel, "glm-4.5-flash")
        XCTAssertTrue(AIProvider.glm.availableModels.contains("glm-4.5-air"))
    }

    func testAssistantDisplayTextRemovesMarkdownNoise() {
        XCTAssertEqual("**重点**\n* 第一项\n### 小结".assistantDisplayText,
                       "重点\n• 第一项\n小结")
    }

    func testTravelDetectionUsesRoutineAndExcludesHomePhotos() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_720_000_000)
        let home = CustomPlace(shortName: "家",
                               latitude: 31.2,
                               longitude: 121.4,
                               category: .accommodation)
        context.insert(home)
        let session = insertSession(start: start,
                                    coordinates: [(32.0, 121.4), (32.05, 121.4), (32.1, 121.4)],
                                    into: context)
        let remoteStay = StayRecord(detectedName: "异地景区",
                                    latitude: 32.05,
                                    longitude: 121.4,
                                    arrivalTime: start)
        remoteStay.duration = 60 * 60
        context.insert(remoteStay)
        let remotePhoto = PhotoAnalysisRecord(assetIdentifier: "remote",
                                              creationDate: start.addingTimeInterval(30),
                                              latitude: 32.05,
                                              longitude: 121.4,
                                              categories: [.landscape],
                                              topLabels: ["mountain|0.9"],
                                              confidence: 0.9,
                                              faceCount: 0,
                                              state: .completed)
        let homePhoto = PhotoAnalysisRecord(assetIdentifier: "home",
                                            creationDate: start.addingTimeInterval(40),
                                            latitude: 31.2,
                                            longitude: 121.4,
                                            categories: [.food],
                                            topLabels: ["food|0.9"],
                                            confidence: 0.9,
                                            faceCount: 0,
                                            state: .completed)
        context.insert(remotePhoto)
        context.insert(homePhoto)

        let suggestions = TravelArchiveDetectionService.suggestions(
            photos: [remotePhoto, homePhoto], sessions: [session], stays: [remoteStay], places: [home],
            timelineNodes: [], confirmed: [])

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].photoCount, 1)
        XCTAssertTrue(suggestions[0].reason.contains("已排除"))
    }

    func testPhotosAloneNeverCreateTravelSuggestion() {
        let home = CustomPlace(shortName: "宿舍",
                               latitude: 31.2,
                               longitude: 121.4,
                               category: .accommodation)
        let photo = PhotoAnalysisRecord(assetIdentifier: "far-photo-only",
                                        creationDate: .now,
                                        latitude: 35,
                                        longitude: 121.4,
                                        categories: [.landscape],
                                        topLabels: ["sea|0.9"],
                                        confidence: 0.9,
                                        faceCount: 0,
                                        state: .completed)
        XCTAssertTrue(TravelArchiveDetectionService.suggestions(
            photos: [photo], sessions: [], stays: [], places: [home],
            timelineNodes: [], confirmed: []).isEmpty)
    }

    func testTodayPhotosRequireGPSOrTimeMatchToRecordedTrack() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let start = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: .now)!
        let session = insertSession(start: start,
                                    coordinates: [(31.20, 121.40), (31.201, 121.401), (31.202, 121.402)],
                                    into: context)
        let matchingGPS = PhotoLibraryAssetDescriptor(id: "near-gps",
                                                      creationDate: start.addingTimeInterval(30),
                                                      displayLatitude: 31.201,
                                                      displayLongitude: 121.401,
                                                      originalLatitude: 31.201,
                                                      originalLongitude: 121.401,
                                                      isSelfie: false)
        let matchingTime = PhotoLibraryAssetDescriptor(id: "time-only",
                                                       creationDate: start.addingTimeInterval(60),
                                                       displayLatitude: nil,
                                                       displayLongitude: nil,
                                                       originalLatitude: nil,
                                                       originalLongitude: nil,
                                                       isSelfie: false)
        let farGPS = PhotoLibraryAssetDescriptor(id: "far-gps",
                                                 creationDate: start.addingTimeInterval(30),
                                                 displayLatitude: 35,
                                                 displayLongitude: 121.4,
                                                 originalLatitude: 35,
                                                 originalLongitude: 121.4,
                                                 isSelfie: false)

        let moments = TodayPhotoTrackService.moments(descriptors: [matchingGPS, matchingTime, farGPS],
                                                     sessions: [session])

        XCTAssertEqual(Set(moments.map(\.assetIdentifier)), ["near-gps", "time-only"])
        XCTAssertTrue(moments.first { $0.assetIdentifier == "near-gps" }?.usesPhotoLocation == true)
        XCTAssertTrue(moments.first { $0.assetIdentifier == "time-only" }?.usesPhotoLocation == false)
    }

    func testHistoricalExerciseCanDisplayAssociatedPhotos() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_650_000_000)
        let session = insertSession(start: start,
                                    coordinates: [(31.20, 121.40), (31.201, 121.401)],
                                    into: context)
        let descriptor = PhotoLibraryAssetDescriptor(id: "historical-exercise-photo",
                                                     creationDate: start.addingTimeInterval(30),
                                                     displayLatitude: 31.201,
                                                     displayLongitude: 121.401,
                                                     originalLatitude: 31.201,
                                                     originalLongitude: 121.401,
                                                     isSelfie: false)

        let moments = TodayPhotoTrackService.momentsForRecordedTracks(descriptors: [descriptor],
                                                                      sessions: [session])

        XCTAssertEqual(moments.map(\.assetIdentifier), ["historical-exercise-photo"])
    }

    func testHistoricalPhotoTravelEvidenceExcludesRoutineAreaAndRestoresRemoteDays() {
        let home = CLLocationCoordinate2D(latitude: 31.20, longitude: 121.40)
        let nearby = CLLocationCoordinate2D(latitude: 31.25, longitude: 121.45)
        let remote = CLLocationCoordinate2D(latitude: 39.90, longitude: 116.40)

        XCTAssertFalse(TravelTimelineGenerationService.isHistoricalPhotoTravelEvidence(
            coordinate: nearby, routineAnchors: [home], groupPhotoCount: 20))
        XCTAssertTrue(TravelTimelineGenerationService.isHistoricalPhotoTravelEvidence(
            coordinate: remote, routineAnchors: [home], groupPhotoCount: 1))
    }

    func testRoutineAnchorsCanBeInferredFromRecurringHistoricalMetadata() {
        let base = Date(timeIntervalSince1970: 1_650_000_000)
        var samples: [HistoricalRoutineLocationSample] = []
        for day in 0..<12 {
            samples.append(HistoricalRoutineLocationSample(
                coordinate: CLLocationCoordinate2D(latitude: 31.20 + Double(day % 2) * 0.001,
                                                    longitude: 121.40),
                date: base.addingTimeInterval(Double(day) * 86_400)
            ))
        }
        for day in 0..<2 {
            samples.append(HistoricalRoutineLocationSample(
                coordinate: CLLocationCoordinate2D(latitude: 39.90, longitude: 116.40),
                date: base.addingTimeInterval(Double(day) * 86_400)
            ))
        }

        let anchors = TravelTimelineGenerationService.inferredRoutineAnchors(samples: samples)

        XCTAssertEqual(anchors.count, 1)
        let inferredLocation = CLLocation(latitude: anchors[0].latitude, longitude: anchors[0].longitude)
        let expectedLocation = CLLocation(latitude: 31.20, longitude: 121.40)
        XCTAssertLessThan(inferredLocation.distance(from: expectedLocation),
                          2_000)
    }

    func testTimelineCacheRebuildNeverDeletesHistoricalTripsMissingFromCurrentDrafts() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        let historical = TravelTimelineTrip(stableKey: "photo:historical",
                                            title: "历史旅行",
                                            startTime: Date(timeIntervalSince1970: 1_650_000_000),
                                            endTime: Date(timeIntervalSince1970: 1_650_003_600),
                                            totalDistance: 12_000,
                                            sourceFingerprint: "legacy-source",
                                            routePoints: [])
        context.insert(historical)
        try context.save()

        _ = await TravelTimelineGenerationService.rebuildFromCache(context: context, sessions: [])

        let trips = try context.fetch(FetchDescriptor<TravelTimelineTrip>())
        XCTAssertEqual(trips.map(\.stableKey), ["photo:historical"])
    }

    func testPhotoAIPrivacyFilterSharesMetadataWithoutImageOrExactGPS() {
        let record = PhotoAnalysisRecord(
            assetIdentifier: "secret-asset-id",
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            latitude: 31.234567,
            longitude: 121.456789,
            categories: [.landscape, .people, .selfie],
            topLabels: ["mountain|0.98", "person|0.99", "passport|0.91", "beach|0.80"],
            confidence: 0.98,
            faceCount: 3,
            state: .completed,
            linkedSessionID: UUID()
        )
        let school = CustomPlace(shortName: "学校",
                                 latitude: 31.2346,
                                 longitude: 121.4568,
                                 radius: 500,
                                 category: .study)

        let summary = PhotoAIPrivacyFilter.summary(records: [record], days: 30, places: [school])
        XCTAssertTrue(summary.contains("学校"))
        XCTAssertTrue(summary.contains("年"))
        XCTAssertTrue(summary.contains("完整逐日索引"))
        XCTAssertTrue(summary.contains("逐张元数据"))
        XCTAssertTrue(summary.contains("风景"))
        XCTAssertTrue(summary.contains("mountain"))
        XCTAssertTrue(summary.contains("beach"))
        XCTAssertFalse(summary.contains("- 人物："))
        XCTAssertFalse(summary.contains("- 自拍："))
        XCTAssertFalse(summary.contains("person"))
        XCTAssertFalse(summary.contains("passport"))
        XCTAssertFalse(summary.contains("secret-asset-id"))
        XCTAssertTrue(summary.contains("31.234567"))
        XCTAssertTrue(summary.contains("121.456789"))
        XCTAssertFalse(summary.contains("1700000000"))
        XCTAssertFalse(summary.contains("3 张脸"))
        XCTAssertFalse(summary.contains("image_url"))
        XCTAssertFalse(summary.contains("base64"))
    }

    func testPhotoMetadataDailyIndexIncludesOldDatesBeyondDetailLimit() {
        let calendar = Calendar(identifier: .gregorian)
        let march = calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 10))!
        let april = calendar.date(from: DateComponents(year: 2026, month: 4, day: 1, hour: 11))!
        let records = [march, april].enumerated().map { index, date in
            PhotoAnalysisRecord(assetIdentifier: "photo-\(index)",
                                creationDate: date,
                                categories: [.landscape],
                                topLabels: [],
                                confidence: 0.8,
                                faceCount: 0,
                                state: .completed)
        }

        let summary = PhotoAIPrivacyFilter.summary(records: records,
                                                   days: 20,
                                                   rangeDescription: "2026-03-20 至 2026-04-05",
                                                   detailLimit: 1)

        XCTAssertTrue(summary.contains("2026-03-28：1 张"))
        XCTAssertTrue(summary.contains("2026-04-01：1 张"))
        XCTAssertTrue(summary.contains("已经计入上方完整逐日索引"))
    }

    func testAgnesWireMessageHasNoImageContentBranch() {
        let dictionary = AgnesWireMessage.text("只发送文字", role: .user).dictionary
        XCTAssertEqual(dictionary["content"] as? String, "只发送文字")
        XCTAssertNil(dictionary["image_url"])
        XCTAssertNil(dictionary["image"])
        XCTAssertFalse(String(describing: dictionary).contains("base64"))
    }

    func testHandDrawnGeofenceUsesPolygonInsteadOfRadius() {
        let place = CustomPlace(shortName: "图书馆",
                                latitude: 31.0,
                                longitude: 121.0,
                                radius: 20)
        let geofence = PlaceGeofence(
            placeID: place.id,
            areaType: .library,
            vertices: [
                .init(latitude: 30.999, longitude: 120.999),
                .init(latitude: 30.999, longitude: 121.002),
                .init(latitude: 31.002, longitude: 121.002),
                .init(latitude: 31.002, longitude: 120.999)
            ]
        )
        let service = PlaceRecognitionService()

        let insidePolygonOutsideCircle = CLLocation(latitude: 31.0015, longitude: 121.0015)
        XCTAssertEqual(service.matchingPlace(for: insidePolygonOutsideCircle,
                                             places: [place],
                                             geofences: [place.id: geofence])?.id,
                       place.id)
        XCTAssertFalse(service.hasExited(place,
                                         location: insidePolygonOutsideCircle,
                                         geofence: geofence))

        let outside = CLLocation(latitude: 31.003, longitude: 121.003)
        XCTAssertNil(service.matchingPlace(for: outside,
                                           places: [place],
                                           geofences: [place.id: geofence]))
        XCTAssertTrue(service.hasExited(place, location: outside, geofence: geofence))
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
        let schema = Schema(versionedSchema: LifeTrackSchemaV5.self)
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
        let schema = Schema(versionedSchema: LifeTrackSchemaV5.self)
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

    func testMarkdownExportGeneratesValidStructureForEmptyDate() async throws {
        let container = try makeContainer()
        let testDate = Date(timeIntervalSince1970: 1_700_000_000)
        let md = await MarkdownExportService.generateDailyMarkdown(for: testDate, context: container.mainContext)
        XCTAssertTrue(md.contains("生活与轨迹复盘"))
        XCTAssertTrue(md.contains("date:"))
        XCTAssertTrue(md.contains("今日量化简报"))
        XCTAssertTrue(md.contains("今日时间线"))
    }

    func testMarkdownExportAggregatesSessionsStaysAndInsights() async throws {
        let container = try makeContainer()
        let testDate = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try insertSampleSession(into: container.mainContext)
        let stay = StayRecord(customPlaceID: UUID(),
                              detectedName: "图书馆自习室",
                              latitude: 31.201,
                              longitude: 121.401,
                              arrivalTime: testDate.addingTimeInterval(3600))
        stay.departureTime = testDate.addingTimeInterval(7200)
        stay.duration = 3600
        container.mainContext.insert(stay)

        let insight = LifeInsightRecord(kind: "dailyReflection",
                                        title: "充实的学习日",
                                        content: "今天在图书馆专注自习了1小时。")
        insight.createdAt = testDate.addingTimeInterval(8000)
        container.mainContext.insert(insight)
        try container.mainContext.save()

        let md = await MarkdownExportService.generateDailyMarkdown(for: testDate, context: container.mainContext)
        XCTAssertTrue(md.contains("图书馆自习室"))
        XCTAssertTrue(md.contains("充实的学习日"))
        XCTAssertTrue(md.contains("步行"))
        XCTAssertTrue(md.contains("total_distance_km:"))
        XCTAssertTrue(md.contains("study_duration_min:"))
    }

    func testMarkdownExportCustomOptionsToggle() async throws {
        let container = try makeContainer()
        let testDate = Date(timeIntervalSince1970: 1_700_000_000)
        var options = MarkdownExportOptions.standard
        options.includeYAMLFrontmatter = false
        options.includeStatsTable = false

        let md = await MarkdownExportService.generateDailyMarkdown(for: testDate,
                                                                 context: container.mainContext,
                                                                 options: options)
        XCTAssertFalse(md.hasPrefix("---"))
        XCTAssertFalse(md.contains("今日量化简报"))
        XCTAssertTrue(md.contains("生活与轨迹复盘"))
    }

    func testMarkdownExportIncludesEnabledCoursesAndEscapesUserText() async throws {
        let container = try makeContainer()
        let calendar = Calendar.current
        let testDate = Date(timeIntervalSince1970: 1_700_000_000)
        let weekday = calendar.component(.weekday, from: testDate)
        let normalizedWeekday = weekday == 1 ? 7 : weekday - 1
        let course = CourseEvent(weekday: normalizedWeekday,
                                 startMinutes: 9 * 60,
                                 endMinutes: 10 * 60,
                                 name: "算法|设计",
                                 locationName: "A_101",
                                 weekParity: 1)
        container.mainContext.insert(course)

        let stay = StayRecord(detectedName: "图书\"馆|主馆\n二楼",
                              latitude: 31.2,
                              longitude: 121.4,
                              arrivalTime: testDate.addingTimeInterval(60))
        stay.departureTime = testDate.addingTimeInterval(120)
        stay.duration = 60
        container.mainContext.insert(stay)
        try container.mainContext.save()

        let md = await MarkdownExportService.generateDailyMarkdown(for: testDate,
                                                                    context: container.mainContext,
                                                                    calendar: calendar)

        XCTAssertTrue(md.contains("📚 算法\\|设计"))
        XCTAssertTrue(md.contains("A\\_101"))
        XCTAssertTrue(md.contains("`单周`"))
        XCTAssertTrue(md.contains("图书\\\"馆|主馆\\n二楼"))
    }

    func testMarkdownExportClampsRecordsThatCrossMidnight() async throws {
        let container = try makeContainer()
        let calendar = Calendar.current
        let testDate = Date(timeIntervalSince1970: 1_700_000_000)
        let startOfDay = calendar.startOfDay(for: testDate)
        let session = ActivitySession(activityType: .walking,
                                      source: "test",
                                      startTime: startOfDay.addingTimeInterval(-30 * 60))
        session.endTime = startOfDay.addingTimeInterval(30 * 60)
        session.duration = 60 * 60
        session.distance = 1_000
        session.isActive = false
        container.mainContext.insert(session)
        try container.mainContext.save()

        let md = await MarkdownExportService.generateDailyMarkdown(for: testDate,
                                                                    context: container.mainContext,
                                                                    calendar: calendar)

        XCTAssertTrue(md.contains("active_duration_min: 30"))
        XCTAssertTrue(md.contains("total_distance_km: 0.50"))
        XCTAssertTrue(md.contains("**00:00 - 00:30**"))
    }

    func testMarkdownExportAssociatesPhotosForSelectedHistoricalDate() async throws {
        let container = try makeContainer()
        let start = Date(timeIntervalSince1970: 1_650_000_000)
        _ = insertSession(start: start,
                          coordinates: [(31.20, 121.40), (31.201, 121.401)],
                          into: container.mainContext)
        let descriptor = PhotoLibraryAssetDescriptor(id: "historical-markdown-photo",
                                                     creationDate: start.addingTimeInterval(30),
                                                     displayLatitude: 31.201,
                                                     displayLongitude: 121.401,
                                                     originalLatitude: 31.201,
                                                     originalLongitude: 121.401,
                                                     isSelfie: false)
        try container.mainContext.save()

        let md = await MarkdownExportService.generateDailyMarkdown(for: start,
                                                                    context: container.mainContext,
                                                                    photoDescriptors: [descriptor])

        XCTAssertTrue(md.contains("沿途照片时刻"))
        XCTAssertTrue(md.contains(Formatters.timeString(descriptor.creationDate)))
    }

    func testMarkdownExportCreatesValidTemporaryFile() throws {
        let testDate = Date(timeIntervalSince1970: 1_700_000_000)
        let sampleContent = "# Test Markdown"
        let url = try MarkdownExportService.createTemporaryMarkdownFile(content: sampleContent, for: testDate)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let readBack = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(readBack, sampleContent)
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
