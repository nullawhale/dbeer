import Combine
import Foundation

/// UTF-8 identities keep database names independent of Unicode normalization.
struct ERTableID: Codable, Hashable, Identifiable, Sendable {
    let profileID: UUID
    let schema: String
    let name: String
    var id: String { profileID.uuidString + ":" + Data(schema.utf8).base64EncodedString() + ":" + Data(name.utf8).base64EncodedString() }
    var label: String { schema + "." + name }
    var reference: TableReference { .init(schema: schema, name: name, kind: "table") }
    var isValid: Bool { Self.validName(schema) && Self.validName(name) }
    static func validName(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 1_024 && !value.contains("\0") }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum ERDiagramLimits {
    static let tables = 100
    static let columns = 10_000
    static let relationships = 1_000
    static let metadataBytes = 16 * 1_024 * 1_024
}
struct ERPoint: Codable, Equatable, Sendable {
    var x: Double = 0
    var y: Double = 0
    var isValid: Bool { x.isFinite && y.isFinite && abs(x) <= 1_000_000 && abs(y) <= 1_000_000 }
}
struct ERPlacement: Codable, Equatable, Sendable {
    var table: ERTableID
    var point: ERPoint
    var manual = false
}
struct ERViewport: Codable, Equatable, Sendable {
    static let zoomRange = 0.2...3.0
    var zoom: Double = 1
    var pan = ERPoint()
    var isValid: Bool { zoom.isFinite && Self.zoomRange.contains(zoom) && pan.isValid }
    func screen(_ p: ERPoint) -> ERPoint { .init(x: p.x * zoom + pan.x, y: p.y * zoom + pan.y) }
    func world(_ p: ERPoint) -> ERPoint { .init(x: (p.x - pan.x) / zoom, y: (p.y - pan.y) / zoom) }
    mutating func scale(_ factor: Double, around anchor: ERPoint) {
        guard factor.isFinite, factor > 0, anchor.isValid else { return }
        let before = world(anchor)
        zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom * factor))
        pan = .init(x: min(1_000_000, max(-1_000_000, anchor.x - before.x * zoom)),
                    y: min(1_000_000, max(-1_000_000, anchor.y - before.y * zoom)))
    }
}

/// Only presentation is persisted; live metadata and service identities are absent.
struct StoredERDiagram: Codable, Equatable, Sendable {
    var profileID: UUID
    var engine: DatabaseEngine
    var database: String
    var tables: [ERTableID] = []
    var placements: [ERPlacement] = []
    var collapsed: [ERTableID] = []
    var selected: ERTableID?
    var viewport = ERViewport()
    var isValid: Bool {
        let ids = Set(tables)
        return [.postgresql, .mysql, .sqlite].contains(engine) && database.utf8.count <= 1_024 && !database.contains("\0") &&
            tables.count <= ERDiagramLimits.tables && ids.count == tables.count &&
            tables.allSatisfy { $0.isValid && $0.profileID == profileID } &&
            placements.count <= tables.count && Set(placements.map(\.table)).count == placements.count &&
            placements.allSatisfy { ids.contains($0.table) && $0.point.isValid } &&
            collapsed.count <= tables.count && Set(collapsed).count == collapsed.count && collapsed.allSatisfy(ids.contains) &&
            (selected == nil || ids.contains(selected!)) && viewport.isValid
    }
}
struct ERColumn: Equatable, Sendable {
    let name: String
    let nativeType: String
    let nullable: Bool
    let primaryKeyPosition: Int?
}
enum ERMetadataState: Equatable, Sendable {
    case notLoaded, available, partial(String), unavailable(String), stale(String)
    var reason: String? {
        switch self {
        case .notLoaded: "Not loaded"
        case .available: nil
        case .partial(let s), .unavailable(let s), .stale(let s): s
        }
    }
    var isAvailable: Bool { self == .available }
}
struct ERTableMetadata: Equatable, Sendable {
    let table: ERTableID
    var columns: [ERColumn] = []
    var foreignKeys: [TableForeignKey] = []
    var columnState: ERMetadataState = .notLoaded
    var relationshipState: ERMetadataState = .notLoaded
    var retainedBytes: Int {
        columns.reduce(0) { $0 + $1.name.utf8.count + $1.nativeType.utf8.count + 32 } +
        foreignKeys.reduce(0) { $0 + $1.name.utf8.count + $1.target.schema.utf8.count + $1.target.name.utf8.count +
            $1.columns.reduce(0) { $0 + $1.source.utf8.count + $1.target.utf8.count + 16 } }
    }
}
enum ERRelationshipKind: String, Sendable { case declared, logical }

struct ERRelationship: Identifiable, Sendable {
    let source: ERTableID
    let key: TableForeignKey
    let logicalID: UUID?
    let targetProfileID: UUID?
    let targetProfileName: String?
    let sourceProfileName: String?
    let validationNotice: String?
    init(source: ERTableID, key: TableForeignKey, logicalID: UUID? = nil, targetProfileID: UUID? = nil, targetProfileName: String? = nil,
         sourceProfileName: String? = nil, validationNotice: String? = nil) {
        self.source = source; self.key = key; self.logicalID = logicalID
        self.targetProfileID = targetProfileID; self.targetProfileName = targetProfileName
        self.sourceProfileName = sourceProfileName; self.validationNotice = validationNotice
    }
    var kind: ERRelationshipKind { logicalID == nil ? .declared : .logical }
    var target: ERTableID { .init(profileID: targetProfileID ?? source.profileID, schema: key.target.schema, name: key.target.name) }
    var isValid: Bool {
        guard source.isValid, target.isValid else { return false }
        if kind == .declared { return key.isValid }
        guard ["table", "view"].contains(key.target.kind) else { return false }
        // The shared key representation checks ordered, unique identifier
        // pairs. A local mapping can reference a view without asserting that
        // the server allows a declared foreign key to that view.
        return TableForeignKey(name: key.name,
            target: .init(schema: key.target.schema, name: key.target.name, kind: "table"), columns: key.columns).isValid
    }
    var id: String {
        if let logicalID { return "logical:" + logicalID.uuidString }
        return source.id + ":" + Data(key.name.utf8).base64EncodedString() + ":" + target.id
    }
}
struct ERDiagramFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
enum ERDiagramMetadata {
    static func columns(_ result: BackendMessage) throws -> [ERColumn] {
        let names = (result.columns ?? []).map(\.name)
        let rows = result.rows ?? []
        guard Set(names).count == names.count,
              Set(["name", "nativeType", "nullable", "primaryKey"]).isSubset(of: Set(names)),
              result.truncated != true, (result.rowCount ?? Int64(rows.count)) == Int64(rows.count),
              rows.allSatisfy({ $0.count == names.count }), rows.count <= 1_000 else {
            throw ERDiagramFailure("Column metadata is incomplete or ambiguous. Narrow the area and retry.")
        }
        var seen = Set<Data>()
        let columns = try result.catalogRecords.map { record -> ERColumn in
            guard let name = record["name"], ERTableID.validName(name), seen.insert(Data(name.utf8)).inserted,
                  let type = record["nativeType"], !type.isEmpty, type.utf8.count <= 16_384, !type.contains("\0"),
                  let nullable = record["nullable"], ["true", "false"].contains(nullable),
                  let rawPK = record["primaryKey"], let pk = Int(rawPK), (0...1_000).contains(pk) else {
                throw ERDiagramFailure("Column metadata is malformed. No key membership was inferred.")
            }
            return ERColumn(name: name, nativeType: type, nullable: nullable == "true", primaryKeyPosition: pk == 0 ? nil : pk)
        }
        let ordinals = columns.compactMap(\.primaryKeyPosition).sorted()
        guard ordinals.isEmpty || ordinals == Array(1...ordinals.count) else {
            throw ERDiagramFailure("Primary-key positions are incomplete or duplicated.")
        }
        return columns
    }
    static func notice(_ result: BackendMessage) -> String? {
        guard let notice = result.displayNotice, !notice.isEmpty else { return nil }
        return "Metadata notice: " + notice
    }
}

struct ERDiagramLoadContext: Equatable, Sendable {
    let profileID: UUID
    let sessionID: String
    let serviceGeneration: UUID
    let settingsRevision: UUID
    let engine: DatabaseEngine
    let database: String
}

@MainActor
final class ERDiagramModel: ObservableObject {
    @Published var stored: StoredERDiagram
    @Published private(set) var metadata: [ERTableID: ERTableMetadata] = [:]
    @Published var notice: String? = "Not loaded. Build explicitly to read metadata. Incoming keys from unselected tables are outside this diagram's scope."
    @Published var visibleTableDiscovery: VisibleTableDiscoveryModel?
    @Published var neighbourDiscovery: IncomingRelationshipDiscoveryModel?
    @Published var isLoading = false
    @Published var progress = 0
    @Published var selectedRelationshipID: String?
    @Published var candidates: [ERTableID] = []
    @Published var candidateNotice: String?
    @Published var isSearching = false
    var initialSchema: String?
    var generation: UInt64 = 0
    var request: CatalogMetadataRequest?
    var searchContext: ERDiagramLoadContext?
    var searchRequest: CatalogMetadataRequest?
    var context: ERDiagramLoadContext?
    private(set) var logicalMetadataRevision: UInt64 = 0
    var localRelationships: (() -> [ERRelationship])?
    private var routedRelationshipSignature: [[Data]] = []
    var changed: (() -> Void)?
    private var routedGeometry: ERDiagramRouting.Geometry?
    private var cachedRoutes: [ERDiagramRoute] = []

    init(stored: StoredERDiagram) { self.stored = stored }
    var relationshipRoutes: [ERDiagramRoute] {
        let geometry = ERDiagramRouting.Geometry(tables: stored.tables, placements: stored.placements,
            metadata: metadata, collapsed: Set(stored.collapsed))
        let edges = relationships
        let signature = edges.map { edge in
            [edge.id, edge.source.id, edge.target.id] + edge.key.columns.flatMap { [$0.source, $0.target, String($0.position)] }
        }.map { $0.map { Data($0.utf8) } }
        if geometry != routedGeometry || signature != routedRelationshipSignature {
            cachedRoutes = ERDiagramRouting.routes(geometry, relationships: edges)
            routedRelationshipSignature = signature
            routedGeometry = geometry
        }
        return cachedRoutes
    }
    private var allRelationships: [ERRelationship] {
        let declared = stored.tables.flatMap { source in
            guard let facts = metadata[source], facts.relationshipState.isAvailable else { return [ERRelationship]() }
            return facts.foreignKeys.map { ERRelationship(source: source, key: $0) }
        }
        return declared + (localRelationships?() ?? [])
    }
    var relationships: [ERRelationship] { Array(allRelationships.prefix(ERDiagramLimits.relationships)) }
    var relationshipLimitNotice: String? {
        let omitted = allRelationships.count - ERDiagramLimits.relationships
        return omitted > 0 ? "\(omitted) additional declared or local relationships exceed the diagram limit. Narrow the selected area to include them." : nil
    }
    var displayNotice: String? { [notice, relationshipLimitNotice].compactMap { $0 }.joined(separator: " ") }
    var selectedRelationship: ERRelationship? { relationships.first { $0.id == selectedRelationshipID } }
    var draftDiffersFromGraph: Bool { Set(stored.tables) != Set(metadata.keys) }
    func add(_ table: ERTableID) {
        guard table.profileID == stored.profileID, table.isValid, !stored.tables.contains(table) else { return }
        guard stored.tables.count < ERDiagramLimits.tables else { notice = "Select at most 100 tables."; return }
        stored.tables.append(table); changed?()
    }
    func adoptCanonicalIdentity(_ original: ERTableID, resolved: ERTableID) {
        guard original != resolved, original.profileID == resolved.profileID, resolved.profileID == stored.profileID,
              resolved.isValid, stored.tables.contains(original) else { return }
        let alreadyPresent = stored.tables.contains(resolved)
        stored.tables = stored.tables.compactMap { $0 == original ? (alreadyPresent ? nil : resolved) : $0 }
        if alreadyPresent { stored.placements.removeAll { $0.table == original } }
        else { stored.placements = stored.placements.map { $0.table == original ? .init(table: resolved, point: $0.point, manual: $0.manual) : $0 } }
        let wasCollapsed = stored.collapsed.contains(original)
        stored.collapsed.removeAll { $0 == original }
        if wasCollapsed && !stored.collapsed.contains(resolved) { stored.collapsed.append(resolved) }
        if stored.selected == original { stored.selected = resolved }
        selectedRelationshipID = nil
        changed?()
    }

    func remove(_ table: ERTableID) {
        stored.tables.removeAll { $0 == table }; stored.placements.removeAll { $0.table == table }
        stored.collapsed.removeAll { $0 == table }
        if stored.selected == table { stored.selected = nil }
        selectedRelationshipID = nil
        changed?()
    }
    func setMetadata(_ facts: ERTableMetadata) {
        logicalMetadataRevision &+= 1
        metadata[facts.table] = facts
        // Identifier matching uses exact UTF-8, while synthesized metadata
        // equality treats canonically equivalent Swift strings as equal.
        routedGeometry = nil
    }
    func beginLoad(retryingFailures: Bool = false) {
        generation &+= 1; isLoading = true; progress = 0; selectedRelationshipID = nil
        metadata = metadata.filter { stored.tables.contains($0.key) }
        for table in stored.tables {
            if retryingFailures, let previous = metadata[table], previous.columnState.isAvailable, previous.relationshipState.isAvailable { continue }
            metadata[table] = .init(table: table)
        }
    }

    func invalidate(_ reason: String) {
        visibleTableDiscovery?.stop(); neighbourDiscovery?.stop()
        logicalMetadataRevision &+= 1
        generation &+= 1; isLoading = false; context = nil; notice = reason
        for table in metadata.keys {
            metadata[table]?.columnState = .stale(reason); metadata[table]?.relationshipState = .stale(reason)
        }
    }
    func move(_ table: ERTableID, to point: ERPoint, manual: Bool = true) {
        guard point.isValid, stored.tables.contains(table) else { return }
        stored.placements.removeAll { $0.table == table }; stored.placements.append(.init(table: table, point: point, manual: manual)); changed?()
    }
    func select(_ table: ERTableID?) { stored.selected = table; selectedRelationshipID = nil; changed?() }
    func autoLayout(reset: Bool = false) {
        stored.placements = ERDiagramLayout.positions(tables: stored.tables, relationships: relationships,
            metadata: metadata, preserving: reset ? [] : stored.placements.filter(\.manual), collapsed: Set(stored.collapsed))
        changed?()
    }
    func toggleCollapse(_ table: ERTableID) {
        if stored.collapsed.contains(table) { stored.collapsed.removeAll { $0 == table } }
        else { stored.collapsed.append(table) }
        changed?()
    }
}

private struct ERStoredKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func requireERKeys(_ decoder: Decoder, _ allowed: Set<String>) throws {
    let values = try decoder.container(keyedBy: ERStoredKey.self)
    guard Set(values.allKeys.map(\.stringValue)).isSubset(of: allowed) else { throw SQLDocumentStoreError.read }
}
extension ERTableID {
    private enum CodingKeys: String, CodingKey { case profileID, schema, name }
    init(from decoder: Decoder) throws {
        try requireERKeys(decoder, ["profileID", "schema", "name"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try values.decode(UUID.self, forKey: .profileID)
        schema = try values.decode(String.self, forKey: .schema)
        name = try values.decode(String.self, forKey: .name)
        guard isValid else { throw SQLDocumentStoreError.read }
    }
}
extension ERPoint {
    private enum CodingKeys: String, CodingKey { case x, y }
    init(from decoder: Decoder) throws {
        try requireERKeys(decoder, ["x", "y"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        x = try values.decode(Double.self, forKey: .x); y = try values.decode(Double.self, forKey: .y)
        guard isValid else { throw SQLDocumentStoreError.read }
    }
}
extension ERPlacement {
    private enum CodingKeys: String, CodingKey { case table, point, manual }
    init(from decoder: Decoder) throws {
        try requireERKeys(decoder, ["table", "point", "manual"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        table = try values.decode(ERTableID.self, forKey: .table)
        point = try values.decode(ERPoint.self, forKey: .point)
        manual = try values.decode(Bool.self, forKey: .manual)
    }
}
extension ERViewport {
    private enum CodingKeys: String, CodingKey { case zoom, pan }
    init(from decoder: Decoder) throws {
        try requireERKeys(decoder, ["zoom", "pan"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        zoom = try values.decode(Double.self, forKey: .zoom); pan = try values.decode(ERPoint.self, forKey: .pan)
        guard isValid else { throw SQLDocumentStoreError.read }
    }
}
extension StoredERDiagram {
    private enum CodingKeys: String, CodingKey { case profileID, engine, database, tables, placements, collapsed, selected, viewport }
    init(from decoder: Decoder) throws {
        try requireERKeys(decoder, ["profileID", "engine", "database", "tables", "placements", "collapsed", "selected", "viewport"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try values.decode(UUID.self, forKey: .profileID)
        engine = try values.decode(DatabaseEngine.self, forKey: .engine)
        database = try values.decode(String.self, forKey: .database)
        tables = try values.decode([ERTableID].self, forKey: .tables)
        placements = try values.decode([ERPlacement].self, forKey: .placements)
        collapsed = try values.decode([ERTableID].self, forKey: .collapsed)
        selected = try values.decodeIfPresent(ERTableID.self, forKey: .selected)
        viewport = try values.decode(ERViewport.self, forKey: .viewport)
        guard isValid else { throw SQLDocumentStoreError.read }
    }
}
