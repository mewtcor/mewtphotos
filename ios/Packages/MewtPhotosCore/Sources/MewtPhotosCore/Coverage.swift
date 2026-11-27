// Coverage: which of the library's items the PC holds (milestone 7). Pure logic, tested on Linux.
import Foundation

public struct Coverage: Equatable, Sendable {
    /// Library items the PC does not hold, in library order.
    public let missing: [LibraryItem]
    /// Library items the PC holds.
    public let held: Int
    /// Items on the PC that the library no longer has (deleted on the phone). Kept by design, so this is
    /// information only, never a failure.
    public let onPCOnly: Int

    /// Verified when every library item is on the PC.
    public var isVerified: Bool { missing.isEmpty }

    public static func compare(library: [LibraryItem], held: Set<String>) -> Coverage {
        let missing = library.filter { !held.contains($0.assetId) }
        let libraryIds = Set(library.map(\.assetId))
        return Coverage(missing: missing, held: library.count - missing.count, onPCOnly: held.subtracting(libraryIds).count)
    }

    /// Returns an updated coverage snapshot after the server confirms `assetId` is stored on disk.
    public func markingHeld(_ assetId: String) -> Coverage {
        guard let index = missing.firstIndex(where: { $0.assetId == assetId }) else { return self }
        var remaining = missing
        remaining.remove(at: index)
        return Coverage(missing: remaining, held: held + 1, onPCOnly: onPCOnly)
    }
}
