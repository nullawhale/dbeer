import Combine
import Foundation

struct CatalogDiscoveryIssue: Identifiable, Sendable {
    let id = UUID()
    let object: String
    let message: String
}

enum CatalogDiscoveryLimits {
    static let schemas = 256
    static let tables = 10_000
    static let referencingTables = 1_000
    static let relationships = 1_000
    static let seconds: TimeInterval = 120
}

struct CatalogDiscoveryLimit: Error {
    let message: String
}

/// Metadata only. Every query remains bound to the original connected service.
@MainActor
final class CatalogDiscoveryReader {
    typealias Provider = @MainActor (CatalogRequest, CatalogMetadataRequest, CatalogMetadataPageHandler?) async throws -> BackendMessage
    private let provider: Provider
    private let isCurrent: @MainActor () -> Bool
    private let cancel: @MainActor (CatalogMetadataRequest) -> Void
    private var pending: CatalogMetadataRequest?
    private var stopped = false
    private var deadline = Date.distantPast
    private var deadlineTask: Task<Void, Never>?
    private var deadlineReached = false
    private let seconds: TimeInterval

    init(provider: @escaping Provider, isCurrent: @escaping @MainActor () -> Bool,
         cancel: @escaping @MainActor (CatalogMetadataRequest) -> Void, seconds: TimeInterval = CatalogDiscoveryLimits.seconds) {
        self.provider = provider
        self.isCurrent = isCurrent
        self.cancel = cancel
        self.seconds = seconds
    }

    func begin() throws {
        guard pending == nil, isCurrent() else { throw CancellationError() }
        stopped = false
        deadlineReached = false
        deadline = Date().addingTimeInterval(seconds)
        deadlineTask?.cancel()
        deadlineTask = Task { @MainActor [weak self, seconds] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self else { return }
            self.deadlineReached = true
            self.cancelPending()
        }
    }

    var contextIsCurrent: Bool { !stopped && isCurrent() }

    func requireCurrent() throws {
        try Task.checkCancellation()
        guard !stopped, isCurrent() else { throw CancellationError() }
        guard !deadlineReached, Date() < deadline else {
            throw CatalogDiscoveryLimit(message: "The metadata discovery deadline was reached. Narrow the scope and retry explicitly.")
        }
    }

    func read(_ selector: CatalogRequest, onPage: CatalogMetadataPageHandler? = nil) async throws -> BackendMessage {
        try requireCurrent()
        let request = CatalogMetadataRequest()
        pending = request
        defer { pending = nil }
        do {
            let guardedPage: CatalogMetadataPageHandler = { page in
                try self.requireCurrent()
                try onPage?(page)
                try self.requireCurrent()
            }
            let result = try await provider(selector, request, guardedPage)
            try requireCurrent()
            return result
        } catch {
            try requireCurrent()
            throw error
        }
    }

    func finish() { deadlineTask?.cancel(); deadlineTask = nil }

    func stop() {
        stopped = true
        finish()
        cancelPending()
    }

    private func cancelPending() {
        guard let pending, !pending.finished else { return }
        pending.cancelled = true
        pending.task?.cancel()
        cancel(pending)
    }
}

private func discoveryRecords(_ page: CatalogMetadataCollection) throws -> [[String: String]] {
    let names = page.columns.map(\.name)
    guard Set(names).count == names.count,
          Set(["name", "schema", "kind"]).isSubset(of: Set(names)),
          page.rows.allSatisfy({ $0.count == names.count }) else {
        throw ERDiagramFailure("The catalog table list is malformed or incomplete.")
    }
    return page.rows.map { row in
        var record: [String: String] = [:]
        for (index, name) in names.enumerated() { if let value = row[index] { record[name] = value } }
        return record
    }
}

private func discoveryTable(_ record: [String: String], profileID: UUID) throws -> ERTableID? {
    guard record["kind"] == "table" else { throw ERDiagramFailure("The catalog table list contains an unexpected object kind.") }
    guard let schema = record["schema"], let name = record["name"] else {
        throw ERDiagramFailure("A catalog table has no qualified identifier.")
    }
    let table = ERTableID(profileID: profileID, schema: schema, name: name)
    guard table.isValid else { throw ERDiagramFailure("A catalog table identifier is invalid.") }
    return table
}

@MainActor
final class VisibleTableDiscoveryModel: ObservableObject {
    let profileID: UUID
    let reader: CatalogDiscoveryReader
    @Published private(set) var tables: [ERTableID] = []
    @Published private(set) var issues: [CatalogDiscoveryIssue] = []
    @Published private(set) var schemasChecked = 0
    @Published private(set) var schemaCount = 0
    @Published private(set) var isBusy = false
    @Published private(set) var complete = false
    @Published private(set) var notice: String?
    private var tableIDs = Set<ERTableID>()

    init(profileID: UUID, reader: CatalogDiscoveryReader) {
        self.profileID = profileID
        self.reader = reader
    }

    func discover(schema: String? = nil) async {
        guard !isBusy else { return }
        isBusy = true
        complete = false
        notice = nil
        tables = []
        issues = []
        schemasChecked = 0
        schemaCount = 0
        tableIDs = []
        defer { isBusy = false; reader.finish() }
        do {
            try reader.begin()
            var schemas: [String] = []
            if let schema {
                guard ERTableID.validName(schema) else { throw ERDiagramFailure("Enter an exact schema or database name.") }
                schemas = [schema]
            } else {
                do {
                let response = try await reader.read(.init(kind: "schemas"), onPage: { page in
                    let names = page.columns.map(\.name)
                    guard let index = names.firstIndex(of: "name"), Set(names).count == names.count else {
                        throw ERDiagramFailure("The visible schema list is malformed.")
                    }
                    for row in page.rows {
                        guard row.indices.contains(index), let name = row[index], ERTableID.validName(name) else {
                            throw ERDiagramFailure("A visible schema identifier is invalid.")
                        }
                        if !schemas.contains(where: { Data($0.utf8) == Data(name.utf8) }) {
                            guard schemas.count < CatalogDiscoveryLimits.schemas else {
                                throw CatalogDiscoveryLimit(message: "More visible schemas are available. Discover one exact schema or database instead.")
                            }
                            schemas.append(name)
                        }
                    }
                })
                if response.truncated == true || response.displayNotice?.isEmpty == false {
                    issues.append(.init(object: "Visible schemas", message: response.displayNotice ?? "The visible schema list is incomplete."))
                }
                } catch let limit as CatalogDiscoveryLimit {
                    issues.append(.init(object: "Visible schemas", message: limit.message))
                }
            }
            schemaCount = schemas.count
            for schema in schemas {
                try reader.requireCurrent()
                do {
                    let response = try await reader.read(.init(kind: "objects", schema: schema, objectKind: "table"), onPage: { page in
                        for record in try discoveryRecords(page) {
                            guard let table = try discoveryTable(record, profileID: self.profileID), self.tableIDs.insert(table).inserted else { continue }
                            guard self.tables.count < CatalogDiscoveryLimits.tables else {
                                throw CatalogDiscoveryLimit(message: "The retained table limit was reached. Discover a narrower schema or database.")
                            }
                            self.tables.append(table)
                        }
                    })
                    if response.truncated == true || response.displayNotice?.isEmpty == false {
                        issues.append(.init(object: schema, message: response.displayNotice ?? "This schema's visible table list is incomplete."))
                    }
                } catch let limit as CatalogDiscoveryLimit { throw limit }
                catch is CancellationError { throw CancellationError() }
                catch {
                    issues.append(.init(object: schema, message: "Table metadata is unavailable. Check the schema and metadata permissions."))
                }
                schemasChecked += 1
                await Task.yield()
            }
            try reader.requireCurrent()
            complete = issues.isEmpty
            notice = complete ? "Visible tables in this connection were discovered. Add chosen tables, then Build explicitly. Server permissions define visibility."
                : "Discovery finished with unavailable or incomplete metadata. Review the scope report."
        } catch let limit as CatalogDiscoveryLimit {
            notice = limit.message
            issues.append(.init(object: "Discovery scope", message: limit.message))
        } catch is CancellationError { notice = "Discovery stopped or its connection context changed. Retained candidates are a partial observation." }
        catch { notice = "Visible-table discovery is unavailable. Check the connection and metadata permissions." }
    }

    func stop() {
        reader.stop()
        complete = false
        notice = "Cancellation requested. Waiting for the owned metadata request to finish."
    }
}

struct DiscoveredTableRelationship: Identifiable, Sendable {
    let source: ERTableID
    let key: TableForeignKey
    var target: ERTableID { .init(profileID: source.profileID, schema: key.target.schema, name: key.target.name) }
    var id: String { ERRelationship(source: source, key: key).id }
    var label: String { source.label + " · " + key.name }

    func inverseKey() -> TableForeignKey {
        .init(name: key.name, target: source.reference, columns: key.columns.map {
            .init(source: $0.target, target: $0.source, position: $0.position)
        })
    }
}

@MainActor
final class IncomingRelationshipDiscoveryModel: ObservableObject {
    let target: ERTableID
    let reader: CatalogDiscoveryReader
    @Published private(set) var relationships: [DiscoveredTableRelationship] = []
    @Published private(set) var resolvedTarget: ERTableID?
    @Published private(set) var issues: [CatalogDiscoveryIssue] = []
    @Published private(set) var sourceCount = 0
    @Published private(set) var sourcesChecked = 0
    @Published private(set) var isBusy = false
    @Published private(set) var complete = false
    @Published private(set) var notice: String?

    init(target: ERTableID, reader: CatalogDiscoveryReader) {
        self.target = target
        self.reader = reader
    }

    func discover(includeOutgoing: Bool = false) async {
        guard !isBusy else { return }
        isBusy = true
        complete = false
        relationships = []
        resolvedTarget = nil
        issues = []
        notice = nil
        sourcesChecked = 0
        sourceCount = 0
        defer { isBusy = false; reader.finish() }
        do {
            try reader.begin()
            var sources: [ERTableID] = []
            var seen = Set<ERTableID>()
            do {
                let response = try await reader.read(.init(kind: "referencingTables", schema: target.schema, object: target.name, objectKind: "table"), onPage: { page in
                    guard let canonical = page.target, canonical.valid else { throw ERDiagramFailure("The canonical target identity is unavailable.") }
                    let resolved = ERTableID(profileID: self.target.profileID, schema: canonical.schema, name: canonical.name)
                    guard self.resolvedTarget == nil || self.resolvedTarget == resolved else { throw ERDiagramFailure("The canonical target changed during discovery.") }
                    self.resolvedTarget = resolved
                    for record in try discoveryRecords(page) {
                        guard let table = try discoveryTable(record, profileID: self.target.profileID), seen.insert(table).inserted else { continue }
                        guard sources.count < CatalogDiscoveryLimits.referencingTables else {
                            throw CatalogDiscoveryLimit(message: "More referencing tables are available. Narrow the relationship scope before continuing.")
                        }
                        sources.append(table)
                    }
                })
                if response.truncated == true || response.displayNotice?.isEmpty == false {
                    issues.append(.init(object: target.label, message: response.displayNotice ?? "The referencing-table list is incomplete."))
                }
            } catch let limit as CatalogDiscoveryLimit {
                issues.append(.init(object: target.label, message: limit.message))
            }
            sourceCount = sources.count
            for source in sources {
                try reader.requireCurrent()
                do {
                    let response = try await reader.read(.init(kind: "foreignKeys", schema: source.schema, object: source.name, objectKind: "table"))
                    let keys = try TableForeignKey.parse(response)
                    let canonical = resolvedTarget ?? target
                    let matching = keys.filter { Data($0.target.schema.utf8) == Data(canonical.schema.utf8) && Data($0.target.name.utf8) == Data(canonical.name.utf8) }
                    if matching.isEmpty {
                        issues.append(.init(object: source.label, message: "A reported source no longer contains a complete mapping to the resolved target. The catalog may have changed. Refresh explicitly."))
                    }
                    for key in matching { try add(.init(source: source, key: key)) }
                    if response.displayNotice?.isEmpty == false {
                        issues.append(.init(object: source.label, message: response.displayNotice!))
                    }
                } catch let limit as CatalogDiscoveryLimit { throw limit }
                catch is CancellationError { throw CancellationError() }
                catch { issues.append(.init(object: source.label, message: "Foreign-key metadata is unavailable or incomplete. This source was not assumed to have no references.")) }
                sourcesChecked += 1
                await Task.yield()
            }
            if includeOutgoing {
                do {
                    let response = try await reader.read(.init(kind: "foreignKeys", schema: target.schema, object: target.name, objectKind: "table"))
                    for key in try TableForeignKey.parse(response) { try add(.init(source: resolvedTarget ?? target, key: key)) }
                    if response.displayNotice?.isEmpty == false { issues.append(.init(object: target.label, message: response.displayNotice!)) }
                } catch let limit as CatalogDiscoveryLimit { throw limit }
                catch is CancellationError { throw CancellationError() }
                catch { issues.append(.init(object: target.label, message: "Outgoing foreign-key metadata is unavailable or incomplete.")) }
            }
            try reader.requireCurrent()
            complete = issues.isEmpty
            notice = complete ? "Declared relationships visible through this connection were inspected. Metadata is a best-effort observation."
                : "Some relationships could not be inspected. Review the source report before drawing conclusions."
        } catch let limit as CatalogDiscoveryLimit {
            issues.append(.init(object: target.label, message: limit.message))
            notice = limit.message
        } catch is CancellationError { notice = "Relationship discovery stopped or its connection context changed. The retained list is partial." }
        catch { notice = "Incoming relationship discovery is unavailable. Check the target table and metadata permissions." }
    }

    private func add(_ relationship: DiscoveredTableRelationship) throws {
        guard !relationships.contains(where: { $0.id == relationship.id }) else { return }
        guard relationships.count < CatalogDiscoveryLimits.relationships else {
            throw CatalogDiscoveryLimit(message: "The relationship limit was reached. Retained relationships are partial.")
        }
        relationships.append(relationship)
    }

    func stop() {
        reader.stop()
        complete = false
        notice = "Cancellation requested. Waiting for the owned metadata request to finish."
    }
}
