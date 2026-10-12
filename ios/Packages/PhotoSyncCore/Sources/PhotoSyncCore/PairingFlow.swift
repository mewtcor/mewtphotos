// Pairing from typed text, remembering it, and classifying every half-paired state.
// Order matters: the key is saved first and the record second, so an interrupted pairing can leave
// a key without a record (harmless: unpaired) but never a record without a key that looks paired.
// Logs through RunLog only, and registers the code and the key with its scrubber before any line
// that could contain them.
import Foundation

public struct PairedInfo: Equatable, Sendable {
    public let serverName: String
    public let serverURL: String
    public let deviceId: String
    public let deviceName: String

    public init(serverName: String, serverURL: String, deviceId: String, deviceName: String) {
        self.serverName = serverName
        self.serverURL = serverURL
        self.deviceId = deviceId
        self.deviceName = deviceName
    }
}

public enum RepairReason: Equatable, Sendable {
    case keyMissing
    case recordUnreadable
    case keychainError(Int32)
    case keyRejected
}

public enum PairingState: Equatable, Sendable {
    case unpaired
    case paired(PairedInfo)
    case needsRepair(RepairReason)
}

public struct PairFailure: Error, Equatable, Sendable {
    /// Plain English, written for the person holding the phone.
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

public enum ConnectionCheck: Equatable, Sendable {
    case reachable(serverName: String)
    case unreachable(String)
    case keyRejected
}

/// What is stored right now, as short words for the launch evidence line.
public struct StorageStates: Equatable, Sendable {
    /// `found`, `not_found` or `error(N)`.
    public let key: String
    /// `none`, `present` or `corrupt`.
    public let record: String

    public init(key: String, record: String) {
        self.key = key
        self.record = record
    }
}

public actor PairingFlow {
    private static let notConnectedToInternet = -1009
    private static let urlErrorDomain = "NSURLErrorDomain"

    private let store: PairingStore
    private let keys: any DeviceKeyStoring
    private let transport: any HTTPTransport
    private let log: RunLog
    private let deviceName: String
    private let retryDelayNanoseconds: UInt64

    public init(store: PairingStore, keys: any DeviceKeyStoring, transport: any HTTPTransport, log: RunLog,
                deviceName: String, retryDelayNanoseconds: UInt64 = 1_500_000_000) {
        self.store = store
        self.keys = keys
        self.transport = transport
        self.log = log
        self.deviceName = deviceName
        self.retryDelayNanoseconds = retryDelayNanoseconds
    }

    // ---- restore ----

    public func restore() async -> PairingState {
        let loaded = store.load()
        let keyResult = keys.load()
        if case .found(let key) = keyResult {
            await log.register(secret: key.revealForAuthorization())
        }
        if case .failed(let status) = keyResult {
            await log.append(.error, code: "restore_keychain_error", "key lookup failed, status \(status)")
            return .needsRepair(.keychainError(status))
        }
        switch (loaded, keyResult) {
        case (.corrupt, _):
            await log.append(.error, code: "restore_record_unreadable", "pairing record is unreadable or foreign")
            return .needsRepair(.recordUnreadable)
        case (.none, .found):
            await log.append(.warn, code: "restore_orphan_key", "a device key exists without a pairing record; treating as unpaired")
            return .unpaired
        case (.none, _):
            await log.append(.info, code: "restore_unpaired", "no pairing stored")
            return .unpaired
        case (.record(let record), .found):
            await log.append(.info, code: "restore_paired", "paired with \(record.serverURL)")
            return .paired(Self.info(record))
        case (.record, _):
            await log.append(.warn, code: "restore_key_missing", "pairing record found but the device key is missing")
            return .needsRepair(.keyMissing)
        }
    }

    // ---- pair ----

    public func pair(addressText: String, codeText: String) async -> Result<PairedInfo, PairFailure> {
        let address: ServerAddress
        switch ServerAddress.parse(addressText) {
        case .failure(let error):
            // The error kind only: the typed text may be a QR link that holds the pairing code.
            await log.append(.warn, code: "pair_rejected_input", "address rejected: \(error)")
            return .failure(PairFailure(message: error.userMessage))
        case .success(let parsed):
            address = parsed
        }

        let typedCode = codeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = typedCode.isEmpty ? (address.pairingCode ?? "") : typedCode
        guard !code.isEmpty else {
            await log.append(.warn, code: "pair_rejected_input", "no pairing code given")
            return .failure(PairFailure(message: "Enter the pairing code shown on the PC dashboard."))
        }
        await log.register(secret: code)
        await log.register(secret: code.uppercased())
        await log.append(.info, code: "pair_start", "pairing with \(address.host) port \(address.port)")

        let client = ServerClient(base: address.baseURL, transport: transport)
        let paired: PairResult
        do {
            paired = try await requestPairing(client, code: code)
        } catch {
            return .failure(await failure(for: error, networkCode: "pair_network", otherCode: "pair_server_error"))
        }

        // Key first. If it cannot be saved there is no record, and the code is already spent.
        await log.register(secret: paired.key.revealForAuthorization())
        if case .failed(let status) = keys.save(paired.key) {
            await log.append(.error, code: "key_save_failed", "saving the device key failed, status \(status)")
            return .failure(PairFailure(message:
                "The PC accepted the code but this iPhone could not store the key. Pair again with a fresh code from the PC dashboard."))
        }

        var serverName = address.display
        if let status = try? await client.status(key: paired.key), !status.serverName.isEmpty {
            serverName = status.serverName
        }
        let record = PairingRecord(
            serverURL: address.baseURL.absoluteString, deviceId: paired.deviceId,
            deviceName: ServerClient.clampedName(deviceName), serverName: serverName,
            pairedAtEpoch: Int(Date().timeIntervalSince1970))
        do {
            try store.save(record)
        } catch {
            // Roll back so no key is left behind that the app cannot find a PC for.
            _ = keys.delete()
            await log.append(.error, code: "record_save_failed", "saving the pairing record failed; the key was removed")
            return .failure(PairFailure(message:
                "Pairing worked but this iPhone could not save it. Pair again with a fresh code from the PC dashboard."))
        }
        await log.append(.info, code: "paired", "paired with \(address.display)")
        return .success(Self.info(record))
    }

    // ---- connection ----

    // ---- upload test ----

    /// Sends one file through the backup's own routes and returns the timing. Only the result reaches the
    /// log; the key and the file's bytes never do.
    public func uploadTest(filename: String, mimeType: String, size: Int64, sha256: String,
                           readChunk: @Sendable (Int64, Int) throws -> Data) async -> Result<UploadOutcome, PairFailure> {
        guard case .record(let record) = store.load(), let address = record.validAddress else {
            return .failure(PairFailure(message: "This iPhone is not paired with a PC yet."))
        }
        guard case .found(let key) = keys.load() else {
            return .failure(PairFailure(message: "The key for this PC is missing. Pair again with a fresh code."))
        }
        await log.register(secret: key.revealForAuthorization())
        let client = ServerClient(base: address.baseURL, transport: transport)
        let chunkBytes = 8 * 1024 * 1024 // matches CHUNK_SIZE on the server
        do {
            let outcome = try await client.uploadFile(key: key, filename: filename, mimeType: mimeType, size: size,
                                                      sha256: sha256, chunkBytes: chunkBytes, readChunk: readChunk)
            let speed = outcome.mibPerSecond.map { String(format: "%.2f MiB/s", $0) } ?? "no speed (zero time)"
            await log.append(.info, code: "upload_test", "sent \(outcome.sentBytes) bytes in \(outcome.seconds) s, \(speed), chunks of \(chunkBytes) bytes; server status \(outcome.status)")
            return .success(outcome)
        } catch {
            return .failure(await failure(for: error, networkCode: "upload_test_failed", otherCode: "upload_test_failed"))
        }
    }

    public func checkConnection() async -> ConnectionCheck {
        guard case .record(let record) = store.load(), let address = record.validAddress else {
            await log.append(.warn, code: "connection_failed", "no usable pairing record")
            return .unreachable("This iPhone is not paired with a PC yet.")
        }
        guard case .found(let key) = keys.load() else {
            await log.append(.warn, code: "connection_failed", "no device key available")
            return .unreachable("The key for this PC is missing. Pair again with a fresh code.")
        }
        await log.register(secret: key.revealForAuthorization())
        let client = ServerClient(base: address.baseURL, transport: transport)
        do {
            let status = try await client.status(key: key)
            await log.append(.info, code: "connection_ok", "server \(address.display) answered")
            return .reachable(serverName: status.serverName)
        } catch ServerClientError.server(let status, _, _) where status == 401 {
            await log.append(.error, code: "key_rejected", "the server rejected the device key (401)")
            return .keyRejected
        } catch {
            let failed = await failure(for: error, networkCode: "connection_failed", otherCode: "connection_failed")
            return .unreachable(failed.message)
        }
    }

    public func storageStates() -> StorageStates {
        let keyState: String
        switch keys.load() {
        case .found: keyState = "found"
        case .notFound: keyState = "not_found"
        case .failed(let status): keyState = "error(\(status))"
        }
        let recordState: String
        switch store.load() {
        case .none: recordState = "none"
        case .record: recordState = "present"
        case .corrupt: recordState = "corrupt"
        }
        return StorageStates(key: keyState, record: recordState)
    }

    // ---- helpers ----

    /// One retry, and only for -1009: the first request after install can fail while iOS shows the
    /// Local Network prompt. Any other network error may have reached the PC and spent the code.
    private func requestPairing(_ client: ServerClient, code: String) async throws -> PairResult {
        do {
            return try await client.pair(code: code, deviceName: deviceName)
        } catch ServerClientError.network(let failure)
                    where failure.domain == Self.urlErrorDomain && failure.code == Self.notConnectedToInternet {
            await log.append(.warn, code: "pair_retry", "first request failed with \(failure.code); retrying once")
            try? await Task.sleep(nanoseconds: retryDelayNanoseconds)
            return try await client.pair(code: code, deviceName: deviceName)
        }
    }

    /// Plain-English failure for the screen, and one log line. Pairing and later connection checks
    /// log under different event codes.
    private func failure(for error: any Error, networkCode: String, otherCode: String) async -> PairFailure {
        switch error as? ServerClientError {
        case .server(let status, let serverCode, let message):
            await log.append(.warn, code: otherCode, "server answered \(status) \(serverCode)")
            return PairFailure(message: message)
        case .network(let failure):
            await log.append(.warn, code: networkCode,
                             "domain \(failure.domain) code \(failure.code) underlying \(failure.underlyingCode.map { String($0) } ?? "none")")
            return PairFailure(message:
                "Could not reach your PC. Check that the iPhone is on the same Wi-Fi as the PC and that the PhotoSync PC app is running. If iOS asked about Local Network access, tap Allow.")
        case .unexpectedResponse(let message), .invalidInput(let message):
            await log.append(.warn, code: otherCode, "unexpected: \(message)")
            return PairFailure(message: message)
        case nil:
            await log.append(.error, code: otherCode, "unexpected error type")
            return PairFailure(message: "Something unexpected went wrong. Try again.")
        }
    }

    private static func info(_ record: PairingRecord) -> PairedInfo {
        PairedInfo(serverName: record.serverName, serverURL: record.serverURL,
                   deviceId: record.deviceId, deviceName: record.deviceName)
    }
}
