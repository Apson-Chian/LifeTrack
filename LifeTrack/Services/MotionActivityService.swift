import CoreMotion

final class MotionActivityService: ObservableObject {
    private let manager = CMMotionActivityManager()
    @Published private(set) var currentActivity: ActivityType = .unknown
    @Published private(set) var isAvailable = CMMotionActivityManager.isActivityAvailable()

    func startUpdates(_ handler: @escaping (ActivityType, CMMotionActivityConfidence) -> Void) {
        guard isAvailable else { return }
        manager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let activity else { return }
            let type: ActivityType
            if activity.stationary { type = .stationary }
            else if activity.walking { type = .walking }
            else if activity.running { type = .running }
            else if activity.cycling { type = .cycling }
            else if activity.automotive { type = .automotive }
            else { type = .unknown }
            self?.currentActivity = type
            handler(type, activity.confidence)
        }
    }

    func stopUpdates() { manager.stopActivityUpdates() }
}
