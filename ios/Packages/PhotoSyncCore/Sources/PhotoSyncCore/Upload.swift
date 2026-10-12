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
    /// Sent so the PC can answer "already backed up" before any bytes move.
    let sha256: String
    /// Stable identity of the library item; lets the PC answer by identity too.
    let assetId: String?
    /// The item was hidden on the phone; the PC stores it under Hidden.
    let hidden: Bool
    /// Modification time in milliseconds, used by the PC only when there is no capture date.
    let lastModified: Int64?
    /// The parts of one photo share this identifier; the PC stores them under one base name.
    let pairId: String?
    /// File name of the other part of the photo, so the PC keeps the two names matching.
    let pairName: String?
}

/// The PC answers an upload request either with an open upload (`status` receiving, `offset`) or, when it
/// already holds the file, with the finished result (`status` verified or duplicate, no `offset`).
struct UploadReply: Decodable {
    let uploadId: String
    let status: String?
    let offset: Int64?
}

/// What the PC said when the upload was opened.
public struct BegunUpload: Equatable, Sendable {
    public let uploadId: String
    /// Bytes the PC already holds; equal to the file size when there is nothing left to send.
    public let offset: Int64
    /// True when the PC already has this exact file, so nothing needs sending or finishing.
    public let alreadyStored: Bool

    public init(uploadId: String, offset: Int64, alreadyStored: Bool) {
        self.uploadId = uploadId
        self.offset = offset
        self.alreadyStored = alreadyStored
    }
}

struct FinishBody: Encodable {
    let sha256: String
}

struct FinishReply: Decodable {
    let status: String
    let endToEndVerified: Bool
}

extension ServerClient {
    /// Opens a session and an upload on the PC, sending the file's hash so a file the PC already has is
    /// recognised before any bytes move. Otherwise the offset says where to start sending.
    public func beginUpload(key: DeviceKey, filename: String, mimeType: String, size: Int64, sha256: String,
                            assetId: String? = nil, hidden: Bool = false, lastModified: Int64? = nil,
                            pairId: String? = nil, pairName: String? = nil) async throws -> BegunUpload {
        guard size > 0 else { throw ServerClientError.invalidInput("The file is empty.") }
        let json = ["Authorization": "Bearer \(key.revealForAuthorization())", "Content-Type": "application/json"]
        let session = try decode(SessionReply.self, from: try await perform(
            "POST", "api/v1/sessions", headers: json,
            body: try JSONEncoder().encode(SessionBody(method: "native", selectedCount: 1))))
        let upload = try decode(UploadReply.self, from: try await perform(
            "POST", "api/v1/uploads", headers: json,
            body: try JSONEncoder().encode(UploadCreateBody(sessionId: session.id, filename: filename, size: size,
                                                            mimeType: mimeType, sha256: sha256, assetId: assetId,
                                                            hidden: hidden, lastModified: lastModified,
                                                            pairId: pairId, pairName: pairName))))
        let stored = upload.status == "verified" || upload.status == "duplicate"
        return BegunUpload(uploadId: upload.uploadId, offset: upload.offset ?? size, alreadyStored: stored)
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
