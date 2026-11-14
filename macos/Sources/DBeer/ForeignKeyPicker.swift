import Foundation

struct ForeignKeyPickerFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ForeignKeyPickerRow: Identifiable {
    let id = UUID()
    let values: [ChangeValue]
}

/// Only exact returned transport values can enter the source draft.
enum ForeignKeyPickerValues {
    @MainActor static func canonicalColumns(_ grid: GridDraft) throws -> [ResultColumn] {
        guard let source = grid.querySource else { return grid.columns }
        guard source.isEditable, source.valid(for: grid.columns),
              sameTable(.init(schema: source.schema, name: source.table, kind: "table"), grid.reference) else {
            throw ForeignKeyPickerFailure("The query result has incomplete or ambiguous source-column provenance.")
        }
        return grid.columns.indices.map { index in
            let displayed = grid.columns[index], native = source.columns[index]
            return ResultColumn(index: index, name: native.name, typeOid: displayed.typeOid,
                engine: displayed.engine, nativeType: native.nativeType, encoding: displayed.encoding,
                typeIdentity: displayed.typeIdentity)
        }
    }
    static func sameValue(_ first: ChangeValue, _ second: ChangeValue) -> Bool {
        first.kind == second.kind && first.value.map { Data($0.utf8) } == second.value.map { Data($0.utf8) }
    }

    static func sameValues(_ first: [ChangeValue], _ second: [ChangeValue]) -> Bool {
        first.count == second.count && zip(first, second).allSatisfy { sameValue($0.0, $0.1) }
    }

    static func sameTable(_ first: TableReference, _ second: TableReference) -> Bool {
        Data(first.schema.utf8) == Data(second.schema.utf8) && Data(first.name.utf8) == Data(second.name.utf8) && first.kind == second.kind
    }

    static func sameKey(_ first: TableForeignKey, _ second: TableForeignKey) -> Bool {
        first.id == second.id && first.columns.count == second.columns.count &&
            zip(first.columns, second.columns).allSatisfy {
                $0.0.position == $0.1.position && Data($0.0.source.utf8) == Data($0.1.source.utf8) && Data($0.0.target.utf8) == Data($0.1.target.utf8)
            }
    }

    static func sourceIndices(key: TableForeignKey, columns: [ResultColumn]) throws -> [Int] {
        guard key.isValid else { throw ForeignKeyPickerFailure("The foreign-key mapping is incomplete. Refresh the table metadata.") }
        return try key.columns.map { pair in
            let matches = columns.indices.filter { Data(columns[$0].name.utf8) == Data(pair.source.utf8) }
            guard matches.count == 1, let index = matches.first else {
                throw ForeignKeyPickerFailure("Every source key column must appear exactly once in this table view.")
            }
            return index
        }
    }

    static func assignments(key: TableForeignKey, sourceColumns: [ResultColumn],
                            targetColumns: [ResultColumn], values: [ChangeValue]) throws -> [Int: ChangeValue] {
        let source = try sourceIndices(key: key, columns: sourceColumns)
        guard values.count == targetColumns.count else { throw ForeignKeyPickerFailure("The referenced row is incomplete. Search again.") }
        var result: [Int: ChangeValue] = [:]
        for (position, pair) in key.columns.enumerated() {
            let matches = targetColumns.indices.filter { Data(targetColumns[$0].name.utf8) == Data(pair.target.utf8) }
            guard matches.count == 1, let target = matches.first else {
                throw ForeignKeyPickerFailure("The referenced row has ambiguous or missing key columns.")
            }
            let value = values[target]
            let column = sourceColumns[source[position]]
            if column.engine == .sqlite {
                guard let typed = value.sqliteValue, typed.valid else {
                    throw ForeignKeyPickerFailure("Choose a referenced row with complete, non-NULL SQLite key values.")
                }
            } else {
                guard ["text", "binary"].contains(value.kind), let text = value.value,
                      text.utf8.count <= 1_024 * 1_024,
                      (value.kind == "binary") == (column.encoding == "base64"),
                      value.kind != "binary" || Data(base64Encoded: text)?.base64EncodedString() == text else {
                    throw ForeignKeyPickerFailure("This referenced key cannot be represented exactly by the source column.")
                }
            }
            result[source[position]] = value
        }
        return result
    }
}

extension GridDraft {
    /// Validate the entire composite edit before publishing one new row value.
    func stageForeignKey(_ assignments: [Int: ChangeValue], rowID: UUID,
                         expectedValues: [ChangeValue]) throws {
        guard canEdit, !isPreviewing, !hasInlineDraft,
              let row = rows.firstIndex(where: { $0.id == rowID }), canEditRow(row),
              ForeignKeyPickerValues.sameValues(rows[row].values, expectedValues), !assignments.isEmpty,
              assignments.keys.allSatisfy({ editableColumns.contains($0) && rows[row].values.indices.contains($0) }) else {
            throw ForeignKeyPickerFailure("The source row or its editing context changed. Close the picker and choose the value again.")
        }
        var changed = rows[row]
        for (column, value) in assignments {
            changed.values[column] = value
            let unchanged = changed.original.map { ForeignKeyPickerValues.sameValue($0[column], value) } == true
            changed.assignments[column] = unchanged ? nil : value
        }
        rows[row] = changed
        preview = nil
        error = nil
        notice = "Related key staged locally. Review SQL and Apply to save the change."
    }
}

@MainActor
final class ForeignKeyPickerModel: ObservableObject, Identifiable {
    typealias Read = @MainActor (CatalogRequest) async throws -> BackendMessage
    let id = UUID()
    let key: TableForeignKey
    let engine: DatabaseEngine
    let typedSQLiteFilters: Bool
    @Published private(set) var columns: [ResultColumn] = []
    @Published private(set) var rows: [ForeignKeyPickerRow] = []
    @Published private(set) var metadata: [[String: String]] = []
    @Published private(set) var isBusy = false
    @Published private(set) var page = 0
    @Published private(set) var hasNext = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published var search = ""
    @Published var exactMatch = false
    @Published var searchColumn = ""
    @Published var sqliteSearchType = "text"
    @Published var displayColumns: Set<Data> = []
    private let sourceColumns: [ResultColumn]
    private let isCurrent: @MainActor () -> Bool
    private let read: Read
    private let cancelRead: @MainActor () async -> Void
    private let stage: @MainActor ([Int: ChangeValue]) throws -> Void
    private var generation: UInt64 = 0
    private var closed = false
    private var loadedSearch: (text: String, column: String, exact: Bool, storageType: String)?

    init(key: TableForeignKey, engine: DatabaseEngine, sourceColumns: [ResultColumn],
         typedSQLiteFilters: Bool = false, isCurrent: @escaping @MainActor () -> Bool,
         read: @escaping Read, cancel: @escaping @MainActor () async -> Void,
         stage: @escaping @MainActor ([Int: ChangeValue]) throws -> Void) {
        self.key = key; self.engine = engine; self.sourceColumns = sourceColumns
        self.typedSQLiteFilters = typedSQLiteFilters
        self.isCurrent = isCurrent; self.read = read; cancelRead = cancel; self.stage = stage
    }

    var hasUnappliedSearch: Bool {
        guard let loadedSearch else { return false }
        return Data(loadedSearch.text.utf8) != Data(search.utf8) || Data(loadedSearch.column.utf8) != Data(searchColumn.utf8) ||
            loadedSearch.exact != exactMatch || loadedSearch.storageType != sqliteSearchType
    }

    var searchableColumns: [[String: String]] {
        metadata.filter { Self.isText($0["nativeType"] ?? "") }
    }

    var displayOptions: [String] { metadata.compactMap { $0["name"] } }

    private func requireCurrent(_ expected: UInt64) throws {
        guard !closed, generation == expected, !Task.isCancelled, isCurrent() else {
            throw ForeignKeyPickerFailure("The source table, connection or row changed. Close this picker and open it again.")
        }
    }

    func load() async {
        guard !isBusy, metadata.isEmpty, !closed else { return }
        isBusy = true; error = nil
        generation &+= 1
        let expected = generation
        defer { isBusy = false }
        do {
            try requireCurrent(expected)
            let reply = try await read(.init(kind: "columns", schema: key.target.schema,
                object: key.target.name, objectKind: "table"))
            try requireCurrent(expected)
            let records = reply.catalogRecords
            let names = records.compactMap { $0["name"] }
            guard reply.truncated != true, (reply.rowCount ?? Int64(records.count)) <= Int64(records.count),
                  !records.isEmpty, records.count <= 10_000,
                  names.count == records.count, Set(names.map { Data($0.utf8) }).count == names.count,
                  key.columns.allSatisfy({ pair in names.contains { Data($0.utf8) == Data(pair.target.utf8) } }) else {
                throw ForeignKeyPickerFailure("The referenced table's complete key metadata is unavailable. Check SELECT permissions and refresh the table.")
            }
            metadata = records
            let descriptions = searchableColumns.compactMap { $0["name"] }.filter { name in
                !key.columns.contains { Data($0.target.utf8) == Data(name.utf8) }
            }
            displayColumns = Set(descriptions.prefix(3).map { Data($0.utf8) })
            searchColumn = descriptions.first ?? key.columns[0].target
            exactMatch = descriptions.isEmpty
            if engine == .sqlite, let selected = records.first(where: { Data(($0["name"] ?? "").utf8) == Data(searchColumn.utf8) }) {
                let native = (selected["nativeType"] ?? "").lowercased()
                sqliteSearchType = native.contains("int") ? "integer" : native.contains("blob") ? "blob" :
                    native.contains("real") || native.contains("float") || native.contains("double") ? "real" : "text"
            }
            notice = reply.displayNotice
        } catch { self.error = error.localizedDescription }
        guard error == nil else { return }
        isBusy = false
        await searchRows()
    }

    func searchRows(page requestedPage: Int = 0) async {
        guard !isBusy, !closed, !metadata.isEmpty, (0...49).contains(requestedPage) else { return }
        isBusy = true; error = nil
        generation &+= 1
        let expected = generation
        let query = (text: search, column: searchColumn, exact: exactMatch, storageType: sqliteSearchType)
        defer { isBusy = false }
        do {
            try requireCurrent(expected)
            guard requestedPage == 0 || !hasUnappliedSearch else {
                throw ForeignKeyPickerFailure("Search again to apply changed search settings before changing pages.")
            }
            let expression = try filter(text: query.text, column: query.column, exact: query.exact, storageType: query.storageType)
            let reply = try await read(.init(kind: "browse", schema: key.target.schema, object: key.target.name,
                objectKind: "table", page: requestedPage, filterExpression: expression))
            try requireCurrent(expected)
            let returnedColumns = reply.columns ?? []
            let returnedRows = reply.rows ?? []
            guard returnedColumns.count == metadata.count, returnedRows.count <= 200,
                  returnedColumns.allSatisfy({ $0.engine == engine }),
                  returnedColumns.map({ Data($0.name.utf8) }) == metadata.compactMap({ $0["name"].map { Data($0.utf8) } }),
                  returnedRows.allSatisfy({ $0.count == returnedColumns.count }),
                  SQLiteValue.validMatrix(reply.sqliteValues, rows: returnedRows.count, columns: returnedColumns.count),
                  NativeValue.validMatrix(reply.nativeValues, rows: returnedRows.count, columns: returnedColumns.count),
                  (engine != .sqlite || NativeValue.matchesSQLite(reply.nativeValues, storage: reply.sqliteValues)),
                  engine != .sqlite || reply.sqliteValues != nil else {
                throw ForeignKeyPickerFailure("The referenced table changed or returned an incomplete row. Close and reopen this picker.")
            }
            var loaded: [ForeignKeyPickerRow] = []
            for (rowIndex, values) in returnedRows.enumerated() {
                let typed = values.enumerated().map { column, value -> ChangeValue in
                    if let storage = reply.sqliteValues { return storage[rowIndex][column].changeValue }
                    if let native = reply.nativeValues?[rowIndex][column] {
                        return native.flatChangeValue(for: returnedColumns[column]) ?? .init(kind: "unresolved", value: value)
                    }
                    guard let value else { return .null }
                    return .init(kind: returnedColumns[column].encoding == "base64" ? "binary" : "text", value: value)
                }
                loaded.append(.init(values: typed))
            }
            columns = returnedColumns; rows = loaded; page = requestedPage
            hasNext = returnedRows.count == 200 && requestedPage < 49 && reply.truncated != true
            loadedSearch = query
            notice = reply.displayNotice
            if reply.truncated == true { notice = "These referenced rows are incomplete. Narrow the search before choosing a value." }
            if requestedPage == 49 { notice = "The picker is limited to 10,000 rows. Narrow the search to find other records." }
        } catch { self.error = error.localizedDescription }
    }

    func choiceError(_ row: ForeignKeyPickerRow) -> String? {
        do { _ = try ForeignKeyPickerValues.assignments(key: key, sourceColumns: sourceColumns, targetColumns: columns, values: row.values); return nil }
        catch { return error.localizedDescription }
    }

    func choose(_ row: ForeignKeyPickerRow) -> Bool {
        guard !isBusy, !closed, !hasUnappliedSearch, rows.contains(where: { $0.id == row.id }) else { return false }
        do {
            try requireCurrent(generation)
            let assignments = try ForeignKeyPickerValues.assignments(key: key, sourceColumns: sourceColumns,
                targetColumns: columns, values: row.values)
            try stage(assignments)
            closed = true
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func stop() async {
        generation &+= 1
        await cancelRead()
    }

    func close() async {
        closed = true
        await stop()
    }

    func label(_ row: ForeignKeyPickerRow, keysOnly: Bool = false, preview: Bool = true) -> String {
        let names = keysOnly ? Set(key.columns.map { Data($0.target.utf8) }) : displayColumns
        return columns.indices.filter { names.contains(Data(columns[$0].name.utf8)) }.map { index in
            let value = row.values[index]
            let label: String
            if value.kind == "null" { label = "SQL NULL" }
            else if value.kind == "binary" || value.kind == "sqliteBlob" { label = "Base64 " + String(reflecting: value.value ?? "") }
            else if value.kind == "sqliteText" || Self.isText(columns[index].nativeType) { label = String(reflecting: value.displayText ?? "") }
            else { label = value.displayText ?? "" }
            let text = preview && label.count > 160 ? String(label.prefix(160)) + "…" : label
            return columns[index].name + " = " + text
        }.joined(separator: " · ")
    }

    private func filter(text: String, column: String, exact: Bool, storageType: String) throws -> CatalogFilterExpression? {
        let typedText = engine == .sqlite && exact && typedSQLiteFilters && storageType == "text"
        guard text.utf8.count <= 4_096, typedText || !text.contains("\0") else {
            throw ForeignKeyPickerFailure("Search text must contain at most 4 KiB without NUL characters.")
        }
        guard !text.isEmpty else { return nil }
        guard let definition = metadata.first(where: { Data(($0["name"] ?? "").utf8) == Data(column.utf8) }) else {
            throw ForeignKeyPickerFailure("Choose an available search column.")
        }
        let nativeType = definition["nativeType"] ?? ""
        guard exact || Self.isText(nativeType) else {
            throw ForeignKeyPickerFailure("Use Exact Match to search this key by its native value. Binary keys use Base64.")
        }
        if engine == .sqlite, exact, !typedSQLiteFilters, storageType != "text" {
            throw ForeignKeyPickerFailure("Reconnect with a helper that supports typed SQLite key filters.")
        }
        if engine == .sqlite, exact, typedSQLiteFilters {
            let value: SQLiteValue
            switch storageType {
            case "integer":
                guard let number = Int64(text), String(number) == text else { throw ForeignKeyPickerFailure("Enter the exact signed 64-bit integer key.") }
                value = .init(type: "integer", value: text)
            case "real":
                guard let number = Double(text), !number.isNaN else { throw ForeignKeyPickerFailure("Enter a valid SQLite real key.") }
                value = .init(type: "real", value: String(format: "%016llx", number.bitPattern))
            case "blob":
                guard let bytes = Data(base64Encoded: text), bytes.base64EncodedString() == text else { throw ForeignKeyPickerFailure("Enter the binary key as Base64.") }
                value = .init(type: "blob", value: text)
            case "text": value = .init(type: "text", value: Data(text.utf8).base64EncodedString())
            default: throw ForeignKeyPickerFailure("Choose the SQLite storage type of the exact key value.")
            }
            return .predicate(.init(column: column, operator: "eq", sqliteValue: value))
        }
        return .predicate(.init(column: column, operator: exact ? "eq" : "contains", value: text))
    }

    private static func isText(_ native: String) -> Bool {
        let base = native.lowercased().split(separator: "(").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return ["text", "varchar", "character varying", "character", "char", "bpchar", "name", "tinytext", "mediumtext", "longtext"].contains(base)
    }
}
