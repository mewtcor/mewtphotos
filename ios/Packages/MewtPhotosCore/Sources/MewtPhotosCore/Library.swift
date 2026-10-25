// What the photo library permission allows, and the count of items the PC does not have yet. The rules are
// pure and tested on Linux; the app maps Photos' authorization status and the asset identifiers into these.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum LibraryAccess: Equatable, Sendable {
    case full
    case limited
    case denied
    case restricted
    case notDetermined

    /// Only full access may run a count or a backup; limited access would present an incomplete library as whole.
    public var canRun: Bool { self == .full }

    /// The words the screen shows for this state.
    public var message: String {
        switch self {
        case .full:
            return "Mewt Photos can read your whole library."
        case .limited:
            return "You gave Mewt Photos access to selected photos only. Choose All Photos in Settings. Until then Mewt Photos cannot back up your whole library, so it will not show a complete result."
        case .denied:
            return "Mewt Photos cannot read your photos. Turn on Photos access for Mewt Photos in Settings."
        case .restricted:
            return "Photo access is restricted on this iPhone, for example by Screen Time or a device profile. Mewt Photos cannot read your photos."
        case .notDetermined:
            return "Mewt Photos needs access to your photos to see what is not on the PC yet. Tap Allow Access."
        }
    }
}

struct AssetCheckItem: Encodable {
    let assetId: String
}

struct AssetCheckBody: Encodable {
    let items: [AssetCheckItem]
}

struct AssetCheckReply: Decodable {
    let known: [Bool]
}

extension ServerClient {
    /// The server accepts at most this many items per check (AssetCheck in shared/schemas.ts).
    static let assetCheckBatch = 5000

    /// For each asset identifier, in the same order: whether the PC already holds that item. Batches the
    /// identifiers to stay under the server's limit. Nothing is sent but the identifiers.
    public func knownAssets(key: DeviceKey, assetIds: [String]) async throws -> [Bool] {
        let json = ["Authorization": "Bearer \(key.revealForAuthorization())", "Content-Type": "application/json"]
        var known: [Bool] = []
        for start in stride(from: 0, to: assetIds.count, by: Self.assetCheckBatch) {
            let batch = assetIds[start..<min(start + Self.assetCheckBatch, assetIds.count)]
            let body = try JSONEncoder().encode(AssetCheckBody(items: batch.map { AssetCheckItem(assetId: $0) }))
            let reply = try decode(AssetCheckReply.self, from: try await perform("POST", "api/v1/assets/check", headers: json, body: body))
            guard reply.known.count == batch.count else {
                throw ServerClientError.unexpectedResponse("The PC answered for a different number of items.")
            }
            known += reply.known
        }
        return known
    }
}

struct AssetCountReply: Decodable {
    let stored: Int
}

struct AssetHeldReply: Decodable {
    let assetIds: [String]
}

extension ServerClient {
    /// How many of this iPhone's photos the PC holds (REP-02), so the app can compare it with its own totals.
    public func storedAssetCount(key: DeviceKey) async throws -> Int {
        try decode(AssetCountReply.self, from: try await perform(
            "GET", "api/v1/assets/count", headers: ["Authorization": "Bearer \(key.revealForAuthorization())"])).stored
    }

    /// Every asset identifier the PC holds for this iPhone, for the coverage report (milestone 7).
    public func heldAssetIds(key: DeviceKey) async throws -> Set<String> {
        Set(try decode(AssetHeldReply.self, from: try await perform(
            "GET", "api/v1/assets/held", headers: ["Authorization": "Bearer \(key.revealForAuthorization())"])).assetIds)
    }
}
