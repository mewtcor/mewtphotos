// The app entry point: registers the BGProcessingTask handler before launch finishes,
// then mounts the Obsidian Glass Bento shell wired to AppModel & BackupModel.
import SwiftUI
import UIKit

final class MewtAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundSyncScheduler.shared.registerHandler()
        return true
    }
}

@main
struct MewtPhotosApp: App {
    @UIApplicationDelegateAdaptor(MewtAppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @StateObject private var adapter: AppModelUIAdapter

    init() {
        let appModel = AppModel()
        BackgroundSyncScheduler.shared.attach(model: appModel)
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
