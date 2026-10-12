// The upload speed test (FEAS-04): sends one file through the backup's own /api/v1 routes in fixed-size
// chunks and times the chunk transfer. The app supplies the bytes; Core moves them and measures the move.
// The server's hash check runs after the timer stops, so it does not count against the speed.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum TransferSpeed {
    /// MiB per second, or nil when no time passed: a zero-time run has no speed.
    public static func mibPerSecond(bytes: Int64, seconds: Double) -> Double? {
        guard seconds > 0 else { return nil }
        return Double(bytes) / 1_048_576 / seconds
    }
}

public struct UploadOutcome: Equatable, Sendable {
    /// What the server said about the file: `verified`, or `duplicate` if it already had the bytes.
    public let status: String
    public let endToEndVerified: Bool
    /// Bytes sent in this run; less than the file size when the server resumed a partial upload.
    public let sentBytes: Int64
    /// Time spent sending chunks, not counting the server's final hash check.
    public let seconds: Double
    public let chunkBytes: Int

    public init(status: String, endToEndVerified: Bool, sentBytes: Int64, seconds: Double, chunkBytes: Int) {
        self.status = status
        self.endToEndVerified = endToEndVerified
        self.sentBytes = sentBytes
        self.seconds = seconds
        self.chunkBytes = chunkBytes
    }

    public var mibPerSecond: Double? { TransferSpeed.mibPerSecond(bytes: sentBytes, seconds: seconds) }
}

struct SessionBody: Encodable {
    let method: String
    let selectedCount: Int
}

struct SessionReply: Decodable {
    let id: String
}

struct UploadCreateBody: Encodable {
    let sessionId: String
    let filename: String
    let size: Int64
    let mimeType: String
}

struct UploadReply: Decodable {
    let uploadId: String
    let offset: Int64
}

struct OffsetReply: Decodable {
    let offset: Int64
}

struct FinishBody: Encodable {
    let sha256: String
}

struct FinishReply: Decodable {
    let status: String
    let endToEndVerified: Bool
}

extension ServerClient {
    /// Sends `size` bytes as one upload, in `chunkBytes` pieces, starting from whatever offset the server
    /// reports (so a resumed upload sends only the rest). Any refusal throws the usual ServerClientError.
    public func uploadFile(key: DeviceKey, filename: String, mimeType: String, size: Int64, sha256: String,
                           chunkBytes: Int, readChunk: @Sendable (Int64, Int) throws -> Data) async throws -> UploadOutcome {
        guard size > 0 else { throw ServerClientError.invalidInput("The file is empty.") }
        let auth = ["Authorization": "Bearer \(key.revealForAuthorization())"]
        let json = auth.merging(["Content-Type": "application/json"]) { $1 }
        let session = try decode(SessionReply.self, from: try await perform(
            "POST", "api/v1/sessions", headers: json,
            body: try JSONEncoder().encode(SessionBody(method: "native", selectedCount: 1))))
        let upload = try decode(UploadReply.self, from: try await perform(
            "POST", "api/v1/uploads", headers: json,
            body: try JSONEncoder().encode(UploadCreateBody(sessionId: session.id, filename: filename, size: size, mimeType: mimeType))))
        let path = "api/v1/uploads/\(upload.uploadId)"
        let chunkHeaders = auth.merging(["Content-Type": "application/offset+octet-stream"]) { $1 }
        let started = ContinuousClock.now
        var offset = upload.offset
        while offset < size {
            let length = Int(min(Int64(chunkBytes), size - offset))
            let chunk = try readChunk(offset, length)
            guard chunk.count == length else {
                throw ServerClientError.invalidInput("The file could not be read from the phone at byte \(offset).")
            }
            let reply = try decode(OffsetReply.self, from: try await perform(
                "PATCH", path, headers: chunkHeaders.merging(["Upload-Offset": String(offset)]) { $1 }, body: chunk))
            // A chunk the server did not take would loop forever, so treat no progress as a failure.
            guard reply.offset > offset else {
                throw ServerClientError.unexpectedResponse("The PC did not accept the chunk at byte \(offset).")
            }
            offset = reply.offset
        }
        let parts = started.duration(to: .now).components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        let finished = try decode(FinishReply.self, from: try await perform(
            "POST", "\(path)/finish", headers: json, body: try JSONEncoder().encode(FinishBody(sha256: sha256))))
        return UploadOutcome(status: finished.status, endToEndVerified: finished.endToEndVerified,
                             sentBytes: size - upload.offset, seconds: seconds, chunkBytes: chunkBytes)
    }
}
