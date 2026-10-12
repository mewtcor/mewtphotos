// The upload speed test (FEAS-04). Core opens an upload on the PC and closes it again; the bytes travel in
// the app, in a background transfer (BackgroundUploader.swift), because a foreground request stops when the
// screen locks. Core only does the small JSON calls, so it can be tested on Linux.
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

/// The paired PC for one upload: the client for the JSON calls, the base URL for the file transfer, and the key.
public struct PairedConnection: Sendable {
    public let client: ServerClient
    public let base: URL
    public let key: DeviceKey

    public init(client: ServerClient, base: URL, key: DeviceKey) {
        self.client = client
        self.base = base
        self.key = key
    }
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

struct FinishBody: Encodable {
    let sha256: String
}

struct FinishReply: Decodable {
    let status: String
    let endToEndVerified: Bool
}

extension ServerClient {
    /// Opens a session and an upload on the PC. Returns the upload id and the offset to send from: more than
    /// zero when the PC already holds the start of this file.
    public func beginUpload(key: DeviceKey, filename: String, mimeType: String, size: Int64) async throws -> (uploadId: String, offset: Int64) {
        guard size > 0 else { throw ServerClientError.invalidInput("The file is empty.") }
        let json = ["Authorization": "Bearer \(key.revealForAuthorization())", "Content-Type": "application/json"]
        let session = try decode(SessionReply.self, from: try await perform(
            "POST", "api/v1/sessions", headers: json,
            body: try JSONEncoder().encode(SessionBody(method: "native", selectedCount: 1))))
        let upload = try decode(UploadReply.self, from: try await perform(
            "POST", "api/v1/uploads", headers: json,
            body: try JSONEncoder().encode(UploadCreateBody(sessionId: session.id, filename: filename, size: size, mimeType: mimeType))))
        return (upload.uploadId, upload.offset)
    }

    /// Asks the PC to check the bytes it holds against `sha256` and file them. Only `verified` or `duplicate`
    /// means the file is backed up.
    public func finishUpload(key: DeviceKey, uploadId: String, sha256: String) async throws -> (status: String, endToEndVerified: Bool) {
        let json = ["Authorization": "Bearer \(key.revealForAuthorization())", "Content-Type": "application/json"]
        let finished = try decode(FinishReply.self, from: try await perform(
            "POST", "api/v1/uploads/\(uploadId)/finish", headers: json,
            body: try JSONEncoder().encode(FinishBody(sha256: sha256))))
        return (finished.status, finished.endToEndVerified)
    }
}
