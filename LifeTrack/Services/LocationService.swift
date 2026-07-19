import CoreLocation
import CoreMotion
import SwiftData

final class LocationService: NSObject, ObservableObject {
    static let shared = LocationService()

    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var currentLocation: CLLocation?
    @Published private(set) var currentActivity: ActivityType = .unknown
    @Published private(set) var activeSession: ActivitySession?
    @Published private(set) var lastError: String?
    @Published var recordingPreference: RecordingPreference = .smart {
        didSet { applySamplingPolicy() }
    }

    private let manager = CLLocationManager()
    private let motionService = MotionActivityService()
    private weak var modelContext: ModelContext?
    private var lastSavedLocation: CLLocation?
    private var lastActivityChange = Date.distantPast
    private var currentMotionConfidence: CMMotionActivityConfidence = .low
    private let placeRecognitionService = PlaceRecognitionService()
    private var pendingStay: StayRecord?

    private override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = true
    }

    func configure(with context: ModelContext) {
        modelContext = context
        recordingPreference = RecordingPreference(rawValue: UserDefaults.standard.string(forKey: "recordingPreference") ?? "smart") ?? .smart
    }

    func requestAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
    }

    func startRecording(manualActivity: ActivityType? = nil) {
        guard let modelContext else {
            lastError = "数据存储尚未准备好。"
            return
        }
        guard manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse else {
            lastError = "开始记录前需要先允许定位访问。"
            requestAuthorization()
            return
        }
        guard activeSession == nil else { return }

        let session = ActivitySession(activityType: manualActivity ?? currentActivity, source: manualActivity == nil ? "automatic" : "manual")
        session.manualActivityType = manualActivity
        modelContext.insert(session)
        try? modelContext.save()
        activeSession = session
        lastSavedLocation = nil
        applySamplingPolicy()
        manager.allowsBackgroundLocationUpdates = manager.authorizationStatus == .authorizedAlways
        manager.startUpdatingLocation()
        motionService.startUpdates { [weak self] activity, confidence in
            self?.handleMotion(activity, confidence: confidence)
        }
    }

    func restore(session: ActivitySession) {
        activeSession = session
        lastSavedLocation = session.trackPoints.sorted(by: { $0.timestamp < $1.timestamp }).last.map(Self.location(for:))
        currentActivity = session.manualActivityType ?? session.activityType
        applySamplingPolicy()
        manager.startUpdatingLocation()
        motionService.startUpdates { [weak self] activity, confidence in
            self?.handleMotion(activity, confidence: confidence)
        }
    }

    func stopRecording() {
        guard let session = activeSession else { return }
        manager.stopUpdatingLocation()
        motionService.stopUpdates()
        session.endTime = .now
        session.duration = session.endTime?.timeIntervalSince(session.startTime) ?? 0
        session.isActive = false
        finalizePendingStay(at: session.endTime ?? .now)
        try? modelContext?.save()
        activeSession = nil
        lastSavedLocation = nil
    }

    func setManualActivity(_ activity: ActivityType?) {
        guard let session = activeSession else { return }
        session.manualActivityType = activity
        if let activity { currentActivity = activity }
        session.activityType = currentActivity
        applySamplingPolicy()
        try? modelContext?.save()
    }

    func savePreference() {
        UserDefaults.standard.set(recordingPreference.rawValue, forKey: "recordingPreference")
        applySamplingPolicy()
    }

    private func handleMotion(_ motionActivity: ActivityType, confidence: CMMotionActivityConfidence) {
        currentMotionConfidence = confidence
        guard activeSession != nil, activeSession?.manualActivityType == nil else { return }
        // Require a confident, sustained change to prevent low-speed driving or GPS noise from flipping modes.
        guard confidence != .low, motionActivity != currentActivity, Date.now.timeIntervalSince(lastActivityChange) > 20 else { return }
        currentActivity = motionActivity
        activeSession?.activityType = motionActivity
        lastActivityChange = .now
        applySamplingPolicy()
    }

    private func applySamplingPolicy() {
        let policy = SamplingPolicy.policy(for: activeSession?.manualActivityType ?? currentActivity, preference: recordingPreference)
        manager.desiredAccuracy = policy.desiredAccuracy
        manager.distanceFilter = policy.distanceFilter
    }

    private func process(_ location: CLLocation) {
        currentLocation = location
        guard let session = activeSession, isValid(location) else { return }
        let activity = session.manualActivityType ?? inferredActivity(for: location)
        let policy = SamplingPolicy.policy(for: activity, preference: recordingPreference)
        guard shouldSave(location, after: lastSavedLocation, policy: policy) else { return }

        if let previous = lastSavedLocation {
            let delta = location.distance(from: previous)
            session.distance += delta
        }
        session.duration = location.timestamp.timeIntervalSince(session.startTime)
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
        updatePlaceRecognition(for: location, session: session)
        try? modelContext?.save()
    }

    private func inferredActivity(for location: CLLocation) -> ActivityType {
        if activeSession?.manualActivityType != nil { return activeSession?.manualActivityType ?? .unknown }
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

    private func shouldSave(_ location: CLLocation, after previous: CLLocation?, policy: SamplingPolicy) -> Bool {
        guard location.horizontalAccuracy <= policy.minimumAccuracy else { return false }
        guard let previous else { return true }
        let time = location.timestamp.timeIntervalSince(previous.timestamp)
        guard time > 0 else { return false }
        let distance = location.distance(from: previous)
        // Reject teleport-like points. This also prevents a single bad fix inflating total distance.
        guard distance / time < 55 else { return false }
        return time >= policy.minimumInterval || distance >= policy.distanceFilter
    }

    private static func location(for point: TrackPoint) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                   altitude: point.altitude,
                   horizontalAccuracy: point.horizontalAccuracy,
                   verticalAccuracy: -1,
                   course: point.course,
                   speed: point.speed,
                   timestamp: point.timestamp)
    }

    private func updatePlaceRecognition(for location: CLLocation, session: ActivitySession) {
        guard let modelContext else { return }
        let places = (try? modelContext.fetch(FetchDescriptor<CustomPlace>())) ?? []
        let matchingPlace = placeRecognitionService.matchingPlace(for: location, places: places)

        if let pendingStay,
           let currentPlace = places.first(where: { $0.id == pendingStay.customPlaceID }),
           !placeRecognitionService.hasExited(currentPlace, location: location) {
            pendingStay.duration = location.timestamp.timeIntervalSince(pendingStay.arrivalTime)
            return
        }

        finalizePendingStay(at: location.timestamp)
        guard let matchingPlace else { return }
        let stay = StayRecord(customPlaceID: matchingPlace.id,
                              detectedName: matchingPlace.shortName,
                              latitude: matchingPlace.latitude,
                              longitude: matchingPlace.longitude,
                              arrivalTime: location.timestamp,
                              session: session)
        modelContext.insert(stay)
        pendingStay = stay
    }

    private func finalizePendingStay(at departure: Date) {
        guard let pendingStay else { return }
        pendingStay.departureTime = departure
        pendingStay.duration = departure.timeIntervalSince(pendingStay.arrivalTime)
        // A short pass-through remains in the raw location history but is not a visit.
        if !placeRecognitionService.isConfirmedStay(from: pendingStay.arrivalTime, to: departure) {
            modelContext?.delete(pendingStay)
        }
        self.pendingStay = nil
    }
}

extension LocationService: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        locations.forEach(process)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        lastError = error.localizedDescription
    }
}
