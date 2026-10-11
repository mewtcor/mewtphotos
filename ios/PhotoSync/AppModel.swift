// App wiring and the state the pairing form shows. The session flags live here and nowhere in Core,
// so Core stays testable on Linux.
import Foundation
import Observation
import UIKit
import PhotoSyncCore

enum AppEnvironment {
    /// Documents holds only the run log, so Files can show it. pairing.json lives in Application
    /// Support, where it is not exposed.
    static func makeFlow() throws -> PairingFlow {
        let fileManager = FileManager.default
        let documents = try fileManager.url(for: .documentDirectory, in: .userDomainMask,
                                            appropriateFor: nil, create: true)
        let support = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                          appropriateFor: nil, create: true)
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpMaximumConnectionsPerHost = 1
        return PairingFlow(
            store: PairingStore(directory: support),
            keys: KeychainDeviceKeyStore(),
            transport: URLSessionTransport(session: URLSession(configuration: configuration)),
            log: RunLog(directory: documents),
            deviceName: "PhotoSync app on " + UIDevice.current.name
        )
    }
}

@MainActor
@Observable
final class AppModel {
    var addressText = ""
    var codeText = ""
    var isBusy = false
    var errorText: String?
    var state: PairingState = .unpaired

    private let flow: PairingFlow?

    init() {
        do {
            flow = try AppEnvironment.makeFlow()
        } catch {
            flow = nil
            errorText = "PhotoSync could not open its storage on this phone. Restart the phone and try again."
        }
    }

    func start() async {
        guard let flow else { return }
        state = await flow.restore()
    }

    func pair() async {
        guard let flow, !isBusy else { return }
        isBusy = true
        errorText = nil
        let result = await flow.pair(addressText: addressText, codeText: codeText)
        isBusy = false
        // The code is single-use, so it is cleared after every attempt.
        codeText = ""
        switch result {
        case .success(let info):
            state = .paired(info)
        case .failure(let failure):
            errorText = failure.message
        }
    }
}
