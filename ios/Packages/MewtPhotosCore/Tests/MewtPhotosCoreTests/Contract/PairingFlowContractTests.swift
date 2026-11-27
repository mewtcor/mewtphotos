// PairingFlow against the real, unmodified server. These are methods on ServerContractTests (not a
// second suite) so they run in its serialized order: the server rotates its pairing code after every
// pairing, and parallel suites would race for it. The wrong-code request budget is spent in
// ServerContractTests; wrong-code mapping is covered with a fake transport in PairingFlowTests.
import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MewtPhotosCore

private func makeFlow(directory: URL, keys: InMemoryDeviceKeyStore, deviceName: String) -> (PairingFlow, RunLog) {
    let log = RunLog(directory: directory)
    let flow = PairingFlow(
        store: PairingStore(directory: directory), keys: keys,
        transport: URLSessionTransport(session: .shared), log: log, deviceName: deviceName)
    return (flow, log)
}

private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ps-flow-\(UUID().uuidString)")
}

private func textOfEveryFile(under directory: URL) -> String {
    var all = ""
    let names = (try? FileManager.default.subpathsOfDirectory(atPath: directory.path)) ?? []
    for name in names {
        let url = directory.appendingPathComponent(name)
        if let data = try? Data(contentsOf: url) {
            all += String(decoding: data, as: UTF8.self)
        }
    }
    return all
}

extension ServerContractTests {
    // The QR form with an empty code field, then a simulated relaunch over the same storage.
    @Test func qrLinkPairsRestoresAndConfirmsWithThePersistedKey() async throws {
        let base = try contractBase()
        let host = try #require(base.host)
        let port = try #require(base.port)
        let code = try await freshPairingCode(base: base)
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = InMemoryDeviceKeyStore()

        let (first, firstLog) = makeFlow(directory: directory, keys: keys, deviceName: "Contract Flow")
        let paired = try await first.pair(addressText: "http://\(host):\(port)/#pair=\(code)", codeText: "").get()
        #expect(!paired.serverName.isEmpty)

        // A brand-new flow and log over the same directory and key store: what a relaunch sees.
        let (second, secondLog) = makeFlow(directory: directory, keys: keys, deviceName: "Contract Flow")
        let restored = await second.restore()
        #expect(restored == .paired(paired))
        let connection = await second.checkConnection()
        #expect(connection == .reachable(serverName: paired.serverName))

        guard case .found(let key) = keys.load() else {
            Issue.record("the key store holds no key after pairing")
            return
        }
        let token = key.revealForAuthorization()
        let firstSnapshot = await firstLog.snapshot()
        let secondSnapshot = await secondLog.snapshot()
        let recordText = String(decoding: try Data(contentsOf: directory.appendingPathComponent("pairing.json")), as: UTF8.self)
        #expect(firstSnapshot.contains(" paired "), "the log recorded nothing, so the secret checks below would prove nothing")
        #expect(secondSnapshot.contains(" connection_ok "))

        let everywhere = [
            ("first log", firstSnapshot), ("second log", secondSnapshot),
            ("pairing.json", recordText), ("all files", textOfEveryFile(under: directory)),
        ]
        for (name, text) in everywhere {
            #expect(!text.contains(token), "the device key leaked into \(name)")
            #expect(!text.contains(code), "the pairing code leaked into \(name)")
        }
    }

    // Separate address and code fields, the code in lower case: the server's normalisation stays its own.
    @Test func separateFieldsWithALowerCaseCodePair() async throws {
        let base = try contractBase()
        let host = try #require(base.host)
        let port = try #require(base.port)
        let code = try await freshPairingCode(base: base)
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let (flow, _) = makeFlow(directory: directory, keys: InMemoryDeviceKeyStore(), deviceName: "Contract Flow B")
        let paired = try await flow.pair(addressText: "\(host):\(port)", codeText: code.lowercased()).get()
        #expect(!paired.deviceId.isEmpty)
    }
}
