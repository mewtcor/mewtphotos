// The device key the PC issues at pairing. It is the only credential the phone holds, so it lives
// in a wrapper that prints as "<redacted>" through every standard Swift description path and
// cannot be serialised by accident. Phone-side counterpart of the token rules in server/security.ts.

public struct DeviceKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    /// The single way to read the key. Only ServerClient calls it, to build the Authorization header.
    public func revealForAuthorization() -> String {
        raw
    }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: [Mirror.Child]()) }
}
