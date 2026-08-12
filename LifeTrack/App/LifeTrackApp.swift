import SwiftUI
import SwiftData

@main
struct LifeTrackApp: App {
    @State private var storeState = DataStoreManager.openActiveStore()

    var body: some Scene {
        WindowGroup {
            storeContent
        }
    }

    @ViewBuilder
    private var storeContent: some View {
        switch storeState {
        case .ready(let container):
            RootView()
                .modelContainer(container)
        case .failed(let message, let storeName):
            DataStoreRecoveryView(errorMessage: message,
                                  storeName: storeName,
                                  retry: retryOpeningStore,
                                  createEmptyStore: createEmptyStore)
        }
    }

    private func retryOpeningStore() {
        storeState = DataStoreManager.openActiveStore()
    }

    private func createEmptyStore() {
        do {
            storeState = .ready(try DataStoreManager.createRecoveryStore())
        } catch {
            storeState = .failed(message: String(reflecting: error),
                                 storeName: DataStoreManager.activeStoreName)
        }
    }
}
