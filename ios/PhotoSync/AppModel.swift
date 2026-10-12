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

    /// Sends a file on disk to the paired PC in the background, so it keeps going while the screen is locked.
    /// `done` gets the result text when the transfer ends, if the app is still running then.
    func startBackgroundUpload(file: URL, filename: String, mimeType: String, size: Int64, sha256: String,
                               done: @escaping @MainActor (String) -> Void) async {
        guard let environment, let connection = await environment.flow.pairedConnection() else {
            done("This iPhone is not paired with a PC yet.")
            return
        }
        let started = ContinuousClock.now
        do {
            let begun = try await connection.client.beginUpload(key: connection.key, filename: filename, mimeType: mimeType,
                                                                size: size, sha256: sha256)
            if begun.alreadyStored {
                done("Already backed up on the PC. Nothing was sent.")
                return
            }
            guard begun.offset < size else {
                // The PC already has every byte from an earlier, interrupted transfer; only the finish is left.
                done(await finishText(connection, uploadId: begun.uploadId, sha256: sha256))
                return
            }
            let source = begun.offset == 0 ? file : try BackgroundUploader.tail(of: file, from: begun.offset)
            var request = URLRequest(url: connection.base.appendingPathComponent("api/v1/uploads/\(begun.uploadId)"))
            request.httpMethod = "PATCH"
            request.setValue("Bearer \(connection.key.revealForAuthorization())", forHTTPHeaderField: "Authorization")
            request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(String(begun.offset), forHTTPHeaderField: "Upload-Offset")
            BackgroundUploader.shared.send(request, fromFile: source) { status, _ in
                Task { @MainActor in
                    guard let status, (200..<300).contains(status) else {
                        done("The upload stopped before the PC had all of it. Tap upload again to resume.")
                        return
                    }
                    let elapsed = Self.seconds(since: started)
                    let sent = size - begun.offset
                    let speed = TransferSpeed.mibPerSecond(bytes: sent, seconds: elapsed).map { String(format: "%.2f MiB/s", $0) } ?? "no speed"
                    let finish = await self.finishText(connection, uploadId: begun.uploadId, sha256: sha256)
                    done(finish + " Sent \(sent) bytes in \(String(format: "%.1f", elapsed)) s, \(speed).")
                }
            }
        } catch {
            done("Upload failed. Check that the iPhone is on the same Wi-Fi as the PC, then tap upload again.")
        }
    }

    /// Finishes an upload. If the answer is lost, the upload is kept for `retryPendingFinish`.
    private func finishText(_ connection: PairedConnection, uploadId: String, sha256: String) async -> String {
        do {
            let result = try await connection.client.finishUpload(key: connection.key, uploadId: uploadId, sha256: sha256)
            return "Server status: \(result.status). Verified end to end: \(result.endToEndVerified ? "yes" : "no")."
        } catch {
            if let directory = environment?.supportDirectory {
                PendingFinish(uploadId: uploadId, sha256: sha256).save(in: directory)
            }
            return "The PC has not confirmed the file yet. It will be finished the next time PhotoSync opens."
        }
    }

    /// Finishes an upload whose last step was lost, for example because the app was in the background.
    /// Runs each time the app becomes active.
    func retryPendingFinish() async {
        guard let environment, let pending = PendingFinish.load(in: environment.supportDirectory),
              let connection = await environment.flow.pairedConnection() else { return }
        do {
            let result = try await connection.client.finishUpload(key: connection.key, uploadId: pending.uploadId, sha256: pending.sha256)
            PendingFinish.clear(in: environment.supportDirectory)
            await environment.log.append(.info, code: "upload_finished", "finished a pending upload; server status \(result.status)")
        } catch {
            // Kept on disk: the next time the app becomes active tries again.
        }
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let parts = start.duration(to: .now).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
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
