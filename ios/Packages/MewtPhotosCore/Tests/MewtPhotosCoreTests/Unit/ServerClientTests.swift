// ServerClient request shapes and error mapping, with a fake transport (no server needed).
import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MewtPhotosCore

@Suite struct ServerClientTests {
    private static let base = URL(string: "http://192.168.1.20:8787")!
    private static let pairReply = #"{"token":"TOKEN-TEXT-12345","deviceId":"dev-1"}"#
    private static let statusReply =
        #"{"deviceName":"Phone","serverName":"PC","chunkSize":8388608,"concurrency":2,"maxFileBytes":53687091200}"#

    private func sentBody(_ transport: FakeTransport) async throws -> [String: String] {
        let requests = await transport.requests()
        let body = try #require(requests.first?.body)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
    }

    @Test func pairSendsTheExpectedRequest() async throws {
        let fake = FakeTransport([.json(Self.pairReply)])
        let client = ServerClient(base: Self.base, transport: fake)
        let result = try await client.pair(code: "  ABCD2345 \n", deviceName: "My iPhone")
        let sent = await fake.requests()
        let request = try #require(sent.first)
        #expect(request.method == "POST")
        #expect(request.url.path == "/api/v1/pair")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["Authorization"] == nil)
        let body = try await sentBody(fake)
        #expect(body == ["code": "ABCD2345", "deviceName": "My iPhone"])
        #expect(result.deviceId == "dev-1")
        #expect(result.key.revealForAuthorization() == "TOKEN-TEXT-12345")
    }

    @Test func longEmojiNamesAreClampedToEightyUnitsWithoutSplittingACharacter() async throws {
        let fake = FakeTransport([.json(Self.pairReply), .json(Self.pairReply)])
        let client = ServerClient(base: Self.base, transport: fake)
        _ = try await client.pair(code: "ABCD2345", deviceName: String(repeating: "😀", count: 100))
        let family = "👨‍👩‍👧"
        _ = try await client.pair(code: "ABCD2345", deviceName: "a" + String(repeating: family, count: 20))
        let requests = await fake.requests()
        let names = try requests.map { request -> String in
            let body = try #require(request.body)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
            return try #require(object["deviceName"])
        }
        #expect(names[0].utf16.count == 80)
        #expect(names[0].count == 40)
        #expect(names[1].utf16.count <= 80)
        #expect(names[1] == "a" + String(repeating: family, count: names[1].count - 1))
    }

    @Test func emptyNameOrCodeIsRejectedWithoutCallingTheTransport() async {
        let fake = FakeTransport([.json(Self.pairReply)])
        let client = ServerClient(base: Self.base, transport: fake)
        let noName = await capturedError { _ = try await client.pair(code: "ABCD2345", deviceName: "   ") }
        let noCode = await capturedError { _ = try await client.pair(code: " \n", deviceName: "Phone") }
        guard let noName, case .invalidInput = noName else { Issue.record("empty name: \(String(describing: noName))"); return }
        guard let noCode, case .invalidInput = noCode else { Issue.record("empty code: \(String(describing: noCode))"); return }
        #expect(await fake.requests().isEmpty)
    }

    @Test func statusSendsTheBearerKey() async throws {
        let fake = FakeTransport([.json(Self.statusReply)])
        let client = ServerClient(base: Self.base, transport: fake)
        let status = try await client.status(key: DeviceKey("KEY-TEXT-98765"))
        let sent = await fake.requests()
        let request = try #require(sent.first)
        #expect(request.method == "GET")
        #expect(request.url.path == "/api/v1/status")
        #expect(request.headers["Authorization"] == "Bearer KEY-TEXT-98765")
        #expect(status.chunkSize == 8388608)
        #expect(status.serverName == "PC")
    }

    @Test func healthSendsNoAuthorization() async throws {
        let fake = FakeTransport([.json(#"{"ok":true,"name":"mewtphotos","apiVersion":1}"#)])
        let client = ServerClient(base: Self.base, transport: fake)
        let health = try await client.health()
        let sent = await fake.requests()
        let request = try #require(sent.first)
        #expect(request.url.path == "/api/v1/health")
        #expect(request.headers["Authorization"] == nil)
        #expect(health == HealthResponse(ok: true, name: "mewtphotos", apiVersion: 1))
    }

    @Test func serverErrorBodyBecomesAServerError() async {
        let fake = FakeTransport([.json(#"{"error":"bad_pairing_code","message":"Wrong code.","extra":1}"#, status: 403)])
        let client = ServerClient(base: Self.base, transport: fake)
        let error = await capturedError { _ = try await client.pair(code: "ZZZZ", deviceName: "Phone") }
        #expect(error == .server(status: 403, code: "bad_pairing_code", message: "Wrong code."))
    }

    @Test func nonJsonErrorBodyGetsADefaultMessage() async {
        let fake = FakeTransport([.json("<html>Bad gateway</html>", status: 502)])
        let client = ServerClient(base: Self.base, transport: fake)
        let error = await capturedError { _ = try await client.health() }
        #expect(error == .server(status: 502, code: "error", message: "Request failed (502)."))
    }

    @Test func invalidJsonOnSuccessIsUnexpected() async {
        let fake = FakeTransport([.json("not json")])
        let client = ServerClient(base: Self.base, transport: fake)
        let error = await capturedError { _ = try await client.health() }
        guard let error, case .unexpectedResponse = error else { Issue.record("got \(String(describing: error))"); return }
    }

    @Test func transportFailuresBecomeNetworkErrorsWithDomainAndCode() async {
        let fake = FakeTransport([
            .failure(URLError(.notConnectedToInternet)),
            .failure(URLError(.timedOut)),
        ])
        let client = ServerClient(base: Self.base, transport: fake)
        let offline = await capturedError { _ = try await client.health() }
        let timedOut = await capturedError { _ = try await client.health() }
        guard let offline, case .network(let first) = offline else { Issue.record("offline: \(String(describing: offline))"); return }
        guard let timedOut, case .network(let second) = timedOut else { Issue.record("timeout: \(String(describing: timedOut))"); return }
        #expect(first.domain == "NSURLErrorDomain")
        #expect(first.code == -1009)
        #expect(second.code == -1001)
    }

    @Test func errorsNeverContainTheKey() async {
        let secret = "LEAK-CHECK-KEY-55555"
        let fake = FakeTransport([
            .json(#"{"error":"unauthorized","message":"Not paired."}"#, status: 401),
            .failure(URLError(.notConnectedToInternet)),
            .json("not json"),
        ])
        let client = ServerClient(base: Self.base, transport: fake)
        for _ in 0..<3 {
            let error = await capturedError { _ = try await client.status(key: DeviceKey(secret)) }
            #expect(error != nil)
            #expect(!String(describing: error).contains(secret))
            #expect(!String(reflecting: error).contains(secret))
        }
    }
}
