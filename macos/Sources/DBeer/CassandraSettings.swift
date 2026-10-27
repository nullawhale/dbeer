import Foundation
import Darwin

/// Native connection validation is shared by profile, launch and editor paths.
/// The helper remains authoritative for database-specific connection policy.
enum CassandraSettings {
    static let consistencyLevels = ["ONE", "TWO", "THREE", "QUORUM", "ALL", "LOCAL_QUORUM", "EACH_QUORUM", "LOCAL_ONE"]

    static func isNumericAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return host.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1 }
    }

    static func contactPoints(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

extension ConnectionSettings {
    var hasValidNativeFields: Bool {
        if let passwordCommand, !passwordCommand.isValid || !password.isEmpty || user.isEmpty { return false }
        guard ssh?.isValid != false else { return false }
        let fields = [host, database, user, localDatacenter ?? ""] + (contactPoints ?? [])
        guard fields.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 1_024 }),
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...65_535).contains(port), engine.sslModes.contains(sslMode) else { return false }
        if engine == .mongodb {
            func validHost(_ value: String) -> Bool {
                !value.isEmpty && !value.contains(where: { " \t\n\r/@?#,\\[]%".contains($0) }) &&
                    (!value.contains(":") || CassandraSettings.isNumericAddress(value))
            }
            return mongodb?.isValid != false && localDatacenter == nil && consistency == nil &&
                !(user.isEmpty && !password.isEmpty) && validHost(host) &&
                (contactPoints?.count ?? 0) <= 32 && contactPoints?.isEmpty != true && (contactPoints ?? []).allSatisfy(validHost) &&
                (mongodb?.directConnection != true || (contactPoints?.count ?? 0) <= 1) &&
                (ssh == nil || mongodb?.directConnection == true && contactPoints == nil)
        }
        guard mongodb == nil else { return false }
        if engine == .cassandra {
            if ssh != nil, !(contactPoints ?? [host]).allSatisfy(CassandraSettings.isNumericAddress) { return false }
            return (contactPoints?.count ?? 0) <= 32 && !(contactPoints?.isEmpty ?? false) && (contactPoints ?? []).allSatisfy {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } && CassandraSettings.consistencyLevels.contains(consistency ?? "LOCAL_QUORUM") &&
                !(user.isEmpty && !password.isEmpty)
        }
        return !database.isEmpty && !user.isEmpty && contactPoints == nil && localDatacenter == nil && consistency == nil
    }
}
