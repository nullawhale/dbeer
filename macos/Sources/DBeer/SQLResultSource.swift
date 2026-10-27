import Foundation

/// Connection-local evidence supplied by the adapter, never inferred from labels.
struct SQLResultSource: Codable, Sendable, Equatable {
    var schema: String
    var table: String
    var columns: [SQLResultSourceColumn]
    var readOnlyReason: String?

    var canOpenRow: Bool { !schema.isEmpty && !table.isEmpty && columns.contains { $0.primaryKey > 0 } }
    var isEditable: Bool { canOpenRow && (readOnlyReason ?? "").isEmpty }

    func valid(for resultColumns: [ResultColumn]) -> Bool {
        func validText(_ text: String, limit: Int) -> Bool {
            text.utf8.count <= limit && !text.contains("\0")
        }
        guard validText(schema, limit: 256), validText(table, limit: 256),
              readOnlyReason.map({ !$0.isEmpty && validText($0, limit: 1_024) }) ?? true else { return false }
        if schema.isEmpty || table.isEmpty {
            return schema.isEmpty && table.isEmpty && columns.isEmpty && readOnlyReason != nil
        }
        guard !columns.isEmpty, columns.count <= 4_096, columns.count == resultColumns.count,
              resultColumns.allSatisfy({ $0.engine == .postgresql || $0.engine == .mysql }),
              Set(resultColumns.map(\.engine)).count == 1,
              Set(columns.map(\.name)).count == columns.count,
              Set(columns.map(\.tableIndex)).count == columns.count,
              columns.allSatisfy({ !$0.name.isEmpty && validText($0.name, limit: 256) &&
                  !$0.nativeType.isEmpty && validText($0.nativeType, limit: 65_536) &&
                  (0..<4_096).contains($0.tableIndex) && (0...4_096).contains($0.primaryKey) &&
                  (!$0.generated || !$0.editable) }) else { return false }
        let keys = columns.filter { $0.primaryKey > 0 }.map(\.primaryKey).sorted()
        guard !keys.isEmpty, keys == Array(1...keys.count) else { return false }
        return !isEditable || columns.map(\.tableIndex).sorted() == Array(columns.indices)
    }

    func filters(row: [ChangeValue]) -> [CatalogFilter]? {
        guard canOpenRow, row.count == columns.count else { return nil }
        var filters: [CatalogFilter] = []
        for index in columns.indices.sorted(by: { columns[$0].primaryKey < columns[$1].primaryKey }) where columns[index].primaryKey > 0 {
            let cell = row[index]
            guard ["text", "binary"].contains(cell.kind), let value = cell.value else { return nil }
            if cell.kind == "binary", Data(base64Encoded: value) == nil { return nil }
            filters.append(CatalogFilter(column: columns[index].name, operator: "eq", value: value))
        }
        return filters.isEmpty ? nil : filters
    }
}

struct SQLResultSourceColumn: Codable, Sendable, Equatable {
    var name: String
    var nativeType: String
    var tableIndex: Int
    var primaryKey: Int
    var editable: Bool
    var generated: Bool
}

struct SQLResultSelection: Hashable {
    var executionID: UUID
    var resultSetIndex: Int
}

@MainActor
extension WorkspaceModel {
    func matchesResultSourceProfile(_ profile: SavedConnection) -> Bool {
        guard let port = Int(port) else { return false }
        return profile.matches(ConnectionSettings(host: host, port: port, database: database,
            user: user, password: "", sslMode: sslMode, sslRootCert: sslRootCert.isEmpty ? nil : sslRootCert,
            engine: engine, policy: policy, contactPoints: contactPoints, localDatacenter: localDatacenter,
            consistency: consistency, ssh: ssh, passwordCommand: passwordCommand))
    }
}
