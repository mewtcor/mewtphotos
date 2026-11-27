// Talks to the Mewt Photos server's /api/v1: health, pairing and status. Server answers and network
// failures are kept as two distinct error cases (as web/src/api.ts does) so callers can tell
// "the PC said no" from "the PC was not reachable". Never logs; callers log.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// ---- wire ----

public struct HealthResponse: Codable, Equatable, Sendable {
    public let ok: Bool
    public let name: String
    public let apiVersion: Int

    public init(ok: Bool, name: String, apiVersion: Int) {
        self.ok = ok
        self.name = name
        self.apiVersion = apiVersion
    }
}

public struct ServerStatus: Codable, Equatable, Sendable {
    public let deviceName: String
    public let serverName: String
    public let chunkSize: Int
    public let concurrency: Int
    public let maxFileBytes: Int
    public let freeBytes: Int64?
    public let storedFiles: Int?
    public let storedBytes: Int64?
    public let verifyRunning: Bool?
    public let lastVerifyAt: Int64?
    public let oneShotMetadata: Bool?

    public init(
        deviceName: String,
        serverName: String,
        chunkSize: Int,
        concurrency: Int,
        maxFileBytes: Int,
        freeBytes: Int64? = nil,
        storedFiles: Int? = nil,
        storedBytes: Int64? = nil,
        verifyRunning: Bool? = nil,
        lastVerifyAt: Int64? = nil,
        oneShotMetadata: Bool? = nil
    ) {
        self.deviceName = deviceName
        self.serverName = serverName
        self.chunkSize = chunkSize
        self.concurrency = concurrency
        self.maxFileBytes = maxFileBytes
        self.freeBytes = freeBytes
        self.storedFiles = storedFiles
        self.storedBytes = storedBytes
        self.verifyRunning = verifyRunning
        self.lastVerifyAt = lastVerifyAt
        self.oneShotMetadata = oneShotMetadata
    }
}

struct VerifyReply: Decodable {
    let started: Bool
}

struct PairBody: Encodable {
    let code: String
    let deviceName: String
}

struct PairReply: Decodable {
    let token: String
    let deviceId: String
}

/// Server error bodies are `{ error, message, ...extra }`; unknown keys are ignored.
struct ErrorBody: Decodable {
    let error: String?
    let message: String?
}

public struct PairResult: Sendable {
    public let key: DeviceKey
    public let deviceId: String

    public init(key: DeviceKey, deviceId: String) {
        self.key = key
        self.deviceId = deviceId
    }
}

// ---- errors ----

public struct NetworkFailure: Equatable, Sendable {
    public let domain: String
    public let code: Int
    public let underlyingCode: Int?
    public let summary: String

    public init(domain: String, code: Int, underlyingCode: Int?, summary: String) {
        self.domain = domain
        self.code = code
        self.underlyingCode = underlyingCode
        self.summary = summary
    }

    /// Domain and code are what tell "local network denied" (-1009) from a timeout (-1001) or a
    /// refused connection (-1004); `localizedDescription` alone cannot. Never holds headers or bodies.
    init(_ error: any Error) {
        if let urlError = error as? URLError {
            let underlying = urlError.userInfo[NSUnderlyingErrorKey] as? NSError
            self.init(domain: "NSURLErrorDomain", code: urlError.code.rawValue, underlyingCode: underlying?.code,
                      summary: "NSURLErrorDomain \(urlError.code.rawValue)")
        } else {
            let ns = error as NSError
            let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            self.init(domain: ns.domain, code: ns.code, underlyingCode: underlying?.code,
                      summary: "\(ns.domain) \(ns.code)")
        }
    }
}

public enum ServerClientError: Error, Equatable, Sendable {
    /// The server answered with a non-2xx status.
    case server(status: Int, code: String, message: String)
    /// The request never got an answer.
    case network(NetworkFailure)
    /// A 2xx answer that is not the shape this app expects.
    case unexpectedResponse(String)
    /// The caller's input was rejected before anything was sent.
    case invalidInput(String)
}

// ---- client ----

public struct ServerClient: Sendable {
    /// The server rejects device names longer than 80 UTF-16 code units (JavaScript string length).
    static let maxDeviceNameUnits = 80

    private let base: URL
    private let transport: any HTTPTransport

    public init(base: URL, transport: any HTTPTransport) {
        self.base = base
        self.transport = transport
    }

    public func health() async throws -> HealthResponse {
        try decode(HealthResponse.self, from: try await perform("GET", "api/v1/health"))
    }

    /// Exchanges a pairing code for a device key. The raw token is wrapped before it leaves this function.
    public func pair(code: String, deviceName: String) async throws -> PairResult {
        // The server upper-cases the code and strips punctuation itself, so only whitespace is trimmed here.
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = Self.clampedName(deviceName)
        guard !trimmedCode.isEmpty else { throw ServerClientError.invalidInput("Enter the pairing code shown on your PC.") }
        guard !name.isEmpty else { throw ServerClientError.invalidInput("Enter a name for this iPhone.") }
        let body: Data
        do {
            body = try JSONEncoder().encode(PairBody(code: trimmedCode, deviceName: name))
        } catch {
            throw ServerClientError.invalidInput("The pairing request could not be built.")
        }
        let reply = try decode(PairReply.self, from: try await perform(
            "POST", "api/v1/pair", headers: ["Content-Type": "application/json"], body: body))
        guard !reply.token.isEmpty else {
            throw ServerClientError.unexpectedResponse("The PC paired this iPhone but sent no key.")
        }
        return PairResult(key: DeviceKey(reply.token), deviceId: reply.deviceId)
    }

    public func status(key: DeviceKey) async throws -> ServerStatus {
        try decode(ServerStatus.self, from: try await perform(
            "GET", "api/v1/status", headers: ["Authorization": "Bearer \(key.revealForAuthorization())"]))
    }

    /// Starts a full SHA-256 verification pass on the server.
    @discardableResult
    public func triggerVerify(key: DeviceKey) async throws -> Bool {
        try decode(VerifyReply.self, from: try await perform(
            "POST", "api/v1/verify", headers: ["Authorization": "Bearer \(key.revealForAuthorization())"])).started
    }

    /// Trim, then drop whole trailing Characters until the name fits in 80 UTF-16 code units,
    /// so an emoji-heavy name is never cut in half and never trips the server's limit.
    static func clampedName(_ raw: String) -> String {
        var out = ""
        var units = 0
        for character in raw.trimmingCharacters(in: .whitespacesAndNewlines) {
            let width = String(character).utf16.count
            if units + width > maxDeviceNameUnits { break }
            out.append(character)
            units += width
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func perform(_ method: String, _ path: String, headers: [String: String] = [:], body: Data? = nil) async throws -> Data {
        let request = HTTPRequest(method: method, url: base.appendingPathComponent(path), headers: headers, body: body)
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            throw ServerClientError.network(NetworkFailure(error))
        }
        guard (200..<300).contains(response.status) else {
            let parsed = try? JSONDecoder().decode(ErrorBody.self, from: response.body)
            throw ServerClientError.server(
                status: response.status,
                code: parsed?.error ?? "error",
                message: parsed?.message ?? "Request failed (\(response.status)).")
        }
        return response.body
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            // No body text in the message: a pair reply holds the key.
            throw ServerClientError.unexpectedResponse("The PC's reply was not what Mewt Photos expected.")
        }
    }
}
