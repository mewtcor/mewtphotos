// Contract tests: Core against the real, unmodified PhotoSync server (started by ci.yml). They fail,
// never skip, when no server is configured. This is the ONLY contract suite: it is serialized because
// the server rotates its pairing code after every successful pairing, and separate suites run in
// parallel and would race for it. Later plans add tests through an extension of this type.
// The server throttles wrong pairing codes (8 per 5 minutes per address): the whole run sends one.
import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PhotoSyncCore

enum ContractSetupError: Error {
    case urlMissing
    case adminStatus(Int)
}

private struct PairingInfo: Decodable {
    let code: String
}

/// The server under test. A missing URL is a failure on every machine, so a misconfigured CI run
/// cannot pass by running nothing.
func contractBase() throws -> URL {
    guard let text = ProcessInfo.processInfo.environment["PHOTOSYNC_CONTRACT_URL"],
          let url = URL(string: text) else {
        Issue.record("PHOTOSYNC_CONTRACT_URL is not set; the contract tests need a running PhotoSync server.")
        throw ContractSetupError.urlMissing
    }
    return url
}

/// Reads the current pairing code from the server's loopback-only dashboard endpoint. Test code
/// only: Core never calls it. Every test that pairs fetches its own code.
func freshPairingCode(base: URL) async throws -> String {
    let transport = URLSessionTransport(session: .shared)
    let response = try await transport.send(
        HTTPRequest(method: "GET", url: base.appendingPathComponent("api/v1/admin/pairing")))
    guard response.status == 200 else { throw ContractSetupError.adminStatus(response.status) }
    return try JSONDecoder().decode(PairingInfo.self, from: response.body).code
}

@Suite(.serialized)
struct ServerContractTests {
    private func makeClient() throws -> (ServerClient, URL) {
        let base = try contractBase()
        return (ServerClient(base: base, transport: URLSessionTransport(session: .shared)), base)
    }

    @Test func healthIdentifiesPhotoSync() async throws {
        let (client, _) = try makeClient()
        let health = try await client.health()
        #expect(health.ok)
        #expect(health.name == "photosync")
        #expect(health.apiVersion == 1)
    }

    @Test func pairThenStatusWithTheIssuedKey() async throws {
        let (client, base) = try makeClient()
        let code = try await freshPairingCode(base: base)
        let paired = try await client.pair(code: code, deviceName: "Contract Test")
        #expect(!paired.deviceId.isEmpty)
        let status = try await client.status(key: paired.key)
        #expect(status.chunkSize == 8388608)
        #expect(!status.serverName.isEmpty)
        #expect(status.deviceName == "Contract Test")
    }

    // The only wrong-code request in the whole contract tree.
    @Test func wrongPairingCodeIsRefused() async throws {
        let (client, _) = try makeClient()
        do {
            _ = try await client.pair(code: "ZZZZZZZZ", deviceName: "Contract Test")
            Issue.record("a wrong pairing code was accepted")
        } catch ServerClientError.server(let status, let code, _) {
            #expect(status == 403)
            #expect(code == "bad_pairing_code")
        } catch {
            Issue.record("expected a server error, got \(error)")
        }
    }

    @Test func unknownKeyIsUnauthorized() async throws {
        let (client, _) = try makeClient()
        do {
            _ = try await client.status(key: DeviceKey("not-a-real-key"))
            Issue.record("an unknown key was accepted")
        } catch ServerClientError.server(let status, let code, _) {
            #expect(status == 401)
            #expect(code == "unauthorized")
        } catch {
            Issue.record("expected a server error, got \(error)")
        }
    }

    @Test func closedPortIsANetworkError() async throws {
        let client = ServerClient(base: URL(string: "http://127.0.0.1:1")!, transport: URLSessionTransport(session: .shared))
        do {
            _ = try await client.health()
            Issue.record("a closed port answered")
        } catch ServerClientError.network(let failure) {
            #expect(failure.domain == "NSURLErrorDomain")
        } catch {
            Issue.record("expected a network error, got \(error)")
        }
    }
}
