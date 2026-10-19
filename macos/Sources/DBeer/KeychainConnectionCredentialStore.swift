import Foundation
import Security

actor KeychainConnectionCredentialStore: ConnectionCredentialStore {
    private let service: String
    private let keychainURL: URL?

    /// Production uses the user's Keychain. Tests can target a temporary file
    /// explicitly without changing the user's default Keychain or search list.
    init(service: String = "dev.dbeer.connections", keychainURL: URL? = nil) {
        self.service = service
        self.keychainURL = keychainURL
    }

    func password(for id: UUID) throws -> String? {
        var query = try itemQuery(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw ConnectionLibraryError.credentialRead
        }
        return password
    }

    func savePassword(_ password: String, for id: UUID) throws {
        let query = try itemQuery(id)
        let data = Data(password.utf8)
        let status = SecItemUpdate(query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = try itemQuery(id, adding: true)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw ConnectionLibraryError.credentialWrite
            }
        } else if status != errSecSuccess { throw ConnectionLibraryError.credentialWrite }
    }

    func deletePassword(for id: UUID) throws {
        let status = SecItemDelete(try itemQuery(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ConnectionLibraryError.credentialDelete
        }
    }

    private func itemQuery(_ id: UUID, adding: Bool = false) throws -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString]
        if let keychainURL {
            var keychain: SecKeychain?
            guard SecKeychainOpen(keychainURL.path, &keychain) == errSecSuccess, let keychain else {
                throw ConnectionLibraryError.credentialRead
            }
            if adding { query[kSecUseKeychain as String] = keychain }
            else { query[kSecMatchSearchList as String] = [keychain] }
        }
        return query
    }
}
