import Foundation
import Security

/// Where an Immich account's session token lives (ADR 0046 §2): the login Keychain, one
/// generic-password item per account, never SQLite. The account's identity names the
/// item, so removing the account removes exactly its token.
nonisolated protocol ImmichSessionStoring: Sendable {
    func saveToken(_ token: String, for account: DeviceIdentity) throws
    /// The saved token, or nil when the account has none (never logged in, or logged out).
    func token(for account: DeviceIdentity) throws -> String?
    func deleteToken(for account: DeviceIdentity) throws
}

nonisolated struct ImmichKeychainSessionStore: ImmichSessionStoring {
    /// The Keychain service every item shares; the dev and installed apps keep separate
    /// items because their bundle identifiers differ (ADR 0030).
    let service: String

    init(service: String = "\(Bundle.main.bundleIdentifier ?? "net.melisma.Otos").immich-session") {
        self.service = service
    }

    func saveToken(_ token: String, for account: DeviceIdentity) throws {
        let query = baseQuery(for: account)
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var item = query
            item[kSecValueData as String] = Data(token.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else {
                throw ImmichSessionStoreError.keychain(status: added)
            }
        default:
            throw ImmichSessionStoreError.keychain(status: status)
        }
    }

    func token(for account: DeviceIdentity) throws -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
                throw ImmichSessionStoreError.unreadableItem
            }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw ImmichSessionStoreError.keychain(status: status)
        }
    }

    func deleteToken(for account: DeviceIdentity) throws {
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ImmichSessionStoreError.keychain(status: status)
        }
    }

    private func baseQuery(for account: DeviceIdentity) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }
}

nonisolated enum ImmichSessionStoreError: Error, Equatable {
    /// A Keychain call failed with this `OSStatus`.
    case keychain(status: OSStatus)
    /// The item exists but holds no UTF-8 token.
    case unreadableItem
}
