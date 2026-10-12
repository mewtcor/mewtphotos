// The stored parts of one library item (for example the photo, its paired video and any edit data), and
// the plain summary line the diagnostics screen shows. Pure logic, so it is tested on Linux. The app reads
// the parts through PhotoKit and passes plain values here.
import Foundation

public struct PartRecord: Equatable, Sendable {
    /// The resource type as iOS names it, for example `photo`, `alternatePhoto` or `pairedVideo`.
    public let kind: String
    public let filename: String
    /// The uniform type identifier iOS reports, for example `public.heic`.
    public let format: String
    /// nil when the part could not be measured, for example when it exists only in iCloud.
    public let bytes: Int64?

    public init(kind: String, filename: String, format: String, bytes: Int64?) {
        self.kind = kind
        self.filename = filename
        self.format = format
        self.bytes = bytes
    }
}

public enum ItemParts {
    public static func summary(_ parts: [PartRecord]) -> String {
        if parts.isEmpty { return "No stored parts found" }
        let known = parts.compactMap(\.bytes)
        let unknown = parts.count - known.count
        let count = parts.count == 1 ? "1 part" : "\(parts.count) parts"
        let total = formatBytes(known.reduce(0, +))
        if unknown == 0 { return "\(count), \(total)" }
        let suffix = unknown == 1 ? "1 part of unknown size" : "\(unknown) parts of unknown size"
        return "\(count), \(total) plus \(suffix)"
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        let units: [(String, Double)] = [("GB", 1_073_741_824), ("MB", 1_048_576), ("KB", 1024)]
        for (name, size) in units where Double(bytes) >= size {
            return String(format: "%.1f %@", Double(bytes) / size, name)
        }
        return "\(bytes) B"
    }
}
