// Where the device key is kept. Core only knows this protocol; the app target supplies the
// Keychain-backed type, and tests use the in-memory one below. Methods are synchronous because the
// Keychain calls are, and statuses are plain numbers (OSStatus) so Core stays free of Apple frameworks.
import Foundation

public enum KeyLoadResult: Equatable, Sendable {
    case found(DeviceKey)
    case notFound
    case failed(Int32)
}

public enum KeyStoreStatus: Equatable, Sendable {
    case ok
    case failed(Int32)
}

public protocol DeviceKeyStoring: Sendable {
    func load() -> KeyLoadResult
    func save(_ key: DeviceKey) -> KeyStoreStatus
    func delete() -> KeyStoreStatus
}

/// Test double with failure injection and call counters. The one unchecked Sendable conformance in
/// Core: the protocol is synchronous, so the state is guarded by a lock instead of an actor.
public final class InMemoryDeviceKeyStore: DeviceKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DeviceKey?
    private var loadFailureValue: Int32?
    private var saveFailureValue: Int32?
    private var deleteFailureValue: Int32?
    private var saveCountValue = 0
    private var deleteCountValue = 0

    public init(key: DeviceKey? = nil) {
        self.stored = key
    }

    public var loadFailure: Int32? {
        get { locked { loadFailureValue } }
        set { locked { loadFailureValue = newValue } }
    }

    public var saveFailure: Int32? {
        get { locked { saveFailureValue } }
        set { locked { saveFailureValue = newValue } }
    }

    public var deleteFailure: Int32? {
        get { locked { deleteFailureValue } }
        set { locked { deleteFailureValue = newValue } }
    }

    public var saveCount: Int { locked { saveCountValue } }
    public var deleteCount: Int { locked { deleteCountValue } }

    public func load() -> KeyLoadResult {
        locked { () -> KeyLoadResult in
            if let status = loadFailureValue { return .failed(status) }
            if let stored { return .found(stored) }
            return .notFound
        }
    }

    public func save(_ key: DeviceKey) -> KeyStoreStatus {
        locked { () -> KeyStoreStatus in
            saveCountValue += 1
            if let status = saveFailureValue { return .failed(status) }
            stored = key
            return .ok
        }
    }

    public func delete() -> KeyStoreStatus {
        locked { () -> KeyStoreStatus in
            deleteCountValue += 1
            if let status = deleteFailureValue { return .failed(status) }
            stored = nil
            return .ok
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
