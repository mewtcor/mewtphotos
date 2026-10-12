// The app entry point: one window, and the model starts by restoring any saved pairing.
import SwiftUI

@main
struct PhotoSyncApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.retryPendingFinish() } }
                }
        }
    }
}
