// The upload speed test: the timing arithmetic, and the chunk loop against a scripted server.
import Testing
import Foundation
@testable import PhotoSyncCore

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

    @Test("chunks follow the server's offsets and the file is verified")
    func chunksFollowServerOffsets() async throws {
        let fake = FakeTransport([
            .json(#"{"id":"s1"}"#),
            .json(#"{"uploadId":"u1","status":"receiving","offset":0,"size":10}"#),
            .json(#"{"offset":4}"#),
            .json(#"{"offset":8}"#),
            .json(#"{"offset":10}"#),
            .json(#"{"uploadId":"u1","status":"verified","sha256":"x","endToEndVerified":true,"path":"p"}"#),
        ])
        let client = ServerClient(base: URL(string: "http://127.0.0.1:8787")!, transport: fake)
        let outcome = try await client.uploadFile(
            key: DeviceKey("tok"), filename: "a.mov", mimeType: "video/quicktime", size: 10, sha256: "x", chunkBytes: 4
        ) { _, length in Data(repeating: 1, count: length) }
        #expect(outcome.status == "verified")
        #expect(outcome.endToEndVerified)
        #expect(outcome.sentBytes == 10)
        let patches = await fake.requests().filter { $0.method == "PATCH" }
        #expect(patches.map { $0.headers["Upload-Offset"] } == ["0", "4", "8"])
    }
}
