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

    func password(for id: UUID) async throws -> String? {
        try await secret(for: id, purpose: .databasePassword)
    }

    func secret(for id: UUID, purpose: ConnectionCredentialPurpose) async throws -> String? {
        var query = try itemQuery(id, purpose: purpose)
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

    func savePassword(_ password: String, for id: UUID) async throws {
        try await saveSecret(password, for: id, purpose: .databasePassword)
    }

    func saveSecret(_ password: String, for id: UUID, purpose: ConnectionCredentialPurpose) async throws {
        let query = try itemQuery(id, purpose: purpose)
        let data = Data(password.utf8)
        let status = SecItemUpdate(query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = try itemQuery(id, purpose: purpose, adding: true)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw ConnectionLibraryError.credentialWrite
            }
        } else if status != errSecSuccess { throw ConnectionLibraryError.credentialWrite }
    }

    func deletePassword(for id: UUID) async throws {
        try await deleteSecret(for: id, purpose: .databasePassword)
    }

    func deleteSecret(for id: UUID, purpose: ConnectionCredentialPurpose) async throws {
        let status = SecItemDelete(try itemQuery(id, purpose: purpose) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ConnectionLibraryError.credentialDelete
        }
    }

    private func itemQuery(_ id: UUID, purpose: ConnectionCredentialPurpose = .databasePassword, adding: Bool = false) throws -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: purpose == .databasePassword ? id.uuidString : id.uuidString + ":" + purpose.rawValue]
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
