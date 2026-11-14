import Combine
import Foundation

@MainActor
final class LogicalRelationshipEditorModel: ObservableObject, Identifiable {
    typealias Reader = @MainActor (LogicalRelationshipEndpoint, CatalogMetadataRequest) async throws -> [ERColumn]
    let id: UUID
    let relationshipID: UUID
    @Published var name: String
    @Published var sourceProfileID: UUID?
    @Published var targetProfileID: UUID?
    @Published var sourceSchema: String
    @Published var sourceName: String
    @Published var sourceKind: String
    @Published var targetSchema: String
    @Published var targetName: String
    @Published var targetKind: String
    @Published var columns: [LogicalRelationshipColumn]
    @Published private(set) var sourceColumns: [ERColumn] = []
    @Published private(set) var targetColumns: [ERColumn] = []
    @Published private(set) var suggestions: [LogicalRelationshipSuggestion] = []
    @Published private(set) var isReading = false
    @Published private(set) var isSaving = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var saved = false
    private(set) var closed = false
    private var origin: LogicalRelationshipOrigin
    private let profiles: @MainActor () -> [SavedConnection]
    private let reader: Reader
    private let isCurrent: @MainActor () -> Bool
    private let mayStart: @MainActor () -> Bool
    private let cancel: @MainActor (LogicalRelationshipEndpoint, CatalogMetadataRequest) -> Void
    private var pending: (LogicalRelationshipEndpoint, CatalogMetadataRequest)?
    private var loadedSource: LogicalRelationshipEndpoint?
    private var loadedTarget: LogicalRelationshipEndpoint?
    private var verified: LogicalRelationship?
    private var operation: UInt64 = 0

    init(id: UUID = UUID(), relationship: LogicalRelationship? = nil,
         sourceProfileID: UUID? = nil, reference: TableReference? = nil,
         profiles: @escaping @MainActor () -> [SavedConnection], mayStart: @escaping @MainActor () -> Bool,
         isCurrent: @escaping @MainActor () -> Bool, reader: @escaping Reader,
         cancel: @escaping @MainActor (LogicalRelationshipEndpoint, CatalogMetadataRequest) -> Void) {
        self.id = id; relationshipID = relationship?.id ?? UUID()
        name = relationship?.name ?? ""
        self.sourceProfileID = relationship?.source.profileID ?? sourceProfileID
        targetProfileID = relationship?.target.profileID ?? sourceProfileID
        sourceSchema = relationship?.source.schema ?? reference?.schema ?? ""
        sourceName = relationship?.source.name ?? reference?.name ?? ""
        sourceKind = relationship?.source.kind ?? reference?.kind ?? "table"
        targetSchema = relationship?.target.schema ?? reference?.schema ?? ""
        targetName = relationship?.target.name ?? ""
        targetKind = relationship?.target.kind ?? "table"
        columns = relationship?.columns ?? [.init(source: "", target: "")]
        origin = relationship?.origin ?? .manual
        self.profiles = profiles; self.reader = reader; self.isCurrent = isCurrent; self.mayStart = mayStart; self.cancel = cancel
    }
    var availableProfiles: [SavedConnection] { profiles().filter { [.postgresql, .mysql, .mariadb, .sqlite].contains($0.engine) } }
    var isBusy: Bool { isReading || isSaving }
    var endpoints: (LogicalRelationshipEndpoint, LogicalRelationshipEndpoint)? {
        guard let sourceProfile = profiles().first(where: { $0.id == sourceProfileID }),
              let targetProfile = profiles().first(where: { $0.id == targetProfileID }) else { return nil }
        let source = LogicalRelationshipEndpoint(profile: sourceProfile, reference: .init(schema: sourceSchema, name: sourceName, kind: sourceKind))
        let target = LogicalRelationshipEndpoint(profile: targetProfile, reference: .init(schema: targetSchema, name: targetName, kind: targetKind))
        guard source.isValid, target.isValid else { return nil }
        return (source, target)
    }
    var metadataMatches: Bool {
        guard let endpoints else { return false }
        return loadedSource == endpoints.0 && loadedTarget == endpoints.1
    }
    var canConfirm: Bool {
        guard !closed, !isBusy, isCurrent(), metadataMatches, let verified, let candidate = candidate() else { return false }
        return candidate == verified
    }
    var scopeDescription: String {
        "Local user-confirmed metadata only. This does not create a database constraint. Each target column uses its database equality, affinity and collation. Validation explicitly connects the selected profiles and reads column metadata. Cross-profile links navigate to independent tabs; they do not create cross-server JOIN SQL."
    }
    func addColumn() {
        guard !isBusy, columns.count < LogicalRelationshipLimits.columns else { return }
        columns.append(.init(source: "", target: "")); verified = nil
    }
    func removeColumn(at index: Int) {
        guard !isBusy, columns.indices.contains(index) else { return }
        columns.remove(at: index); verified = nil
    }
    func loadColumns() async { await read(validate: false) }
    func validate() async { await read(validate: true) }
    private func read(validate: Bool) async {
        guard !closed, !isBusy, draftWithinBudget, mayStart(), isCurrent(), let endpoints else {
            error = "Choose saved relational profiles and exact schema/object names, then read metadata explicitly."
            return
        }
        guard !validate || validPairs else { error = "Choose 1–32 unique ordered source and target columns."; return }
        operation &+= 1; let generation = operation
        let input = inputSignature
        isReading = true; error = nil; notice = nil; verified = nil; suggestions = []
        defer { if operation == generation { isReading = false; pending = nil } }
        func current() -> Bool {
            !closed && operation == generation && isCurrent() && self.endpoints?.0 == endpoints.0 && self.endpoints?.1 == endpoints.1 && inputSignature == input
        }
        do {
            let sourceRequest = CatalogMetadataRequest(); pending = (endpoints.0, sourceRequest)
            let source = try await reader(endpoints.0, sourceRequest)
            guard current(), !sourceRequest.cancelled else { throw CancellationError() }
            let targetRequest = CatalogMetadataRequest(); pending = (endpoints.1, targetRequest)
            let target = try await reader(endpoints.1, targetRequest)
            guard current(), !targetRequest.cancelled else { throw CancellationError() }
            guard Self.validMetadata(source), Self.validMetadata(target) else {
                throw LogicalRelationshipError.metadata("Column metadata is incomplete, duplicated or too large. No mapping was confirmed.")
            }
            sourceColumns = source; targetColumns = target
            loadedSource = endpoints.0; loadedTarget = endpoints.1
            if validate {
                columns = try columns.map { pair in
                    guard let sourceColumn = source.first(where: { Data($0.name.utf8) == Data(pair.source.utf8) }),
                          let targetColumn = target.first(where: { Data($0.name.utf8) == Data(pair.target.utf8) }) else {
                        throw LogicalRelationshipError.metadata("A mapped column is missing. Update the mapping and validate it again.")
                    }
                    return .init(source: sourceColumn.name, target: targetColumn.name, sourceType: sourceColumn.nativeType,
                                 targetType: targetColumn.nativeType, sqliteStorage: pair.sqliteStorage)
                }
                guard let candidate = candidate(), candidate.isValid else { throw LogicalRelationshipError.invalid }
                verified = candidate
                notice = "Mapping validated from the current column metadata. Review every pair, then explicitly Confirm and Save."
            } else { notice = "Column metadata loaded. Choose mappings, or inspect name/type suggestions. No relationship has been confirmed." }
        } catch {
            if !closed, operation == generation {
                if error is CancellationError || pending?.1.cancelled == true { notice = "Metadata read stopped. The local draft has been kept." }
                else { self.error = error.localizedDescription }
            }
        }
    }
    func inferSuggestions() {
        guard !closed, !isBusy, isCurrent(), metadataMatches, let endpoints else { return }
        suggestions = LogicalRelationshipInference.suggestions(source: endpoints.0, sourceColumns: sourceColumns,
            target: endpoints.1, targetColumns: targetColumns)
        notice = suggestions.isEmpty ? "No unambiguous name/type suggestion was found. You can choose columns manually." :
            "Suggestions are unconfirmed name/type matches. They are not server constraints and are not used for navigation, ER or JOIN completion."
    }
    func choose(_ suggestion: LogicalRelationshipSuggestion) {
        guard !isBusy, suggestions.contains(where: { $0.id == suggestion.id }), metadataMatches else { return }
        columns = suggestion.relationship.columns
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = suggestion.relationship.name }
        origin = .nameTypeSuggestion; verified = nil
        notice = "Suggestion copied to the draft. Validate and explicitly confirm it before use."
    }
    func confirm(in store: LogicalRelationshipStore) async {
        guard canConfirm, let candidate = candidate() else {
            error = "Validate the current mapping and review it before confirming. Changed profiles or columns require validation again."
            return
        }
        isSaving = true; error = nil
        defer { isSaving = false }
        do { try await store.saveConfirmed(candidate); saved = true; notice = "Local relationship saved. No database constraint was changed." }
        catch { self.error = error.localizedDescription }
    }
    func stop() {
        verified = nil
        if let (endpoint, request) = pending {
            request.cancelled = true
            if request.submitted { cancel(endpoint, request) }
            request.task?.cancel()
        }
    }
    func close() { closed = true; stop() }
    private var validPairs: Bool {
        (1...LogicalRelationshipLimits.columns).contains(columns.count) &&
            columns.allSatisfy { ERTableID.validName($0.source) && ERTableID.validName($0.target) } &&
            Set(columns.map { Data($0.source.utf8) }).count == columns.count && Set(columns.map { Data($0.target.utf8) }).count == columns.count
    }
    private var draftWithinBudget: Bool {
        name.utf8.count <= 1_024 && !name.contains("\0") && columns.count <= LogicalRelationshipLimits.columns &&
            columns.allSatisfy { $0.source.utf8.count <= 1_024 && $0.target.utf8.count <= 1_024 && !$0.source.contains("\0") && !$0.target.contains("\0") }
    }
    private var inputSignature: Data {
        var components = [name, sourceProfileID?.uuidString ?? "", targetProfileID?.uuidString ?? "", sourceSchema, sourceName,
                          sourceKind, targetSchema, targetName, targetKind, origin.rawValue]
        for pair in columns { components.append(pair.source); components.append(pair.target); components.append(pair.sqliteStorage) }
        return (try? JSONEncoder().encode(components)) ?? Data()
    }
    private func candidate() -> LogicalRelationship? {
        guard let endpoints, validPairs else { return nil }
        let candidate = LogicalRelationship(id: relationshipID, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            source: endpoints.0, target: endpoints.1, columns: columns, origin: origin)
        return candidate.isValid ? candidate : nil
    }
    private static func validMetadata(_ columns: [ERColumn]) -> Bool {
        !columns.isEmpty && columns.count <= 2_000 && Set(columns.map { Data($0.name.utf8) }).count == columns.count &&
            columns.allSatisfy { ERTableID.validName($0.name) && !$0.nativeType.isEmpty && $0.nativeType.utf8.count <= 16_384 && !$0.nativeType.contains("\0") } &&
            columns.reduce(0, { $0 + $1.name.utf8.count + $1.nativeType.utf8.count + 32 }) <= LogicalRelationshipLimits.metadataBytes
    }
}

enum LogicalRelationshipInference {
    static func suggestions(source: LogicalRelationshipEndpoint, sourceColumns: [ERColumn],
                            target: LogicalRelationshipEndpoint, targetColumns: [ERColumn]) -> [LogicalRelationshipSuggestion] {
        let primary = targetColumns.filter { $0.primaryKeyPosition != nil }.sorted { $0.primaryKeyPosition! < $1.primaryKeyPosition! }
        guard !primary.isEmpty, primary.count <= LogicalRelationshipLimits.columns,
              primary.map(\.primaryKeyPosition) == Array(1...primary.count).map(Optional.some) else { return [] }
        let table = target.name.hasSuffix("s") && target.name.count > 1 ? String(target.name.dropLast()) : target.name
        var pairs: [LogicalRelationshipColumn] = []
        for column in primary {
            let candidates = sourceColumns.filter { item in
                let expected = asciiFold(table + "_" + column.name)
                return asciiFold(item.name) == expected && family(item.nativeType) != nil && family(item.nativeType) == family(column.nativeType)
            }
            guard candidates.count == 1, let match = candidates.first else { return [] }
            pairs.append(.init(source: match.name, target: column.name, sourceType: match.nativeType, targetType: column.nativeType,
                sqliteStorage: source.engine != target.engine && (source.engine == .sqlite || target.engine == .sqlite) ? "text" : "preserve"))
        }
        let label = String((source.name + " → " + target.name).prefix(256))
        let relationship = LogicalRelationship(name: label, source: source, target: target, columns: pairs, origin: .nameTypeSuggestion)
        guard relationship.isValid else { return [] }
        return [.init(relationship: relationship, reason: "Column names resemble the target table and its complete primary key, with matching broad type families. This is a suggestion only.")]
    }
    private static func asciiFold(_ text: String) -> Data { Data(text.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }) }
    private static func family(_ text: String) -> String? {
        let head = text.lowercased().trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == "(" || $0 == " " }).first.map(String.init) ?? ""
        if ["smallint", "integer", "int", "int2", "int4", "int8", "bigint", "tinyint", "mediumint", "numeric", "decimal", "number"].contains(head) { return "number" }
        if ["text", "varchar", "character", "char", "nvarchar", "nchar"].contains(head) { return "text" }
        if ["uuid"].contains(head) { return "uuid" }
        if ["bytea", "blob", "binary", "varbinary"].contains(head) { return "binary" }
        return nil
    }
}
