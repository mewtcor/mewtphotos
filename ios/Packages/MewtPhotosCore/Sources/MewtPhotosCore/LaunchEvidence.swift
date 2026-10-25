// Launch evidence: one line per launch that says which build ran and what it found stored, so a
// refresh that the phone cannot explain can be diffed from the exported log. Core never prints;
// the app writes the line to RunLog. Nothing here can carry the device key or the pairing code.
import Foundation

public struct LaunchFacts: Equatable, Sendable {
    public let launch: Int
    public let version: String
    public let build: String
    public let gitSHA: String
    public let bundleID: String
    public let altBundleID: String?
    /// `found`, `not_found` or `error(N)`, from PairingFlow.storageStates().
    public let keychain: String
    /// `none`, `present` or `corrupt`, from PairingFlow.storageStates().
    public let pairing: String

    public init(launch: Int, version: String, build: String, gitSHA: String, bundleID: String,
                altBundleID: String?, keychain: String, pairing: String) {
        self.launch = launch
        self.version = version
        self.build = build
        self.gitSHA = gitSHA
        self.bundleID = bundleID
        self.altBundleID = altBundleID
        self.keychain = keychain
        self.pairing = pairing
    }

    /// Fixed field order, single spaces, no newline. A newline inside a value would split the
    /// line in the log and is removed.
    public var logLine: String {
        [
            "launch=\(launch)",
            "version=\(clean(version))",
            "build=\(clean(build))",
            "sha=\(clean(gitSHA))",
            "bundle=\(clean(bundleID))",
            "alt_bundle=\(altBundleID.map(clean) ?? "-")",
            "keychain=\(clean(keychain))",
            "pairing=\(clean(pairing))",
        ].joined(separator: " ")
    }

    private func clean(_ value: String) -> String {
        value.filter { $0 != "\n" && $0 != "\r" }
    }
}

public enum LaunchCounter {
    /// Reads `launch-count`, adds one and writes it back. A missing, empty or non-numeric file counts
    /// as zero, so a damaged file restarts the count rather than blocking launch.
    public static func next(in directory: URL) throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("launch-count")
        let stored = (try? String(contentsOf: file, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let next = max(stored, 0) + 1
        try String(next).write(to: file, atomically: true, encoding: .utf8)
        return next
    }
}
