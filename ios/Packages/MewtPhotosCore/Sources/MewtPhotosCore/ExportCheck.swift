// The FEAS-03 comparison: the SHA-256 of each exported file on the phone against the same file copied
// over USB. Any mismatch stops the project. Pure logic, tested on Linux; the app computes the hashes.
import Foundation

public enum ExportOutcome: Equatable, Sendable {
    case match
    case mismatch
    case onlyOnPhone
    case onlyOnPC
}

public struct ExportResult: Equatable, Sendable {
    public let name: String
    public let outcome: ExportOutcome

    public init(name: String, outcome: ExportOutcome) {
        self.name = name
        self.outcome = outcome
    }
}

public enum ExportCheck {
    /// `phone` and `pc` map a file name to its lowercase SHA-256 hex.
    public static func compare(phone: [String: String], pc: [String: String]) -> [ExportResult] {
        let names = Set(phone.keys).union(pc.keys).sorted()
        return names.map { name in
            switch (phone[name], pc[name]) {
            case let (p?, c?) where p == c: return ExportResult(name: name, outcome: .match)
            case (_?, _?): return ExportResult(name: name, outcome: .mismatch)
            case (_?, nil): return ExportResult(name: name, outcome: .onlyOnPhone)
            default: return ExportResult(name: name, outcome: .onlyOnPC)
            }
        }
    }
}

/// The manifest the phone writes next to the exported files: one `sha256  name` line per file.
public enum ExportManifest {
    public static func text(_ hashes: [String: String]) -> String {
        hashes.keys.sorted().map { "\(hashes[$0] ?? "")  \($0)\n" }.joined()
    }

    public static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            // The hash runs up to the first space; the name starts after the two spaces that follow it.
            let hash = line.prefix { $0 != " " }
            let name = line.dropFirst(hash.count + 2)
            guard !hash.isEmpty, !name.isEmpty else { continue }
            out[String(name)] = String(hash)
        }
        return out
    }
}
