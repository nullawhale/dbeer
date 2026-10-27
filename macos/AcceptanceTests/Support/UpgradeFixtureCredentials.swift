import Darwin
import Foundation
import Security

// Provision only the new UUIDs allocated by the baseline application's import.
// Secrets arrive through stdin, before baseline queries, and never reach the
// candidate app's arguments, environment, configuration, or startup channel.
private struct Request: Decodable {
    let action: String
    let profileID: String
    let appPath: String
    let ownedAccountsFile: String
    let databasePassword: String?
}

private struct OwnedAccounts: Decodable {
    let service: String
    let accounts: [String]
}

private enum FixtureFailure: Error { case invalidRequest, security(OSStatus) }
private var stage = "request"
private var lookupMetadata: [String: Any] = [:]

private func perform() throws {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard input.count < 65_536 else { throw FixtureFailure.invalidRequest }
    let request = try JSONDecoder().decode(Request.self, from: input)
    guard let identifier = UUID(uuidString: request.profileID), identifier.uuidString == request.profileID,
          request.appPath.hasPrefix("/"), request.appPath.hasSuffix("/Applications/DBeer.app"),
          request.ownedAccountsFile.hasPrefix("/"),
          request.action == "inspect-empty" || request.action == "create" else {
        throw FixtureFailure.invalidRequest
    }
    stage = "owned-manifest"
    let attributes = try FileManager.default.attributesOfItem(atPath: request.ownedAccountsFile)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
          let permissions = attributes[.posixPermissions] as? NSNumber, permissions.intValue & 0o077 == 0,
          let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid() else {
        throw FixtureFailure.invalidRequest
    }
    let owned = try JSONDecoder().decode(OwnedAccounts.self,
        from: Data(contentsOf: URL(fileURLWithPath: request.ownedAccountsFile)))
    guard owned.service == "dev.dbeer.connections", owned.accounts.contains(identifier.uuidString) else {
        throw FixtureFailure.invalidRequest
    }
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: owned.service, kSecAttrAccount as String: identifier.uuidString]
    // Import creates an empty item. Verify it before the caller uses the system
    // security utility to delete that exact newly allocated, owned UUID.
    var existing: CFTypeRef?
    var lookup = query
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    lookup[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    stage = request.action == "inspect-empty" ? "empty-item-lookup" : "absent-item-lookup"
    let lookupStatus = SecItemCopyMatching(lookup as CFDictionary, &existing)
    lookupMetadata = ["lookupStatus": Int(lookupStatus), "returnedData": existing is Data,
                      "returnedEmptyData": (existing as? Data)?.isEmpty == true]
    if request.action == "inspect-empty" {
        guard lookupStatus == errSecSuccess else { throw FixtureFailure.security(lookupStatus) }
        guard let value = existing as? Data, value.isEmpty else { throw FixtureFailure.invalidRequest }
        print("{\"emptyVerified\":true}")
        return
    }
    // Never update or replace an existing item in the create step.
    guard lookupStatus == errSecItemNotFound else { throw FixtureFailure.security(lookupStatus) }
    guard let password = request.databasePassword, !password.isEmpty else { throw FixtureFailure.invalidRequest }
    stage = "trusted-application"
    var application: SecTrustedApplication?
    var status = SecTrustedApplicationCreateFromPath(request.appPath + "/Contents/MacOS/DBeer", &application)
    guard status == errSecSuccess, let application else { throw FixtureFailure.security(status) }
    stage = "trusted-utility"
    var utility: SecTrustedApplication?
    status = SecTrustedApplicationCreateFromPath(nil, &utility)
    guard status == errSecSuccess, let utility else { throw FixtureFailure.security(status) }
    stage = "create-access"
    var access: SecAccess?
    status = SecAccessCreate("DBeer owned update acceptance fixture" as CFString, [application, utility] as CFArray, &access)
    guard status == errSecSuccess, let access else { throw FixtureFailure.security(status) }
    var item = query
    item[kSecValueData as String] = Data(password.utf8)
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    item[kSecAttrAccess as String] = access
    stage = "add-item"
    status = SecItemAdd(item as CFDictionary, nil)
    guard status == errSecSuccess else { throw FixtureFailure.security(status) }
    print("{\"created\":true}")
}

private func reportFailure(status: OSStatus? = nil) {
    var result: [String: Any] = ["created": false, "stage": stage]
    result.merge(lookupMetadata) { _, value in value }
    if let status { result["securityStatus"] = Int(status) }
    // Only operation names, status codes and type/empty flags are emitted.
    // Never include request content or the underlying error's description.
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data)
    }
}

do { try perform() }
catch FixtureFailure.security(let status) {
    reportFailure(status: status)
    exit(1)
} catch {
    reportFailure()
    exit(1)
}
