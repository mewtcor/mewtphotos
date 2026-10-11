// Keeps the device key in the Keychain. Core only sees DeviceKeyStoring; this is the Apple-side
// type that backs it. Renaming the service or the account below orphans every stored key.
import Foundation
import Security
import PhotoSyncCore

struct KeychainDeviceKeyStore: DeviceKeyStoring {
    private static let service = "photosync.device-key"
    private static let account = "device-key"

    // Only this device, and only after the first unlock, so the key is readable when the phone
    // runs a background refresh but never leaves this phone through a device transfer.
    private func itemQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    func load() -> KeyLoadResult {
        var query = itemQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess else { return .failed(status) }
        guard let data = item as? Data, let raw = String(data: data, encoding: .utf8) else {
            return .failed(errSecDecode)
        }
        return .found(DeviceKey(raw))
    }

    func save(_ key: DeviceKey) -> KeyStoreStatus {
        _ = SecItemDelete(itemQuery() as CFDictionary)
        var attributes = itemQuery()
        attributes[kSecValueData as String] = Data(key.revealForAuthorization().utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        return status == errSecSuccess ? .ok : .failed(status)
    }

    func delete() -> KeyStoreStatus {
        let status = SecItemDelete(itemQuery() as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return .ok }
        return .failed(status)
    }
}
