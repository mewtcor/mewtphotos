// The app entry point: one window, and the model starts by restoring any saved pairing.
import SwiftUI

@main
struct PhotoSyncApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task { await model.start() }
        }
    }
}
