// ServerAddress.parse: typed addresses and the QR URL form. The pairing code goes to whatever host
// parses out of this text, so the table below is mostly rejections.
import Foundation
import Testing
import PhotoSyncCore

struct AcceptedAddress: Sendable {
    let input: String
    let host: String
    let port: Int
    let code: String?
}

struct RejectedAddress: Sendable {
    let input: String
    let error: ServerAddressError
}

@Suite struct ServerAddressTests {
    @Test(arguments: [
        AcceptedAddress(input: "192.168.1.20", host: "192.168.1.20", port: 8787, code: nil),
        AcceptedAddress(input: "192.168.1.20:9000", host: "192.168.1.20", port: 9000, code: nil),
        AcceptedAddress(input: "  192.168.1.20  ", host: "192.168.1.20", port: 8787, code: nil),
        AcceptedAddress(input: "HTTP://192.168.1.20:8787", host: "192.168.1.20", port: 8787, code: nil),
        AcceptedAddress(input: "mypc.local", host: "mypc.local", port: 8787, code: nil),
        AcceptedAddress(input: "DESKTOP-AB12", host: "DESKTOP-AB12", port: 8787, code: nil),
        AcceptedAddress(input: "http://192.168.1.20:8787/#pair=ABCD2345", host: "192.168.1.20", port: 8787, code: "ABCD2345"),
        AcceptedAddress(input: "192.168.1.20/", host: "192.168.1.20", port: 8787, code: nil),
        AcceptedAddress(input: "0.0.0.0:65535", host: "0.0.0.0", port: 65535, code: nil),
    ])
    func accepts(_ row: AcceptedAddress) throws {
        let address = try ServerAddress.parse(row.input).get()
        #expect(address.host == row.host)
        #expect(address.port == row.port)
        #expect(address.pairingCode == row.code)
        #expect(address.baseURL.absoluteString == "http://\(row.host):\(row.port)")
        #expect(address.display == "\(row.host):\(row.port)")
    }

    @Test(arguments: [
        RejectedAddress(input: "", error: .empty),
        RejectedAddress(input: "   ", error: .empty),
        RejectedAddress(input: "https://192.168.1.20", error: .unsupportedScheme),
        RejectedAddress(input: "ftp://x", error: .unsupportedScheme),
        RejectedAddress(input: ":", error: .badPort),
        RejectedAddress(input: "192.168.1.20:", error: .badPort),
        RejectedAddress(input: "192.168.1.20:0", error: .badPort),
        RejectedAddress(input: "192.168.1.20:65536", error: .badPort),
        RejectedAddress(input: "192.168.1.20:abc", error: .badPort),
        RejectedAddress(input: "192.168.1.256", error: .badHost),
        RejectedAddress(input: "192.168.001.1", error: .badHost),
        RejectedAddress(input: "1.2.3", error: .badHost),
        RejectedAddress(input: "user@192.168.1.20", error: .badHost),
        RejectedAddress(input: "[::1]:8787", error: .badHost),
        RejectedAddress(input: "pcé.local", error: .badHost),
        RejectedAddress(input: "my pc.local", error: .badHost),
        RejectedAddress(input: "a..b", error: .badHost),
        RejectedAddress(input: "-bad.local", error: .badHost),
        RejectedAddress(input: String(repeating: "a", count: 254), error: .badHost),
        RejectedAddress(input: "192.168.1.20/photos", error: .unexpectedPath),
        RejectedAddress(input: "192.168.1.20?x=1", error: .unexpectedPath),
        RejectedAddress(input: "192.168.1.20/#pair=", error: .badPairingFragment),
        RejectedAddress(input: "192.168.1.20/#pair=AB-CD", error: .badPairingFragment),
        RejectedAddress(input: "192.168.1.20/#other=1", error: .badPairingFragment),
    ])
    func rejects(_ row: RejectedAddress) {
        let result = ServerAddress.parse(row.input)
        #expect(result == .failure(row.error))
    }

    @Test func everyErrorHasAPlainEnglishMessage() {
        let all: [ServerAddressError] = [.empty, .unsupportedScheme, .badHost, .badPort, .unexpectedPath, .badPairingFragment]
        let messages = Set(all.map(\.userMessage))
        #expect(messages.count == all.count)
        #expect(messages.allSatisfy { !$0.isEmpty })
    }

    @Test func defaultPortIsTheServerDefault() {
        #expect(ServerAddress.defaultPort == 8787)
    }
}
