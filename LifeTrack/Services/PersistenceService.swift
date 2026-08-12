import Foundation
import OSLog
import SwiftData

enum PersistenceService {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LifeTrack",
                                       category: "Persistence")

    @discardableResult
    static func save(_ context: ModelContext,
                     operation: String,
                     onError: ((String) -> Void)? = nil) -> Bool {
        do {
            try context.save()
            return true
        } catch {
            let message = "\(operation)失败：\(error.localizedDescription)"
            logger.error("\(operation, privacy: .public) failed: \(String(reflecting: error), privacy: .public)")
            onError?(message)
            return false
        }
    }
}
