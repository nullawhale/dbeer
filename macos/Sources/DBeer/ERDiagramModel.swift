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
    static let sources = 16
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
    var sources: [ERDiagramSource] = []
    var tables: [ERTableID] = []
    var placements: [ERPlacement] = []
    var collapsed: [ERTableID] = []
    var selected: ERTableID?
    var viewport = ERViewport()
    var sourceProfileIDs: Set<UUID> { Set(sources.map(\.profileID) + tables.map(\.profileID)) }
    var isValid: Bool {
        let ids = Set(tables)
        let profiles = Set(sources.map(\.profileID)).union([profileID])
        let validSources = sources.isEmpty || (sources.count <= ERDiagramLimits.sources && Set(sources.map(\.profileID)).count == sources.count &&
            sources.allSatisfy(\.isValid) && sources.filter { $0.profileID == profileID }.allSatisfy { $0.engine == engine && Data($0.database.utf8) == Data(database.utf8) })
        return validSources && sourceProfileIDs.count <= ERDiagramLimits.sources && [.postgresql, .mysql, .sqlite].contains(engine) && database.utf8.count <= 1_024 && !database.contains("\0") &&
            tables.count <= ERDiagramLimits.tables && ids.count == tables.count &&
            tables.allSatisfy { $0.isValid && profiles.contains($0.profileID) } &&
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
    @Published var activeSourceID: UUID
    @Published var sourceStates: [UUID: ERDiagramSourceState] = [:]
    var isLoading: Bool { sourceStates.values.contains { $0.loading } }
    var activeSourceIsLoading: Bool { sourceState(activeSourceID).loading }
    @Published var visibleTableDiscovery: VisibleTableDiscoveryModel?
    @Published var neighbourDiscovery: IncomingRelationshipDiscoveryModel?
    var progress: Int {
        get { sourceState(activeSourceID).progress }
        set { sourceStates[activeSourceID, default: .init()].progress = newValue }
    }
    @Published var selectedRelationshipID: String?
    @Published var candidates: [ERTableID] = []
    @Published var candidateNotice: String?
    @Published var isSearching = false
    var initialSchema: String?
    var ownerRevisions: [UUID: UInt64] = [:]
    var generation: UInt64 = 0
    private(set) var logicalMetadataRevision: UInt64 = 0
    var request: CatalogMetadataRequest? {
        get { sourceState(activeSourceID).request }
        set { sourceStates[activeSourceID, default: .init()].request = newValue }
    }
    var searchGeneration: UInt64 = 0
    var searchContext: ERDiagramLoadContext?
    var searchRequest: CatalogMetadataRequest?
    var context: ERDiagramLoadContext? {
        get { sourceState(activeSourceID).context }
        set { sourceStates[activeSourceID, default: .init()].context = newValue }
    }
    var changed: (() -> Void)?
    var localRelationships: (() -> [ERRelationship])?
    private var routedRelationshipSignature: [[Data]] = []
    private var routedGeometry: ERDiagramRouting.Geometry?
    private var cachedRoutes: [ERDiagramRoute] = []

    init(stored: StoredERDiagram) {
        self.stored = stored
        let ids = Set(stored.sources.map(\.profileID) + stored.tables.map(\.profileID))
        activeSourceID = ids.contains(stored.profileID) || ids.isEmpty ? stored.profileID : (stored.sources.first?.profileID ?? stored.tables.first!.profileID)
    }
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
    var displayNotice: String? {
        let sourceNotices = stored.sources.compactMap { source -> String? in
            sourceState(source.profileID).notice.map { source.name + ": " + $0 }
        }
        let messages = ([notice, relationshipLimitNotice].compactMap { $0 }) + sourceNotices
        return messages.isEmpty ? nil : messages.joined(separator: " ")
    }
    var selectedRelationship: ERRelationship? { relationships.first { $0.id == selectedRelationshipID } }
    var draftDiffersFromGraph: Bool { Set(stored.tables) != Set(metadata.keys) }
    func add(_ table: ERTableID) {
        guard ownsSource(table.profileID), table.isValid, !stored.tables.contains(table) else { return }
        guard stored.tables.count < ERDiagramLimits.tables else { notice = "Select at most 100 tables."; return }
        stored.tables.append(table); changed?()
    }
    /// Explicit discovery may resolve an alias using the connected server's
    /// own identifier rules. Only draft identity/presentation changes here.
    func adoptCanonicalIdentity(_ original: ERTableID, resolved: ERTableID) {
        guard original != resolved, original.profileID == resolved.profileID, ownsSource(resolved.profileID),
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
        if stored.selected == table { neighbourDiscovery?.stop(); neighbourDiscovery = nil; stored.selected = nil }
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
    func sourceState(_ profileID: UUID) -> ERDiagramSourceState { sourceStates[profileID] ?? .init() }
    var sourceProfileIDs: Set<UUID> {
        let ids = stored.sourceProfileIDs
        return ids.isEmpty ? [stored.profileID] : ids
    }
    func ownsSource(_ profileID: UUID) -> Bool { sourceProfileIDs.contains(profileID) }
    func source(_ profileID: UUID) -> ERDiagramSource? { stored.sources.first { $0.profileID == profileID } }
    func ownerName(_ profileID: UUID) -> String { source(profileID)?.name ?? "Unconfirmed profile " + profileID.uuidString }
    var activeEngine: DatabaseEngine { source(activeSourceID)?.engine ?? stored.engine }
    func selectSource(_ profileID: UUID) {
        guard ownsSource(profileID), activeSourceID != profileID else { return }
        visibleTableDiscovery?.stop(); neighbourDiscovery?.stop()
        visibleTableDiscovery = nil; neighbourDiscovery = nil
        searchRequest?.cancelled = true; searchRequest?.task?.cancel()
        searchGeneration &+= 1; isSearching = false
        candidates = []; candidateNotice = nil; activeSourceID = profileID
    }
    @discardableResult
    func bindSource(_ profile: SavedConnection) -> Bool {
        let binding = ERDiagramSource(profile)
        guard binding.isValid else { return false }
        if let previous = source(profile.id) {
            guard previous.fingerprint == binding.fingerprint else {
                notice = "This source changed. Rebind its objects explicitly before loading."; return false
            }
            if let index = stored.sources.firstIndex(where: { $0.profileID == profile.id }) { stored.sources[index].name = profile.name }
            return true
        }
        guard stored.sourceProfileIDs.union([profile.id]).count <= ERDiagramLimits.sources else {
            notice = "Select at most 16 source profiles."; return false
        }
        if profile.id == stored.profileID {
            if stored.tables.contains(where: { $0.profileID == profile.id }) {
                guard profile.engine == stored.engine && Data(profile.database.utf8) == Data(stored.database.utf8) else { return false }
            } else { stored.engine = profile.engine; stored.database = profile.database }
        }
        stored.sources.append(binding); changed?(); return true
    }
    func removeSource(_ profileID: UUID) {
        guard ownsSource(profileID) else { return }
        let removed = Set(stored.tables.filter { $0.profileID == profileID })
        stored.tables.removeAll { removed.contains($0) }; stored.placements.removeAll { removed.contains($0.table) }
        stored.collapsed.removeAll { removed.contains($0) }
        if let selected = stored.selected, removed.contains(selected) { stored.selected = nil }
        stored.sources.removeAll { $0.profileID == profileID }
        metadata = metadata.filter { !removed.contains($0.key) }
        sourceStates[profileID, default: .init()].generation &+= 1
        sourceStates[profileID, default: .init()].context = nil
        sourceStates[profileID, default: .init()].loading = false
        sourceStates[profileID, default: .init()].progress = 0
        sourceStates[profileID, default: .init()].notice = "Removed from this diagram."
        selectedRelationshipID = nil; logicalMetadataRevision &+= 1
        if activeSourceID == profileID { activeSourceID = stored.sources.first?.profileID ?? stored.tables.first?.profileID ?? stored.profileID }
        changed?()
    }
    func rebind(_ original: ERTableID, to replacement: ERTableID, profile: SavedConnection) throws {
        guard stored.tables.contains(original), replacement.isValid, replacement.profileID == profile.id,
              !stored.tables.contains(replacement) || original == replacement, ERDiagramSource(profile).isValid else {
            throw ERDiagramFailure("Select one existing object and a distinct exact destination. Existing destinations are not merged.")
        }
        if stored.tables.contains(where: { $0.profileID == profile.id && $0 != original }), source(profile.id)?.matches(profile) != true {
            throw ERDiagramFailure("Other objects still have this profile's original or unconfirmed binding. Review the whole source, or rebind to a different saved profile.")
        }
        let reboundTables = stored.tables.map { $0 == original ? replacement : $0 }
        let reboundProfiles = Set(stored.sources.map(\.profileID) + [profile.id] + reboundTables.map(\.profileID))
        guard reboundProfiles.count <= ERDiagramLimits.sources else { throw ERDiagramFailure("Select at most 16 source profiles.") }
        invalidateSource(original.profileID, reason: "An object was rebound. Build this source explicitly.")
        if profile.id != original.profileID { invalidateSource(profile.id, reason: "An object was rebound. Build this source explicitly.") }
        stored.sources.removeAll { $0.profileID == profile.id }; stored.sources.append(.init(profile))
        if profile.id == stored.profileID { stored.engine = profile.engine; stored.database = profile.database }
        stored.tables = reboundTables
        stored.placements = stored.placements.map { $0.table == original ? .init(table: replacement, point: $0.point, manual: $0.manual) : $0 }
        stored.collapsed = stored.collapsed.map { $0 == original ? replacement : $0 }
        if stored.selected == original { stored.selected = replacement }
        metadata[original] = nil; metadata[replacement] = nil
        selectedRelationshipID = nil; activeSourceID = profile.id; changed?()
    }
    func beginLoad(profileID: UUID? = nil, retryingFailures: Bool = false) {
        let id = profileID ?? activeSourceID
        logicalMetadataRevision &+= 1
        notice = nil
        sourceStates[id, default: .init()].generation &+= 1
        sourceStates[id, default: .init()].loading = true
        sourceStates[id, default: .init()].progress = 0
        sourceStates[id, default: .init()].notice = "Loading metadata."
        selectedRelationshipID = nil
        metadata = metadata.filter { stored.tables.contains($0.key) }
        for table in stored.tables where table.profileID == id {
            if retryingFailures, let previous = metadata[table], previous.columnState.isAvailable, previous.relationshipState.isAvailable { continue }
            metadata[table] = .init(table: table)
        }
    }
    func finishLoad(_ profileID: UUID, generation expected: UInt64) {
        guard sourceState(profileID).generation == expected else { return }
        sourceStates[profileID, default: .init()].loading = false
    }
    func invalidateSource(_ profileID: UUID, reason: String) {
        logicalMetadataRevision &+= 1
        sourceStates[profileID, default: .init()].generation &+= 1
        sourceStates[profileID, default: .init()].loading = false
        sourceStates[profileID, default: .init()].context = nil
        sourceStates[profileID, default: .init()].notice = reason
        for table in metadata.keys where table.profileID == profileID {
            metadata[table]?.columnState = .stale(reason); metadata[table]?.relationshipState = .stale(reason)
        }
    }
    func invalidate(_ reason: String) {
        visibleTableDiscovery?.stop(); neighbourDiscovery?.stop(); generation &+= 1; notice = reason
        for id in Set(sourceStates.keys).union(stored.tables.map(\.profileID)).union([stored.profileID]) { invalidateSource(id, reason: reason) }
    }
    func move(_ table: ERTableID, to point: ERPoint, manual: Bool = true) {
        guard point.isValid, stored.tables.contains(table) else { return }
        stored.placements.removeAll { $0.table == table }; stored.placements.append(.init(table: table, point: point, manual: manual)); changed?()
    }
    func select(_ table: ERTableID?) { if let table { selectSource(table.profileID) }; if stored.selected != table { neighbourDiscovery?.stop(); neighbourDiscovery = nil }; stored.selected = table; selectedRelationshipID = nil; changed?() }
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
    private enum CodingKeys: String, CodingKey { case profileID, engine, database, sources, tables, placements, collapsed, selected, viewport }
    init(from decoder: Decoder) throws {
        try requireERKeys(decoder, ["profileID", "engine", "database", "sources", "tables", "placements", "collapsed", "selected", "viewport"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try values.decode(UUID.self, forKey: .profileID)
        engine = try values.decode(DatabaseEngine.self, forKey: .engine)
        database = try values.decode(String.self, forKey: .database)
        sources = values.contains(.sources) ? try values.decode([ERDiagramSource].self, forKey: .sources) : []
        tables = try values.decode([ERTableID].self, forKey: .tables)
        placements = try values.decode([ERPlacement].self, forKey: .placements)
        collapsed = try values.decode([ERTableID].self, forKey: .collapsed)
        selected = try values.decodeIfPresent(ERTableID.self, forKey: .selected)
        viewport = try values.decode(ERViewport.self, forKey: .viewport)
        guard isValid else { throw SQLDocumentStoreError.read }
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profileID, forKey: .profileID); try c.encode(engine, forKey: .engine); try c.encode(database, forKey: .database)
        if !sources.isEmpty { try c.encode(sources, forKey: .sources) }
        try c.encode(tables, forKey: .tables); try c.encode(placements, forKey: .placements)
        try c.encode(collapsed, forKey: .collapsed); try c.encodeIfPresent(selected, forKey: .selected); try c.encode(viewport, forKey: .viewport)
    }

}
