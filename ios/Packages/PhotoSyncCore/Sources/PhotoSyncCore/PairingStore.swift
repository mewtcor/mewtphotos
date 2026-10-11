// What the phone remembers about the PC it paired with: one small JSON file, like the server's
// settings blob (server/config.ts loadSettings/saveSettings). It holds NO secret; the device key
// lives only in the key store. `schema` lets later phases evolve the layout with a version bump.
import Foundation

public struct PairingRecord: Codable, Equatable, Sendable {
    public static let currentSchema = 1

    public let schema: Int
    public let serverURL: String
    public let deviceId: String
    public let deviceName: String
    public let serverName: String
    public let pairedAtEpoch: Int

    public init(schema: Int = PairingRecord.currentSchema, serverURL: String, deviceId: String,
                deviceName: String, serverName: String, pairedAtEpoch: Int) {
        self.schema = schema
        self.serverURL = serverURL
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.serverName = serverName
        self.pairedAtEpoch = pairedAtEpoch
    }

    /// The host this record points at, or nil if the file is not exactly what this app writes: a
    /// hand-edited or foreign record must not steer the key to another host. Strict: plain http,
    /// host and port only, byte-for-byte the form `ServerAddress.baseURL` produces.
    var validAddress: ServerAddress? {
        guard schema == Self.currentSchema, serverURL.hasPrefix("http://"),
              case .success(let address) = ServerAddress.parse(serverURL),
              address.pairingCode == nil,
              address.baseURL.absoluteString == serverURL else { return nil }
        return address
    }
}

public enum PairingLoad: Equatable, Sendable {
    case none
    case record(PairingRecord)
    case corrupt
}

public struct PairingStore: Sendable {
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    private var fileURL: URL { directory.appendingPathComponent("pairing.json") }

    public func load() -> PairingLoad {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .none }
        guard let data = try? Data(contentsOf: fileURL),
              let record = try? JSONDecoder().decode(PairingRecord.self, from: data),
              record.validAddress != nil else { return .corrupt }
        return .record(record)
    }

    public func save(_ record: PairingRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: fileURL, options: .atomic)
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
