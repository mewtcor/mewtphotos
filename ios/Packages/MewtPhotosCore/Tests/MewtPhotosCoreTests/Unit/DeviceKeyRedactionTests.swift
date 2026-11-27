// The device key must not leak through any standard Swift description path (log lines, error
// text, debugger-style dumps). Swift Testing selects this suite with `swift test --filter Redaction`.
import Testing
import MewtPhotosCore

@Suite struct DeviceKeyRedactionTests {
    private static let secret = "SECRET-KEY-VALUE-0123456789abcdef"
    private let key = DeviceKey(DeviceKeyRedactionTests.secret)

    @Test func interpolationHidesTheKey() {
        #expect(!"\(key)".contains(Self.secret))
        #expect("\(key)" == "<redacted>")
    }

    @Test func describingAndReflectingHideTheKey() {
        #expect(String(describing: key) == "<redacted>")
        #expect(String(reflecting: key) == "<redacted>")
    }

    @Test func dumpHidesTheKey() {
        var out = ""
        dump(key, to: &out)
        #expect(!out.contains(Self.secret))
    }

    @Test func containersHideTheKey() {
        #expect(!"\([key])".contains(Self.secret))
        #expect(!"\(["k": key])".contains(Self.secret))
        #expect(!"\(Optional(key))".contains(Self.secret))
    }

    @Test func mirrorHasNoChildren() {
        #expect(Mirror(reflecting: key).children.count == 0)
    }

    @Test func authorizationAccessorReturnsTheOriginal() {
        #expect(key.revealForAuthorization() == Self.secret)
    }
}
