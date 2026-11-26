// The app entry point: one window running the Obsidian Glass Bento shell, wired to AppModel & BackupModel.
import SwiftUI

@main
struct MewtPhotosApp: App {
    @State private var model: AppModel
    @StateObject private var adapter: AppModelUIAdapter

    init() {
        let appModel = AppModel()
        _model = State(initialValue: appModel)
        _adapter = StateObject(wrappedValue: AppModelUIAdapter(model: appModel))
    }

    var body: some Scene {
        WindowGroup {
            MewtPhotosRedesignView(
                dataSource: adapter,
                scanner: { onScanned in
                    PairScanner { link in onScanned(link) }
                        .ignoresSafeArea()
                },
                diagnostics: {
                    DiagnosticsView(pairing: model)
                }
            )
            .preferredColorScheme(.dark)
            .task { await model.start() }
        }
    }
}
