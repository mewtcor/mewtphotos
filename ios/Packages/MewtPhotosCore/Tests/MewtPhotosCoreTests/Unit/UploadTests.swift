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
}
