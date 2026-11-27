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
    let libraryCount: Int?

    init(method: String, selectedCount: Int, libraryCount: Int? = nil) {
        self.method = method
        self.selectedCount = selectedCount
        self.libraryCount = libraryCount
    }
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
    /// Creates a backup session on the PC so a multi-file run can reuse one session instead of
    /// opening a brand-new session per file.
    public func createSession(key: DeviceKey, selectedCount: Int, libraryCount: Int? = nil) async throws -> String {
        let json = ["Authorization": "Bearer \(key.revealForAuthorization())", "Content-Type": "application/json"]
        let session = try decode(SessionReply.self, from: try await perform(
            "POST", "api/v1/sessions", headers: json,
            body: try JSONEncoder().encode(SessionBody(
                method: "native",
                selectedCount: max(selectedCount, 1),
                libraryCount: libraryCount))))
        return session.id
    }

    /// Opens an upload on the PC (creating a 1-item session if `sessionId` is nil), sending the file's hash
    /// so a file the PC already has is recognised before any bytes move. Otherwise the offset says where to start.
    public func beginUpload(key: DeviceKey, filename: String, mimeType: String, size: Int64, sha256: String,
                            assetId: String? = nil, hidden: Bool = false, lastModified: Int64? = nil,
                            pairId: String? = nil, pairName: String? = nil, sessionId: String? = nil) async throws -> BegunUpload {
        guard size > 0 else { throw ServerClientError.invalidInput("The file is empty.") }
        let json = ["Authorization": "Bearer \(key.revealForAuthorization())", "Content-Type": "application/json"]
        let resolvedSessionId: String
        if let sessionId {
            resolvedSessionId = sessionId
        } else {
            let session = try decode(SessionReply.self, from: try await perform(
                "POST", "api/v1/sessions", headers: json,
                body: try JSONEncoder().encode(SessionBody(method: "native", selectedCount: 1))))
            resolvedSessionId = session.id
        }
        let upload = try await createUploadWaitingForBusy(headers: json, body: try JSONEncoder().encode(
            UploadCreateBody(sessionId: resolvedSessionId, filename: filename, size: size, mimeType: mimeType, sha256: sha256,
                             assetId: assetId, hidden: hidden, lastModified: lastModified, pairId: pairId, pairName: pairName)))
        let stored = upload.status == "verified" || upload.status == "duplicate"
        return BegunUpload(uploadId: upload.uploadId, offset: upload.offset ?? size, alreadyStored: stored)
    }

    /// Builds the URL for a single-request verified upload (`POST /api/v1/files`) used for smaller
    /// files so they complete in 1 round-trip instead of 3.
    public static func oneShotUploadURL(
        base: URL,
        filename: String,
        sessionId: String?,
        sha256: String,
        assetId: String? = nil,
        hidden: Bool = false,
        lastModified: Int64? = nil,
        pairId: String? = nil,
        pairName: String? = nil
    ) -> URL? {
        var components = URLComponents(url: base.appendingPathComponent("api/v1/files"), resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = [
            URLQueryItem(name: "filename", value: filename),
            URLQueryItem(name: "sha256", value: sha256),
        ]
        if let sessionId { items.append(URLQueryItem(name: "sessionId", value: sessionId)) }
        if let assetId { items.append(URLQueryItem(name: "assetId", value: assetId)) }
        if hidden { items.append(URLQueryItem(name: "hidden", value: "1")) }
        if let lastModified { items.append(URLQueryItem(name: "lastModified", value: String(lastModified))) }
        if let pairId { items.append(URLQueryItem(name: "pairId", value: pairId)) }
        if let pairName { items.append(URLQueryItem(name: "pairName", value: pairName)) }
        components?.queryItems = items
        return components?.url
    }

    /// Decodes the JSON reply from `POST /api/v1/files` or `POST /api/v1/uploads/:id/finish`.
    public static func decodeUploadResult(from data: Data) throws -> (status: String, endToEndVerified: Bool) {
        do {
            let reply = try JSONDecoder().decode(FinishReply.self, from: data)
            return (reply.status, reply.endToEndVerified)
        } catch {
            throw ServerClientError.unexpectedResponse("The PC's reply was not what Mewt Photos expected.")
        }
    }

    /// Extracts `{ error, message }` from a non-2xx server reply body.
    public static func decodeErrorBody(from data: Data, status: Int) -> (code: String, message: String) {
        let parsed = try? JSONDecoder().decode(ErrorBody.self, from: data)
        return (parsed?.error ?? "error", parsed?.message ?? "Request failed (\(status)).")
    }

    /// The PC answers `upload_busy` while an earlier, stalled attempt at this file is still open. That attempt is
    /// released after about a minute, so wait and ask again; then the upload resumes instead of starting over.
    private func createUploadWaitingForBusy(headers: [String: String], body: Data) async throws -> UploadReply {
        var attempt = 1
        while true {
            do {
                return try decode(UploadReply.self, from: try await perform("POST", "api/v1/uploads", headers: headers, body: body))
            } catch ServerClientError.server(let status, let code, _) where status == 409 && code == "upload_busy" && attempt < 20 {
                attempt += 1
                try await Task.sleep(for: .seconds(4))
            }
        }
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
