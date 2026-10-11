// The in-app log the user exports from the phone (there is no debugger without a Mac). Same shape as
// the server's Ctx.log (server/engine.ts): a level, a stable snake_case event code and a message,
// one line per call. Callers must not pass secrets, and this type enforces it anyway by scrubbing
// every registered secret and every "Bearer ..." run before a line is written.
import Foundation

public enum LogLevel: String, Sendable {
    case info, warn, error
}

public actor RunLog {
    public nonisolated let fileURL: URL
    private let rotatedURL: URL
    private let maxBytes: Int
    /// Longest first, so a secret that contains another is replaced whole. Memory only, never persisted.
    private var secrets: [String] = []
    /// Bytes in the current file, tracked here so rotation needs no file-attribute lookups.
    private var currentSize: Int

    private static let maxMessageCharacters = 2000
    private static let minSecretLength = 8
    private static let redacted = "<redacted>"

    public init(directory: URL, maxBytes: Int = 262_144) {
        let file = directory.appendingPathComponent("photosync.log")
        // The share sheet needs a file to exist, so create it now (an existing log is left alone).
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        fileURL = file
        rotatedURL = directory.appendingPathComponent("photosync.1.log")
        self.maxBytes = maxBytes
        currentSize = FileManager.default.contents(atPath: file.path)?.count ?? 0
    }

    /// Call before any line that could contain the value. Short values are ignored: replacing a
    /// 3-character string everywhere would shred the log and protect nothing.
    public func register(secret: String) {
        guard secret.count >= Self.minSecretLength, !secrets.contains(secret) else { return }
        secrets.append(secret)
        secrets.sort { $0.count > $1.count }
    }

    public func append(_ level: LogLevel, code: String, _ message: String) {
        let text = flatten(scrub(code)) + " " + String(flatten(scrub(message)).prefix(Self.maxMessageCharacters))
        let line = "\(Date().ISO8601Format()) \(level.rawValue.uppercased()) \(text)\n"
        let data = Data(line.utf8)
        // ponytail: a failed write is dropped; logging must never crash or block the app.
        rotateIfNeeded(adding: data.count)
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        if (try? handle.write(contentsOf: data)) != nil { currentSize += data.count }
    }

    /// The rotated file, then the current one.
    public func snapshot() -> String {
        var out = ""
        for url in [rotatedURL, fileURL] {
            if let data = FileManager.default.contents(atPath: url.path) {
                out += String(decoding: data, as: UTF8.self)
            }
        }
        return out
    }

    // ---- internals ----

    /// Rotation happens between lines, so a line is never split across the two files.
    private func rotateIfNeeded(adding bytes: Int) {
        guard currentSize > 0, currentSize + bytes > maxBytes else { return }
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: fileURL, to: rotatedURL)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        currentSize = 0
    }

    private func scrub(_ text: String) -> String {
        var out = text
        for secret in secrets {
            out = out.replacingOccurrences(of: secret, with: Self.redacted)
        }
        return Self.redactBearer(out)
    }

    /// Replaces whatever follows "Bearer " (up to the next whitespace) with the redaction marker.
    static func redactBearer(_ text: String) -> String {
        let marker = "Bearer "
        var out = ""
        var rest = Substring(text)
        while let found = rest.range(of: marker, options: .caseInsensitive) {
            out += rest[..<found.upperBound]
            rest = rest[found.upperBound...]
            let run = rest.prefix { !$0.isWhitespace }
            if !run.isEmpty { out += redacted }
            rest = rest.dropFirst(run.count)
        }
        return out + rest
    }

    /// One call is one line: every control character, including CR, LF and NUL, becomes a space.
    private func flatten(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: out.append(" ")
            default: out.append(scalar)
            }
        }
        return String(out)
    }
}
