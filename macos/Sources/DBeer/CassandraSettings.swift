import Foundation

/// Native connection validation is shared by profile, launch and editor paths.
/// The helper remains authoritative for database-specific connection policy.
enum CassandraSettings {
    static let consistencyLevels = ["ONE", "TWO", "THREE", "QUORUM", "ALL", "LOCAL_QUORUM", "EACH_QUORUM", "LOCAL_ONE"]

    static func contactPoints(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

extension ConnectionSettings {
    var hasValidNativeFields: Bool {
        let fields = [host, database, user, localDatacenter ?? ""] + (contactPoints ?? [])
        guard fields.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 1_024 }),
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...65_535).contains(port), engine.sslModes.contains(sslMode) else { return false }
        if engine == .cassandra {
            return (contactPoints?.count ?? 0) <= 32 && !(contactPoints?.isEmpty ?? false) && (contactPoints ?? []).allSatisfy {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } && CassandraSettings.consistencyLevels.contains(consistency ?? "LOCAL_QUORUM") &&
                !(user.isEmpty && !password.isEmpty)
        }
        return !database.isEmpty && !user.isEmpty && contactPoints == nil && localDatacenter == nil && consistency == nil
    }
}
