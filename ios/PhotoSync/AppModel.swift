// App wiring and the state the pairing form shows. The session flags live here and nowhere in Core,
// so Core stays testable on Linux.
import Foundation
import Observation
import UIKit
import PhotoSyncCore

struct AppEnvironment {
    let flow: PairingFlow
    let log: RunLog
    /// Application Support: pairing.json and launch-count. Files does not show this folder.
    let supportDirectory: URL

    /// Documents holds only the run log, so Files can show it.
    static func make() throws -> AppEnvironment {
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
        let log = RunLog(directory: documents)
        let flow = PairingFlow(
            store: PairingStore(directory: support),
            keys: KeychainDeviceKeyStore(),
            transport: URLSessionTransport(session: URLSession(configuration: configuration)),
            log: log,
            deviceName: "PhotoSync app on " + UIDevice.current.name
        )
        return AppEnvironment(flow: flow, log: log, supportDirectory: support)
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
    /// Set after the launch connection check; nil until it has run.
    var connectionText: String?

    private let environment: AppEnvironment?

    init() {
        do {
            environment = try AppEnvironment.make()
        } catch {
            environment = nil
            errorText = "PhotoSync could not open its storage on this phone. Restart the phone and try again."
        }
    }

    var logURL: URL? { environment?.log.fileURL }

    var statusText: String {
        if let connectionText { return connectionText }
        switch state {
        case .unpaired:
            return "Not paired yet"
        case .paired(let info):
            return "Paired with \(info.serverName)"
        case .needsRepair(let reason):
            return Self.repairText(reason)
        }
    }

    var versionText: String { Self.bundleValue("CFBundleShortVersionString") }
    var buildText: String { Self.bundleValue("CFBundleVersion") }
    var gitSHAText: String { Self.bundleValue("PhotoSyncGitSHA") }

    /// Restores the pairing, writes one launch line to the log, and when paired checks the PC.
    func start() async {
        guard let environment else { return }
        let launch = (try? LaunchCounter.next(in: environment.supportDirectory)) ?? 0
        state = await environment.flow.restore()
        let stored = await environment.flow.storageStates()
        let facts = LaunchFacts(
            launch: launch, version: versionText, build: buildText, gitSHA: gitSHAText,
            bundleID: Bundle.main.bundleIdentifier ?? "-",
            altBundleID: Bundle.main.object(forInfoDictionaryKey: "ALTBundleIdentifier") as? String,
            keychain: stored.key, pairing: stored.record)
        await environment.log.append(.info, code: "launch", facts.logLine)
        guard case .paired = state else { return }
        connectionText = Self.connectionText(await environment.flow.checkConnection())
    }

    func pair() async {
        guard let environment, !isBusy else { return }
        isBusy = true
        errorText = nil
        let result = await environment.flow.pair(addressText: addressText, codeText: codeText)
        isBusy = false
        // The code is single-use, so it is cleared after every attempt.
        codeText = ""
        switch result {
        case .success(let info):
            connectionText = nil
            state = .paired(info)
        case .failure(let failure):
            errorText = failure.message
        }
    }

    /// Sends one file on disk through the paired PC, reading it back in chunks. Used by the speed test.
    func uploadTest(file: URL, filename: String, mimeType: String, size: Int64, sha256: String) async -> Result<UploadOutcome, PairFailure> {
        guard let environment else {
            return .failure(PairFailure(message: "PhotoSync could not open its storage on this phone."))
        }
        return await environment.flow.uploadTest(filename: filename, mimeType: mimeType, size: size, sha256: sha256) { offset, length in
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: length) ?? Data()
        }
    }

    private static func bundleValue(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "-"
    }

    private static func connectionText(_ check: ConnectionCheck) -> String {
        switch check {
        case .reachable(let serverName):
            return "Connected to " + serverName
        case .unreachable(let message):
            return "Cannot reach your PC right now. " + message
        case .keyRejected:
            return keyRejectedText
        }
    }

    private static func repairText(_ reason: RepairReason) -> String {
        switch reason {
        case .keyMissing:
            return "This iPhone lost its pairing key. Pair again with a new code from the PC."
        case .recordUnreadable:
            return "The saved pairing could not be read. Pair again."
        case .keychainError(let status):
            return "The iPhone key store returned error \(status). Pair again, and export the log if it repeats."
        case .keyRejected:
            return keyRejectedText
        }
    }

    private static let keyRejectedText = "The PC no longer accepts this iPhone. Pair again with a new code from the PC."
}
