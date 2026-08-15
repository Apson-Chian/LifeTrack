import Foundation
import SwiftData

enum DataStoreOpenState {
    case ready(ModelContainer)
    case failed(message: String, storeName: String)
}

enum DataStoreManager {
    static let defaultStoreName = "LifeTrack"
    private static let activeStoreNameKey = "activeDataStoreName"

    static var activeStoreName: String {
        UserDefaults.standard.string(forKey: activeStoreNameKey) ?? defaultStoreName
    }

    static var activeStoreURL: URL {
        ModelConfiguration(activeStoreName,
                           schema: Schema(versionedSchema: LifeTrackSchemaV5.self),
                           cloudKitDatabase: .none).url
    }

    static func openActiveStore() -> DataStoreOpenState {
        let storeName = activeStoreName
        do {
            return .ready(try makeContainer(storeName: storeName))
        } catch {
            return .failed(message: String(reflecting: error), storeName: storeName)
        }
    }

    static func createRecoveryStore() throws -> ModelContainer {
        let name = "LifeTrack-Recovery-\(Int(Date.now.timeIntervalSince1970))"
        let container = try makeContainer(storeName: name)
        UserDefaults.standard.set(name, forKey: activeStoreNameKey)
        return container
    }

    private static func makeContainer(storeName: String) throws -> ModelContainer {
        let schema = Schema(versionedSchema: LifeTrackSchemaV5.self)
        let configuration = ModelConfiguration(storeName,
                                               schema: schema,
                                               cloudKitDatabase: .none)
        return try ModelContainer(for: schema,
                                  migrationPlan: LifeTrackMigrationPlan.self,
                                  configurations: [configuration])
    }
}
