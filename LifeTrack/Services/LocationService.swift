import CoreLocation
import CoreMotion
import OSLog
import SwiftData

enum RecordingState: Equatable {
    case idle
    case recording
    case stopping
    case stopFailed
}

final class LocationService: NSObject, ObservableObject {
    static let shared = LocationService()

    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var currentLocation: CLLocation?
    @Published private(set) var currentActivity: ActivityType = .unknown
    @Published private(set) var activeSession: ActivitySession?
    @Published private(set) var lastError: String?
    @Published private(set) var lastCriticalError: String?
    @Published private(set) var recoveryNotice: String?
    @Published private(set) var recordingState: RecordingState = .idle
    @Published var recordingPreference: RecordingPreference = .smart {
        didSet { applySamplingPolicy() }
    }

    var canRecordInForeground: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }

    var hasBackgroundAuthorization: Bool {
        authorizationStatus == .authorizedAlways
    }

    var needsBackgroundWarning: Bool {
        activeSession != nil && !hasBackgroundAuthorization
    }

    private let manager = CLLocationManager()
    private let motionService = MotionActivityService()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LifeTrack",
                                category: "Location")
    private weak var modelContext: ModelContext?
    private var lastSavedLocation: CLLocation?
    private var lastDistanceLocation: CLLocation?
    private var pointsSinceLastAnalysis = 0
    private var lastActivityChange = Date.distantPast
    private var currentMotionConfidence: CMMotionActivityConfidence = .low
    private let placeRecognitionService = PlaceRecognitionService()
    private var pendingStay: StayRecord?
    private var cachedPlaces: [CustomPlace] = []
    private var cachedGeofences: [UUID: PlaceGeofence] = [:]
    private var pendingAlwaysRequest = false
    private var isConfigured = false
    private var unsavedTrackPointCount = 0
    private var lastPersistenceDate = Date.distantPast
    private var hasPendingPersistenceChanges = false

    private static let maximumRecoveryGap: TimeInterval = 4 * 60 * 60
    private static let maximumStayPointGap: TimeInterval = 60 * 60
    private static let maximumUnsavedTrackPointCount = 10
    private static let maximumPersistenceInterval: TimeInterval = 20

    private override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = true
    }

    func configure(with context: ModelContext) {
        modelContext = context
        guard !isConfigured else { return }
        isConfigured = true
        recordingPreference = RecordingPreference(
            rawValue: UserDefaults.standard.string(forKey: "recordingPreference") ?? "smart"
        ) ?? .smart
        refreshPlaceCache()
        reprocessStoredDataIfNeeded()
        recoverActiveSessions()
    }

    /// Requests only foreground access. Always access is requested separately after an explicit user action.
    func requestAuthorization() {
        requestForegroundAuthorization()
    }

    func requestForegroundAuthorization() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func requestBackgroundAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            pendingAlwaysRequest = true
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        case .denied, .restricted:
            recordError("定位权限已关闭，请在系统设置中允许 LifeTrack 使用定位。", critical: true)
        case .authorizedAlways:
            break
        @unknown default:
            recordError("无法确认定位授权状态。", critical: false)
        }
    }

    func requestCurrentLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            recordError("需要允许定位访问后才能回到当前位置。", critical: false)
        @unknown default:
            recordError("无法确认定位授权状态。", critical: false)
        }
    }

    func startRecording(manualActivity: ActivityType? = nil) {
        lastCriticalError = nil
        guard let modelContext else {
            recordError("数据存储尚未准备好。", critical: true)
            return
        }
        guard canRecordInForeground else {
            recordError("开始记录前需要先允许定位访问。", critical: true)
            requestForegroundAuthorization()
            return
        }
        guard activeSession == nil, recordingState == .idle else { return }

        // Resolve any persisted active row first so repeated taps cannot create duplicate sessions.
        if hasPersistedActiveSession() {
            recoverActiveSessions()
            guard activeSession == nil else { return }
        }

        let session = ActivitySession(activityType: manualActivity ?? currentActivity,
                                      source: manualActivity == nil ? "automatic" : "manual")
        session.manualActivityType = manualActivity
        modelContext.insert(session)
        guard saveContext(operation: "开始运动记录",
                          critical: true,
                          failureRecovery: .rollback) else {
            return
        }

        activeSession = session
        recordingState = .recording
        pendingStay = nil
        lastSavedLocation = nil
        lastDistanceLocation = nil
        pointsSinceLastAnalysis = 0
        resetPendingPersistenceState(at: .now)
        startSensors()
    }

    func stopRecording() {
        guard let session = activeSession, recordingState == .recording else { return }
        lastCriticalError = nil
        recordingState = .stopping
        manager.stopUpdatingLocation()
        motionService.stopUpdates()

        let end = Date.now
        session.endTime = end
        session.duration = max(0, end.timeIntervalSince(session.startTime))
        session.isActive = false
        finalizePendingStay(at: end)
        applyTrajectoryAnalysis(to: session)
        TransitDetectionService.relabelIfTransit(session)
        rebuildStayRecords(for: session)
        hasPendingPersistenceChanges = true

        if saveContext(operation: "结束运动记录", critical: true) {
            completeSuccessfulStop()
        } else {
            recordingState = .stopFailed
            recordError("结束记录保存失败，请重试。轨迹仍保留在当前会话中。", critical: true)
        }
    }

    func retryStopRecording() {
        guard activeSession != nil, recordingState == .stopFailed else { return }
        lastCriticalError = nil
        recordingState = .stopping
        if saveContext(operation: "重试结束运动记录", critical: true) {
            completeSuccessfulStop()
        } else {
            recordingState = .stopFailed
            recordError("结束记录保存失败，请重试。轨迹仍保留在当前会话中。", critical: true)
        }
    }

    func flushPendingTrackDataIfNeeded(force: Bool) {
        guard activeSession != nil || hasPendingPersistenceChanges else { return }
        if recordingState == .stopFailed {
            if force { retryStopRecording() }
            return
        }
        guard recordingState == .recording else { return }

        let reachedCountLimit = unsavedTrackPointCount >= Self.maximumUnsavedTrackPointCount
        let reachedTimeLimit = Date.now.timeIntervalSince(lastPersistenceDate) >= Self.maximumPersistenceInterval
        guard force || reachedCountLimit || reachedTimeLimit else { return }

        if saveContext(operation: force ? "保存待处理轨迹" : "批量保存轨迹点") {
            resetPendingPersistenceState(at: .now)
        }
    }

    func retryPendingPersistence() {
        if recordingState == .stopFailed {
            retryStopRecording()
        } else {
            flushPendingTrackDataIfNeeded(force: true)
        }
    }

    func refreshPlaceCache() {
        guard let modelContext else { return }
        do {
            cachedPlaces = try modelContext.fetch(FetchDescriptor<CustomPlace>())
            cachedGeofences = Dictionary(uniqueKeysWithValues:
                try modelContext.fetch(FetchDescriptor<PlaceGeofence>()).map { ($0.placeID, $0) })
        } catch {
            recordError("刷新地点缓存失败：\(error.localizedDescription)", critical: false)
            logger.error("Place cache refresh failed: \(String(reflecting: error), privacy: .public)")
        }
    }

    func setManualActivity(_ activity: ActivityType?) {
        guard let session = activeSession else { return }
        session.manualActivityType = activity
        if let activity { currentActivity = activity }
        session.activityType = currentActivity
        applySamplingPolicy()
        if saveContext(operation: "更新活动类型") {
            resetPendingPersistenceState(at: .now)
        } else {
            hasPendingPersistenceChanges = true
        }
    }

    func savePreference() {
        UserDefaults.standard.set(recordingPreference.rawValue, forKey: "recordingPreference")
        applySamplingPolicy()
    }

    func clearCriticalError() {
        lastCriticalError = nil
    }

    private func startSensors() {
        applySamplingPolicy()
        manager.allowsBackgroundLocationUpdates = activeSession != nil && hasBackgroundAuthorization
        manager.startUpdatingLocation()
        motionService.startUpdates { [weak self] activity, confidence in
            self?.handleMotion(activity, confidence: confidence)
        }
    }

    private func restore(session: ActivitySession) {
        activeSession = session
        recordingState = .recording
        applyTrajectoryAnalysis(to: session)
        let orderedPoints = session.trackPoints.sorted(by: { $0.timestamp < $1.timestamp })
        lastSavedLocation = orderedPoints.last.map(Self.location(for:))
        lastDistanceLocation = orderedPoints.last(where: \.isUsableForAnalysis).map(Self.location(for:))
        pointsSinceLastAnalysis = 0
        currentActivity = session.manualActivityType ?? session.activityType
        restorePendingStay(for: session, orderedPoints: orderedPoints)
        hasPendingPersistenceChanges = true
        if saveContext(operation: "恢复运动记录") {
            resetPendingPersistenceState(at: .now)
        }
        startSensors()
    }

    private func recoverActiveSessions(now: Date = .now) {
        guard let modelContext else { return }
        do {
            let descriptor = FetchDescriptor<ActivitySession>(
                predicate: #Predicate { $0.isActive },
                sortBy: [SortDescriptor(\ActivitySession.startTime, order: .reverse)]
            )
            let active = try modelContext.fetch(descriptor)
            guard !active.isEmpty else { return }

            let newest = active[0]
            let shouldResumeNewest = shouldResume(newest, now: now)
            var closedCount = 0

            for session in active {
                if session.id == newest.id && shouldResumeNewest { continue }
                closeAbandonedSession(session, now: now)
                closedCount += 1
            }

            if closedCount > 0 {
                let detail = shouldResumeNewest
                    ? "已自动关闭 \(closedCount) 条较旧的异常记录。"
                    : "检测到长时间中断的记录，已按最后定位点安全结束。"
                recoveryNotice = detail
                hasPendingPersistenceChanges = true
                if saveContext(operation: "修复异常运动记录") {
                    resetPendingPersistenceState(at: .now)
                }
            }

            if shouldResumeNewest {
                restore(session: newest)
            }
        } catch {
            recordError("恢复未完成的运动记录失败：\(error.localizedDescription)", critical: false)
            logger.error("Active session recovery failed: \(String(reflecting: error), privacy: .public)")
        }
    }

    private func hasPersistedActiveSession() -> Bool {
        guard let modelContext else { return false }
        do {
            var descriptor = FetchDescriptor<ActivitySession>(predicate: #Predicate { $0.isActive })
            descriptor.fetchLimit = 1
            return try !modelContext.fetch(descriptor).isEmpty
        } catch {
            recordError("检查未完成记录失败：\(error.localizedDescription)", critical: false)
            return false
        }
    }

    private func shouldResume(_ session: ActivitySession, now: Date) -> Bool {
        let lastActivity = session.trackPoints.map(\.timestamp).max() ?? session.startTime
        let gap = now.timeIntervalSince(lastActivity)
        return gap >= -5 * 60 && gap <= Self.maximumRecoveryGap
    }

    private func closeAbandonedSession(_ session: ActivitySession, now: Date) {
        let lastPointTime = session.trackPoints.map(\.timestamp).max()
        let end = min(max(lastPointTime ?? session.startTime, session.startTime), now)
        session.endTime = end
        session.duration = max(0, end.timeIntervalSince(session.startTime))
        session.isActive = false
        applyTrajectoryAnalysis(to: session)
        rebuildStayRecords(for: session)
    }

    private func handleMotion(_ motionActivity: ActivityType,
                              confidence: CMMotionActivityConfidence) {
        currentMotionConfidence = confidence
        guard activeSession != nil, activeSession?.manualActivityType == nil else { return }
        guard confidence != .low,
              motionActivity != currentActivity,
              Date.now.timeIntervalSince(lastActivityChange) > 20 else { return }
        currentActivity = motionActivity
        activeSession?.activityType = motionActivity
        lastActivityChange = .now
        applySamplingPolicy()
    }

    private func applySamplingPolicy() {
        let policy = SamplingPolicy.policy(for: activeSession?.manualActivityType ?? currentActivity,
                                           preference: recordingPreference)
        manager.desiredAccuracy = policy.desiredAccuracy
        manager.distanceFilter = policy.distanceFilter
    }

    private func process(_ location: CLLocation) {
        currentLocation = location
        guard recordingState == .recording,
              let session = activeSession,
              isValid(location) else { return }
        let activity = session.manualActivityType ?? inferredActivity(for: location)
        let policy = SamplingPolicy.policy(for: activity, preference: recordingPreference)
        guard shouldSave(location, after: lastSavedLocation, policy: policy) else { return }

        if let previous = lastDistanceLocation,
           TrajectoryAnalysisService.isPlausibleLeg(from: previous, to: location) {
            session.distance += location.distance(from: previous)
        }
        session.duration = max(0, location.timestamp.timeIntervalSince(session.startTime))
        session.activityType = activity
        let point = TrackPoint(latitude: location.coordinate.latitude,
                               longitude: location.coordinate.longitude,
                               altitude: location.altitude,
                               speed: location.speed,
                               course: location.course,
                               horizontalAccuracy: location.horizontalAccuracy,
                               timestamp: location.timestamp,
                               activityType: activity,
                               session: session)
        modelContext?.insert(point)
        lastSavedLocation = location
        lastDistanceLocation = location
        pointsSinceLastAnalysis += 1
        unsavedTrackPointCount += 1
        hasPendingPersistenceChanges = true
        if pointsSinceLastAnalysis >= 8 {
            applyTrajectoryAnalysis(to: session, including: point)
            pointsSinceLastAnalysis = 0
        }
        updatePlaceRecognition(for: location, session: session)
        flushPendingTrackDataIfNeeded(force: false)
    }

    private func inferredActivity(for location: CLLocation) -> ActivityType {
        if let manual = activeSession?.manualActivityType { return manual }
        if currentMotionConfidence != .low, currentActivity != .unknown { return currentActivity }
        let speed = max(location.speed, 0)
        if speed < 0.7 { return .stationary }
        if speed < 2.4 { return .walking }
        if speed < 5.5 { return .running }
        if speed < 11 { return .cycling }
        return .automotive
    }

    private func isValid(_ location: CLLocation) -> Bool {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 200 else { return false }
        guard location.timestamp.timeIntervalSinceNow > -30 else { return false }
        guard location.coordinate.latitude != 0 || location.coordinate.longitude != 0 else { return false }
        return true
    }

    private func shouldSave(_ location: CLLocation,
                            after previous: CLLocation?,
                            policy: SamplingPolicy) -> Bool {
        guard location.horizontalAccuracy <= policy.minimumAccuracy else { return false }
        guard let previous else { return true }
        let time = location.timestamp.timeIntervalSince(previous.timestamp)
        guard time > 0 else { return false }
        let distance = location.distance(from: previous)
        return time >= policy.minimumInterval || distance >= policy.distanceFilter
    }

    private func applyTrajectoryAnalysis(to session: ActivitySession,
                                         including pendingPoint: TrackPoint? = nil) {
        var points = session.trackPoints
        if let pendingPoint, !points.contains(where: { $0.id == pendingPoint.id }) {
            points.append(pendingPoint)
        }
        let analysis = TrajectoryAnalysisService.analyze(points)
        for point in points {
            point.anomalyReason = analysis.anomalyReasons[point.id]
        }
        session.distance = analysis.effectiveDistance
        lastDistanceLocation = points
            .filter(\.isUsableForAnalysis)
            .max(by: { $0.timestamp < $1.timestamp })
            .map(Self.location(for:))
    }

    private func rebuildStayRecords(for session: ActivitySession) {
        guard let modelContext else { return }
        StayDetectionService.rebuildRecords(for: session, places: cachedPlaces, in: modelContext)
    }

    private func reprocessStoredDataIfNeeded() {
        guard let modelContext else { return }
        let versionKey = "trajectoryAnalysisVersion"
        let currentVersion = 1
        guard UserDefaults.standard.integer(forKey: versionKey) < currentVersion else { return }

        do {
            let sessions = try modelContext.fetch(FetchDescriptor<ActivitySession>())
            for session in sessions where !session.isActive {
                applyTrajectoryAnalysis(to: session)
                StayDetectionService.rebuildRecords(for: session, places: cachedPlaces, in: modelContext)
            }
            if saveContext(operation: "历史轨迹重新分析") {
                UserDefaults.standard.set(currentVersion, forKey: versionKey)
            }
        } catch {
            recordError("历史轨迹重新分析失败：\(error.localizedDescription)", critical: false)
            logger.error("Stored trajectory reprocessing failed: \(String(reflecting: error), privacy: .public)")
        }
    }

    private static func location(for point: TrackPoint) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: point.latitude,
                                                      longitude: point.longitude),
                   altitude: point.altitude,
                   horizontalAccuracy: point.horizontalAccuracy,
                   verticalAccuracy: -1,
                   course: point.course,
                   speed: point.speed,
                   timestamp: point.timestamp)
    }

    private func updatePlaceRecognition(for location: CLLocation,
                                        session: ActivitySession) {
        guard let modelContext else { return }
        let matchingPlace = placeRecognitionService.matchingPlace(for: location,
                                                                  places: cachedPlaces,
                                                                  geofences: cachedGeofences)

        if let pendingStay,
           let currentPlace = cachedPlaces.first(where: { $0.id == pendingStay.customPlaceID }),
           !placeRecognitionService.hasExited(currentPlace,
                                              location: location,
                                              geofence: cachedGeofences[currentPlace.id]) {
            pendingStay.duration = max(0, location.timestamp.timeIntervalSince(pendingStay.arrivalTime))
            return
        }

        finalizePendingStay(at: location.timestamp)
        guard let matchingPlace else { return }

        if let existing = session.stayRecords
            .filter({ $0.customPlaceID == matchingPlace.id && $0.departureTime == nil })
            .max(by: { $0.arrivalTime < $1.arrivalTime }) {
            pendingStay = existing
            existing.duration = max(0, location.timestamp.timeIntervalSince(existing.arrivalTime))
            return
        }

        let stay = StayRecord(customPlaceID: matchingPlace.id,
                              detectedName: matchingPlace.shortName,
                              latitude: matchingPlace.latitude,
                              longitude: matchingPlace.longitude,
                              arrivalTime: location.timestamp,
                              session: session)
        modelContext.insert(stay)
        pendingStay = stay
    }

    private func restorePendingStay(for session: ActivitySession,
                                    orderedPoints: [TrackPoint]) {
        pendingStay = nil
        guard let modelContext, let latestPoint = orderedPoints.last else { return }

        let latestLocation = Self.location(for: latestPoint)
        let matchingPlace = placeRecognitionService.matchingPlace(for: latestLocation,
                                                                  places: cachedPlaces,
                                                                  geofences: cachedGeofences)

        for openRecord in session.stayRecords.filter({ $0.departureTime == nil }) {
            guard let place = cachedPlaces.first(where: { $0.id == openRecord.customPlaceID }),
                  !placeRecognitionService.hasExited(place,
                                                     location: latestLocation,
                                                     geofence: cachedGeofences[place.id]),
                  place.id == matchingPlace?.id else {
                closeRecoveredStay(openRecord, at: latestPoint.timestamp)
                continue
            }
            openRecord.duration = max(0, latestPoint.timestamp.timeIntervalSince(openRecord.arrivalTime))
            pendingStay = openRecord
        }

        guard pendingStay == nil, let matchingPlace else { return }

        let arrival = inferredArrivalTime(at: matchingPlace,
                                          in: orderedPoints,
                                          endingAt: latestPoint.timestamp)
        let duplicates = session.stayRecords.contains { record in
            guard record.customPlaceID == matchingPlace.id else { return false }
            let end = record.departureTime ?? latestPoint.timestamp
            return record.arrivalTime <= latestPoint.timestamp && end >= arrival
        }
        guard !duplicates else { return }

        let restored = StayRecord(customPlaceID: matchingPlace.id,
                                  detectedName: matchingPlace.shortName,
                                  latitude: matchingPlace.latitude,
                                  longitude: matchingPlace.longitude,
                                  arrivalTime: arrival,
                                  session: session)
        restored.duration = max(0, latestPoint.timestamp.timeIntervalSince(arrival))
        modelContext.insert(restored)
        pendingStay = restored
    }

    private func inferredArrivalTime(at place: CustomPlace,
                                     in orderedPoints: [TrackPoint],
                                     endingAt latest: Date) -> Date {
        var arrival = latest
        var laterTimestamp = latest
        for point in orderedPoints.reversed() {
            guard laterTimestamp.timeIntervalSince(point.timestamp) <= Self.maximumStayPointGap else { break }
            let location = Self.location(for: point)
            guard !placeRecognitionService.hasExited(place,
                                                     location: location,
                                                     geofence: cachedGeofences[place.id]) else { break }
            arrival = point.timestamp
            laterTimestamp = point.timestamp
        }
        return arrival
    }

    private func closeRecoveredStay(_ stay: StayRecord, at departure: Date) {
        let safeDeparture = max(departure, stay.arrivalTime)
        stay.departureTime = safeDeparture
        stay.duration = safeDeparture.timeIntervalSince(stay.arrivalTime)
        if !placeRecognitionService.isConfirmedStay(from: stay.arrivalTime, to: safeDeparture) {
            modelContext?.delete(stay)
        }
    }

    private func finalizePendingStay(at departure: Date) {
        guard let pendingStay else { return }
        let safeDeparture = max(departure, pendingStay.arrivalTime)
        pendingStay.departureTime = safeDeparture
        pendingStay.duration = safeDeparture.timeIntervalSince(pendingStay.arrivalTime)
        if !placeRecognitionService.isConfirmedStay(from: pendingStay.arrivalTime,
                                                     to: safeDeparture) {
            modelContext?.delete(pendingStay)
        }
        self.pendingStay = nil
    }

    private func completeSuccessfulStop() {
        let context = modelContext
        activeSession = nil
        recordingState = .idle
        pendingStay = nil
        lastSavedLocation = nil
        lastDistanceLocation = nil
        pointsSinceLastAnalysis = 0
        manager.allowsBackgroundLocationUpdates = false
        resetPendingPersistenceState(at: .now)
        if let context {
            JourneyGenerationService.refresh(in: context)
        }
    }

    private func resetPendingPersistenceState(at date: Date) {
        unsavedTrackPointCount = 0
        hasPendingPersistenceChanges = false
        lastPersistenceDate = date
    }

    @discardableResult
    private func saveContext(operation: String,
                             critical: Bool = false,
                             failureRecovery: PersistenceFailureRecovery = .preserveChanges) -> Bool {
        guard let modelContext else {
            recordError("\(operation)失败：数据存储尚未准备好。", critical: critical)
            return false
        }
        return PersistenceService.save(modelContext,
                                       operation: operation,
                                       failureRecovery: failureRecovery) { [weak self] message in
            self?.recordError(message, critical: critical)
        }
    }

    private func recordError(_ message: String, critical: Bool) {
        lastError = message
        if critical { lastCriticalError = message }
        logger.error("\(message, privacy: .public)")
        DiagnosticsService.logEvent(message, category: critical ? "critical" : "location")
    }
}

extension LocationService: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        manager.allowsBackgroundLocationUpdates = activeSession != nil &&
            manager.authorizationStatus == .authorizedAlways

        if pendingAlwaysRequest, manager.authorizationStatus == .authorizedWhenInUse {
            pendingAlwaysRequest = false
            manager.requestAlwaysAuthorization()
        }

        if activeSession != nil {
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.startUpdatingLocation()
            case .denied, .restricted:
                manager.stopUpdatingLocation()
                recordError("定位权限已关闭，当前轨迹记录已暂停。请前往系统设置重新授权。", critical: true)
            case .notDetermined:
                break
            @unknown default:
                break
            }
        }
    }

    func locationManager(_ manager: CLLocationManager,
                         didUpdateLocations locations: [CLLocation]) {
        locations.forEach(process)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        recordError("定位失败：\(error.localizedDescription)", critical: false)
    }
}
