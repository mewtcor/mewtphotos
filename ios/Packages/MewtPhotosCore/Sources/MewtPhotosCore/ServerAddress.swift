// Turns what the user types (or pastes from the QR link) into the one host:port that will receive
// the pairing code. Parsed by hand and strictly: a lax parser could send the code somewhere the
// user did not mean. Mirrors how web/src/Phone.tsx reads the `#pair=CODE` fragment.
import Foundation

public enum ServerAddressError: Error, Equatable, Sendable {
    case empty
    case unsupportedScheme
    case badHost
    case badPort
    case unexpectedPath
    case badPairingFragment

    /// Plain English for the person typing.
    public var userMessage: String {
        switch self {
        case .empty:
            return "Type the address of your PC, for example 192.168.1.20."
        case .unsupportedScheme:
            return "This app talks to your PC over plain http on your home network. Remove https:// or any other prefix."
        case .badHost:
            return "That does not look like a PC address. Use numbers like 192.168.1.20, or the PC's name."
        case .badPort:
            return "The port after the colon must be a number from 1 to 65535. Leave it out to use 8787."
        case .unexpectedPath:
            return "Type only the address, such as 192.168.1.20 or 192.168.1.20:8787, with nothing after it."
        case .badPairingFragment:
            return "The pairing code in that link is not valid. Type the code from your PC's dashboard instead."
        }
    }
}

public struct ServerAddress: Equatable, Sendable {
    /// The server's default port (MEWTPHOTOS_PORT default in server/main.ts).
    public static let defaultPort = 8787

    public let host: String
    public let port: Int
    /// The code from a `#pair=CODE` link. Secret: callers must keep it out of logs.
    public let pairingCode: String?
    /// Exactly `http://HOST:PORT`, no path.
    public let baseURL: URL

    public var display: String { "\(host):\(port)" }

    public static func parse(_ text: String) -> Result<ServerAddress, ServerAddressError> {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.isEmpty { return .failure(.empty) }

        if rest.lowercased().hasPrefix("http://") {
            rest.removeFirst("http://".count)
        } else if rest.contains("://") {
            return .failure(.unsupportedScheme)
        }

        var pairingCode: String?
        if let hash = rest.firstIndex(of: "#") {
            let fragment = String(rest[rest.index(after: hash)...])
            rest = String(rest[..<hash])
            if !fragment.isEmpty {
                guard fragment.hasPrefix("pair=") else { return .failure(.badPairingFragment) }
                let code = String(fragment.dropFirst("pair=".count))
                guard (1...32).contains(code.unicodeScalars.count), code.unicodeScalars.allSatisfy(isASCIIAlphanumeric) else {
                    return .failure(.badPairingFragment)
                }
                pairingCode = code
            }
        }

        if rest.contains("?") { return .failure(.unexpectedPath) }
        if rest.contains("@") { return .failure(.badHost) }
        if rest.hasSuffix("/") { rest.removeLast() }
        if rest.contains("/") { return .failure(.unexpectedPath) }
        if rest.hasPrefix("[") { return .failure(.badHost) }

        var hostText = rest
        var port = defaultPort
        if let colon = rest.lastIndex(of: ":") {
            hostText = String(rest[..<colon])
            let portText = String(rest[rest.index(after: colon)...])
            guard (1...5).contains(portText.unicodeScalars.count), portText.unicodeScalars.allSatisfy(isASCIIDigit),
                  let parsed = Int(portText), (1...65535).contains(parsed) else {
                return .failure(.badPort)
            }
            port = parsed
        }

        guard isValidHost(hostText) else { return .failure(.badHost) }

        var components = URLComponents()
        components.scheme = "http"
        components.host = hostText
        components.port = port
        guard let url = components.url else { return .failure(.badHost) }
        return .success(ServerAddress(host: hostText, port: port, pairingCode: pairingCode, baseURL: url))
    }

    // ---- host rules ----

    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 48 && scalar.value <= 57
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        isASCIIDigit(scalar) || (scalar.value >= 65 && scalar.value <= 90) || (scalar.value >= 97 && scalar.value <= 122)
    }

    /// DNS-style names (letters, digits, hyphens; 1 to 63 per label; at most 253 in all) or a strict
    /// dotted-quad IPv4 address. Anything else, including IPv6 literals and non-ASCII names, is refused.
    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.unicodeScalars.count <= 253, host.unicodeScalars.allSatisfy({ $0.isASCII }) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard (1...63).contains(label.unicodeScalars.count),
                  label.unicodeScalars.allSatisfy({ isASCIIAlphanumeric($0) || $0 == "-" }),
                  !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
        }
        if labels.allSatisfy({ $0.unicodeScalars.allSatisfy(isASCIIDigit) }) {
            guard labels.count == 4 else { return false }
            return labels.allSatisfy { octet in
                guard octet.unicodeScalars.count <= 3, let value = Int(octet) else { return false }
                return value <= 255 && (octet == "0" || !octet.hasPrefix("0"))
            }
        }
        return true
    }
}
