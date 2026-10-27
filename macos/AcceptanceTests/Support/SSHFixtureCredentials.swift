import Foundation
import Security

// This fixture utility accepts synthetic credentials only through stdin. It
// grants access to the exact signed application copy without changing Keychain
// defaults, trust settings, or the search list.
struct Request: Decodable {
    var action: String
    var profileID: String
    var appPath: String
    var databasePassword: String?
    var passphrase: String?
}

enum FixtureFailure: Error { case invalidRequest, security(OSStatus) }

func perform() throws {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard data.count < 65536 else { throw FixtureFailure.invalidRequest }
    let request = try JSONDecoder().decode(Request.self, from: data)
    guard let id = UUID(uuidString: request.profileID), id.uuidString == request.profileID,
          request.appPath.hasPrefix("/"), request.appPath.hasSuffix("/DBeer.app") else { throw FixtureFailure.invalidRequest }
    var accounts = [(id.uuidString, request.databasePassword)]
    if request.action == "delete" || request.passphrase != nil {
        accounts.append((id.uuidString + ":sshPassphrase", request.passphrase))
    }
    let service = "dev.dbeer.connections"
    if request.action == "delete" {
        for (account, _) in accounts {
            let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw FixtureFailure.security(status) }
        }
        print("{\"deleted\":true}")
        return
    }
    guard request.action == "create", accounts.allSatisfy({ $0.1 != nil }) else { throw FixtureFailure.invalidRequest }
    var trusted: SecTrustedApplication?
    let path = request.appPath + "/Contents/MacOS/DBeer"
    var status = SecTrustedApplicationCreateFromPath(path, &trusted)
    guard status == errSecSuccess, let trusted else { throw FixtureFailure.security(status) }
    var trustedUtility: SecTrustedApplication?
    status = SecTrustedApplicationCreateFromPath(nil, &trustedUtility)
    guard status == errSecSuccess, let trustedUtility else { throw FixtureFailure.security(status) }
    var access: SecAccess?
    status = SecAccessCreate("DBeer owned SSH acceptance fixture" as CFString, [trusted, trustedUtility] as CFArray, &access)
    guard status == errSecSuccess, let access else { throw FixtureFailure.security(status) }
    for (account, _) in accounts {
        let query = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                     kSecAttrAccount as String: account] as [String: Any]
        guard SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound else { throw FixtureFailure.invalidRequest }
    }
    for (account, secret) in accounts {
        let query = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                     kSecAttrAccount as String: account] as [String: Any]
        var attributes = query
        attributes[kSecValueData as String] = Data(secret!.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrAccess as String] = access
        status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw FixtureFailure.security(status) }
    }
    print("{\"created\":true}")
}

do { try perform() }
catch FixtureFailure.security(let status) { FileHandle.standardError.write(Data("Owned SSH fixture credential operation failed (Security status \(status)).\n".utf8)); exit(1) }
catch { FileHandle.standardError.write(Data("Owned SSH fixture credential operation failed.\n".utf8)); exit(1) }
