// The upload speed test: the timing arithmetic, and the open and finish calls against a scripted server.
import Testing
import Foundation
@testable import MewtPhotosCore

@Suite("Upload speed test")
struct UploadTests {
    @Test("speed is MiB per second")
    func speed() {
        #expect(TransferSpeed.mibPerSecond(bytes: 80 * 1_048_576, seconds: 10) == 8.0)
    }

    @Test("a zero-time run has no speed")
    func zeroTime() {
        #expect(TransferSpeed.mibPerSecond(bytes: 1_048_576, seconds: 0) == nil)
    }

    @Test("opening an upload returns its id and the offset to send from")
    func beginUpload() async throws {
        let fake = FakeTransport([
            .json(#"{"id":"s1"}"#),
            .json(#"{"uploadId":"u1","status":"receiving","offset":4,"size":10}"#),
        ])
        let client = ServerClient(base: URL(string: "http://127.0.0.1:8787")!, transport: fake)
        let begun = try await client.beginUpload(key: DeviceKey("tok"), filename: "a.mov", mimeType: "video/quicktime", size: 10, sha256: "x")
        #expect(begun.uploadId == "u1")
        #expect(begun.offset == 4)
        #expect(!begun.alreadyStored)
        let requests = await fake.requests()
        #expect(requests.last?.url.path == "/api/v1/uploads")
    }

    @Test("a file the PC already holds needs no sending")
    func alreadyStored() async throws {
        let fake = FakeTransport([
            .json(#"{"id":"s1"}"#),
            .json(#"{"uploadId":"u1","status":"duplicate","sha256":"x","endToEndVerified":false,"path":"p"}"#),
        ])
        let client = ServerClient(base: URL(string: "http://127.0.0.1:8787")!, transport: fake)
        let begun = try await client.beginUpload(key: DeviceKey("tok"), filename: "a.mov", mimeType: "video/quicktime", size: 10, sha256: "x")
        #expect(begun.alreadyStored)
        #expect(begun.offset == 10)
    }

    @Test("finishing reports the server's status and its end-to-end check")
    func finishUpload() async throws {
        let fake = FakeTransport([
            .json(#"{"uploadId":"u1","status":"verified","sha256":"x","endToEndVerified":true,"path":"p"}"#),
        ])
        let client = ServerClient(base: URL(string: "http://127.0.0.1:8787")!, transport: fake)
        let done = try await client.finishUpload(key: DeviceKey("tok"), uploadId: "u1", sha256: "x")
        #expect(done.status == "verified")
        #expect(done.endToEndVerified)
    }

    @Test("reusing a session skips POST /api/v1/sessions per file")
    func beginUploadReusesSession() async throws {
        let fake = FakeTransport([
            .json(#"{"id":"s-shared"}"#),
            .json(#"{"uploadId":"u1","status":"receiving","offset":0,"size":10}"#),
        ])
        let client = ServerClient(base: URL(string: "http://127.0.0.1:8787")!, transport: fake)
        let sessionId = try await client.createSession(key: DeviceKey("tok"), selectedCount: 42, libraryCount: 100)
        #expect(sessionId == "s-shared")
        let begun = try await client.beginUpload(
            key: DeviceKey("tok"), filename: "a.heic", mimeType: "image/heic",
            size: 10, sha256: "x", sessionId: sessionId)
        #expect(begun.uploadId == "u1")
        let requests = await fake.requests()
        #expect(requests.map(\.url.path) == ["/api/v1/sessions", "/api/v1/uploads"])
    }

    @Test("one-shot URL encodes native metadata and decodes verified reply")
    func oneShotHelpers() throws {
        let base = URL(string: "http://192.168.4.20:8788")!
        let url = ServerClient.oneShotUploadURL(
            base: base,
            filename: "IMG 01.HEIC",
            sessionId: "sess-1",
            sha256: String(repeating: "a", count: 64),
            assetId: "A/B",
            hidden: true,
            lastModified: 1_700_000_000_000,
            pairId: "pair-1",
            pairName: "IMG 01.MOV"
        )
        #expect(url != nil)
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let map = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(map["filename"] == "IMG 01.HEIC")
        #expect(map["sessionId"] == "sess-1")
        #expect(map["assetId"] == "A/B")
        #expect(map["hidden"] == "1")
        #expect(map["lastModified"] == "1700000000000")
        #expect(map["pairId"] == "pair-1")
        #expect(map["pairName"] == "IMG 01.MOV")

        let reply = try ServerClient.decodeUploadResult(
            from: Data(#"{"uploadId":"u1","status":"verified","sha256":"x","endToEndVerified":true,"path":"p"}"#.utf8))
        #expect(reply.status == "verified")
        #expect(reply.endToEndVerified)
    }
}
