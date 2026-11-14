import CoreGraphics
import CoreText
import Foundation

enum ERDiagramExportFormat: String, CaseIterable, Identifiable, Hashable, Sendable {
    case png, pdf, svg
    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

enum ERDiagramExportScope: String, CaseIterable, Identifiable, Hashable, Sendable {
    case diagram, selectedTable
    var id: String { rawValue }
    var label: String { self == .diagram ? "All Tables in Diagram" : "Selected Table" }
}

enum ERDiagramExportAppearance: String, CaseIterable, Identifiable, Hashable, Sendable {
    case light, dark
    var id: String { rawValue }
    var label: String { self == .light ? "Light" : "Dark" }
}

struct ERDiagramExportOptions: Sendable {
    var scope: ERDiagramExportScope = .diagram
    var appearance: ERDiagramExportAppearance = .light
    var scale: Double = 1
    var valid: Bool { [1.0, 2.0, 3.0].contains(scale) }
}

enum ERDiagramExportFailure: LocalizedError {
    case empty, invalid, tooLarge, render, exists, changed, write
    var errorDescription: String? {
        switch self {
        case .empty: "Choose at least one table to export."
        case .invalid: "The diagram contains invalid or incomplete geometry. Arrange the tables and retry."
        case .tooLarge: "This export exceeds the size limit. Select fewer tables, collapse cards, or reduce the PNG scale."
        case .render: "The diagram could not be rendered in the selected format."
        case .exists: "Choose a new filename. Existing files and folders are kept."
        case .changed: "The destination changed during export. External changes have been kept. Choose a new filename."
        case .write: "The diagram could not be saved. Choose a local writable folder and retry."
        }
    }
}

enum ERDiagramExportLimits {
    static let fileBytes = 64 * 1_024 * 1_024
    static let textBytes = ERDiagramLimits.metadataBytes
    static let vectorDimension = 1_000_000.0
    static let rasterDimension = 16_384
    static let rasterPixels = 32_000_000
    static let primitives = 50_000
}

/// The display mapping is reversible and common to every format. Original
/// strings are also included in versioned metadata, without normalization.
enum ERDiagramExportText {
    static func display(_ value: String) -> String {
        var output = ""
        for scalar in value.unicodeScalars {
            if scalar.value == 0x5c { output += "\\\\" }
            else if mustEscape(scalar) { output += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}" }
            else { output.unicodeScalars.append(scalar) }
        }
        return output
    }
    private static func mustEscape(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: return scalar.value == 0xfffe || scalar.value == 0xffff
        }
    }
    static func original(_ value: String) -> String? {
        var output = "", index = value.startIndex
        while index < value.endIndex {
            let next = value.index(after: index)
            guard value[index] == "\\" else { output.append(value[index]); index = next; continue }
            guard next < value.endIndex else { return nil }
            if value[next] == "\\" { output.append("\\"); index = value.index(after: next); continue }
            guard value[next] == "u", value.index(after: next) < value.endIndex,
                  value[value.index(after: next)] == "{" else { return nil }
            let digits = value.index(next, offsetBy: 2)
            guard let end = value[digits...].firstIndex(of: "}"), digits < end,
                  end.utf16Offset(in: value) - digits.utf16Offset(in: value) <= 6,
                  let number = UInt32(value[digits..<end], radix: 16), let scalar = Unicode.Scalar(number) else { return nil }
            output.unicodeScalars.append(scalar); index = value.index(after: end)
        }
        return output
    }
    static func xml(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

struct ERDiagramExportSnapshot: Sendable {
    enum RelationshipKind: String, Codable, Sendable { case declared, logical }
    struct RelationshipDescription: Sendable {
        let id: String
        let kind: RelationshipKind
        let targetProfileName: String?
        let sourceProfileName: String?
        let validationNotice: String?
        init(id: String, kind: RelationshipKind, targetProfileName: String?, sourceProfileName: String? = nil, validationNotice: String? = nil) {
            self.id = id; self.kind = kind; self.targetProfileName = targetProfileName
            self.sourceProfileName = sourceProfileName; self.validationNotice = validationNotice
        }
    }
    let title: String
    let profileName: String
    var profileNames: [UUID: String] = [:]
    let scope: ERDiagramExportScope
    let tables: [ERTableID]
    let metadata: [ERTableID: ERTableMetadata]
    let placements: [ERPlacement]
    let collapsed: Set<ERTableID>
    let relationships: [ERRelationship]
    let relationshipDescriptions: [RelationshipDescription]
    let notice: String?

    func validate() throws {
        guard !tables.isEmpty else { throw ERDiagramExportFailure.empty }
        let selected = Set(tables)
        guard tables.count <= ERDiagramLimits.tables, selected.count == tables.count,
              tables.allSatisfy(\.isValid), placements.count <= tables.count,
              Set(placements.map(\.table)).count == placements.count,
              placements.allSatisfy({ selected.contains($0.table) && $0.point.isValid }),
              collapsed.isSubset(of: selected), metadata.count <= tables.count, Set(metadata.keys).isSubset(of: selected), relationships.count <= ERDiagramLimits.relationships,
              relationships.allSatisfy(\.isValid),
              Set(relationships.map(\.id)).count == relationships.count,
              relationshipDescriptions.count == relationships.count,
              Set(relationshipDescriptions.map(\.id)) == Set(relationships.map(\.id)) else { throw ERDiagramExportFailure.invalid }
        let owners = Set(tables.map(\.profileID) + relationships.flatMap { [$0.source.profileID, $0.target.profileID] })
        guard Set(profileNames.keys).isSubset(of: owners), profileNames.count <= ERDiagramLimits.tables + 2 * ERDiagramLimits.relationships else { throw ERDiagramExportFailure.invalid }
        var bytes = title.utf8.count + profileName.utf8.count + (notice?.utf8.count ?? 0) + profileNames.values.reduce(0, { $0 + $1.utf8.count }), columns = 0
        for table in tables {
            try Task.checkCancellation()
            bytes += table.schema.utf8.count + table.name.utf8.count
            if let facts = metadata[table] {
                guard facts.table == table else { throw ERDiagramExportFailure.invalid }
                columns += facts.columns.count
                bytes += facts.columns.reduce(0) { $0 + $1.name.utf8.count + $1.nativeType.utf8.count }
                bytes += (facts.columnState.reason?.utf8.count ?? 0) + (facts.relationshipState.reason?.utf8.count ?? 0)
            }
            guard bytes <= ERDiagramExportLimits.textBytes, columns <= ERDiagramLimits.columns else { throw ERDiagramExportFailure.tooLarge }
        }
        for edge in relationships {
            bytes += edge.source.schema.utf8.count + edge.source.name.utf8.count + edge.target.schema.utf8.count + edge.target.name.utf8.count + edge.key.name.utf8.count
            bytes += edge.key.columns.reduce(0) { $0 + $1.source.utf8.count + $1.target.utf8.count }
            guard bytes <= ERDiagramExportLimits.textBytes else { throw ERDiagramExportFailure.tooLarge }
        }
        for description in relationshipDescriptions {
            bytes += (description.targetProfileName?.utf8.count ?? 0) + (description.sourceProfileName?.utf8.count ?? 0) + (description.validationNotice?.utf8.count ?? 0)
            guard bytes <= ERDiagramExportLimits.textBytes else { throw ERDiagramExportFailure.tooLarge }
        }
    }

    func originalMetadata(placements resolved: [ERPlacement]? = nil) throws -> Data {
        struct Column: Encodable { let name: String; let type: String; let nullable: Bool; let primaryKeyPosition: Int? }
        struct State: Encodable {
            let kind: String; let reason: String?
            init(_ state: ERMetadataState) {
                switch state {
                case .available: kind = "available"; reason = nil
                case .notLoaded: kind = "notLoaded"; reason = nil
                case .partial(let value): kind = "partial"; reason = value
                case .unavailable(let value): kind = "unavailable"; reason = value
                case .stale(let value): kind = "stale"; reason = value
                }
            }
        }
        struct Table: Encodable {
            let profileID: UUID; let profileName: String?; let schema: String; let name: String; let columns: [Column]
            let columnsState: State; let relationshipsState: State; let collapsed: Bool
        }
        struct Pair: Encodable { let source: String; let target: String }
        struct Edge: Encodable {
            let kind: RelationshipKind; let name: String; let sourceProfileID: UUID; let sourceProfileName: String?; let sourceSchema: String; let sourceName: String
            let targetProfileID: UUID; let targetProfileName: String?; let targetSchema: String; let targetName: String; let columns: [Pair]
            let validationNotice: String?
        }
        struct Document: Encodable {
            let version: Int; let title: String; let profileName: String; let scope: String
            let displayEscaping: String; let elision: String; let tables: [Table]; let placements: [ERPlacement]; let relationships: [Edge]
        }
        let kinds = Dictionary(uniqueKeysWithValues: relationshipDescriptions.map { ($0.id, $0) })
        let document = Document(version: 1, title: title, profileName: profileName, scope: scope.rawValue,
            displayEscaping: "unicode-scalars-v1", elision: "ellipsis", tables: tables.map { table in
            let facts = metadata[table]
            return Table(profileID: table.profileID, profileName: profileNames[table.profileID], schema: table.schema, name: table.name,
                         columns: (facts?.columns ?? []).map { Column(name: $0.name, type: $0.nativeType, nullable: $0.nullable, primaryKeyPosition: $0.primaryKeyPosition) },
                         columnsState: State(facts?.columnState ?? .notLoaded), relationshipsState: State(facts?.relationshipState ?? .notLoaded), collapsed: collapsed.contains(table))
        }, placements: resolved ?? placements, relationships: relationships.map { edge in
            Edge(kind: kinds[edge.id]?.kind ?? .declared, name: edge.key.name,
                 sourceProfileID: edge.source.profileID, sourceProfileName: kinds[edge.id]?.sourceProfileName, sourceSchema: edge.source.schema, sourceName: edge.source.name,
                 targetProfileID: edge.target.profileID, targetProfileName: kinds[edge.id]?.targetProfileName,
                 targetSchema: edge.target.schema, targetName: edge.target.name,
                 columns: edge.key.columns.map { Pair(source: $0.source, target: $0.target) }, validationNotice: kinds[edge.id]?.validationNotice)
        })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard data.count <= ERDiagramExportLimits.textBytes else { throw ERDiagramExportFailure.tooLarge }
        return data
    }
}

struct ERDiagramExportColor: Sendable {
    let red: Double; let green: Double; let blue: Double
    var cgColor: CGColor { CGColor(red: red, green: green, blue: blue, alpha: 1) }
    var hex: String { String(format: "#%02x%02x%02x", Int(red * 255), Int(green * 255), Int(blue * 255)) }
}

struct ERDiagramExportPalette: Sendable {
    let background: ERDiagramExportColor, card: ERDiagramExportColor, header: ERDiagramExportColor
    let border: ERDiagramExportColor, text: ERDiagramExportColor, secondary: ERDiagramExportColor, accent: ERDiagramExportColor
    init(_ appearance: ERDiagramExportAppearance) {
        if appearance == .light {
            background = .init(red: 1, green: 1, blue: 1); card = .init(red: 0.98, green: 0.985, blue: 0.99)
            header = .init(red: 0.94, green: 0.95, blue: 0.965); border = .init(red: 0.67, green: 0.7, blue: 0.75)
            text = .init(red: 0.1, green: 0.13, blue: 0.18); secondary = .init(red: 0.34, green: 0.39, blue: 0.46)
            accent = .init(red: 0.14, green: 0.36, blue: 0.73)
        } else {
            background = .init(red: 0.08, green: 0.095, blue: 0.12); card = .init(red: 0.13, green: 0.15, blue: 0.19)
            header = .init(red: 0.18, green: 0.2, blue: 0.25); border = .init(red: 0.39, green: 0.43, blue: 0.5)
            text = .init(red: 0.94, green: 0.95, blue: 0.97); secondary = .init(red: 0.7, green: 0.74, blue: 0.8)
            accent = .init(red: 0.48, green: 0.69, blue: 1)
        }
    }
}

struct ERDiagramExportScene: Sendable {
    enum Primitive: Sendable {
        case rectangle(CGRect, Double, ERDiagramExportColor, ERDiagramExportColor?)
        case line([ERPoint], ERDiagramExportColor, Bool)
        case polygon([ERPoint], ERDiagramExportColor)
        case text(String, CGRect, Double, Bool, Bool, ERDiagramExportColor)
    }
    let size: CGSize
    let palette: ERDiagramExportPalette
    let primitives: [Primitive]
    let originalMetadata: Data
    let graphBounds: CGRect
    let exportedTables: [ERTableID]

    static func make(_ snapshot: ERDiagramExportSnapshot, options: ERDiagramExportOptions) throws -> Self {
        try snapshot.validate()
        guard options.valid else { throw ERDiagramExportFailure.invalid }
        try Task.checkCancellation()
        let palette = ERDiagramExportPalette(options.appearance)
        let metadata = snapshot.metadata.filter { snapshot.tables.contains($0.key) }
        let placements = ERDiagramLayout.positions(tables: snapshot.tables, relationships: snapshot.relationships,
            metadata: metadata, preserving: snapshot.placements, collapsed: snapshot.collapsed)
        try Task.checkCancellation()
        guard placements.count == snapshot.tables.count else { throw ERDiagramExportFailure.invalid }
        let positions = Dictionary(uniqueKeysWithValues: placements.map { ($0.table, $0.point) })
        let cards = Dictionary(uniqueKeysWithValues: snapshot.tables.map { table in
            (table, CGRect(x: positions[table]!.x, y: positions[table]!.y, width: ERDiagramLayout.width,
                           height: ERDiagramLayout.height(metadata[table], collapsed: snapshot.collapsed.contains(table))))
        })
        let geometry = ERDiagramRouting.Geometry(tables: snapshot.tables, placements: placements, metadata: metadata, collapsed: snapshot.collapsed)
        let routes = ERDiagramRouting.routes(geometry, relationships: snapshot.relationships)
        try Task.checkCancellation()
        let edges = Dictionary(uniqueKeysWithValues: snapshot.relationships.map { ($0.id, $0) })
        let descriptions = Dictionary(uniqueKeysWithValues: snapshot.relationshipDescriptions.map { ($0.id, $0) })
        let selected = Set(snapshot.tables)
        struct ExternalLabel { let rect: CGRect; let table: ERTableID; let profile: String? }
        var externalLabels: [String: ExternalLabel] = [:]
        for route in routes {
            guard let edge = edges[route.relationshipID] else { continue }
            if !selected.contains(edge.target), let tail = route.points.last {
                externalLabels[edge.id] = ExternalLabel(rect: CGRect(x: tail.x + 12, y: tail.y - 24, width: 340, height: 45), table: edge.target, profile: descriptions[edge.id]?.targetProfileName)
            } else if !selected.contains(edge.source), let start = route.points.first {
                externalLabels[edge.id] = ExternalLabel(rect: CGRect(x: start.x - 352, y: start.y - 24, width: 340, height: 45), table: edge.source, profile: descriptions[edge.id]?.sourceProfileName)
            }
        }
        var bounds = cards.values.reduce(CGRect.null) { $0.union($1) }
        for route in routes { for point in route.points { bounds = bounds.union(CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24)) } }
        for label in externalLabels.values { bounds = bounds.union(label.rect) }
        guard !bounds.isNull, bounds.minX.isFinite, bounds.minY.isFinite, bounds.width.isFinite, bounds.height.isFinite,
              bounds.width <= ERDiagramExportLimits.vectorDimension, bounds.height <= ERDiagramExportLimits.vectorDimension else { throw ERDiagramExportFailure.tooLarge }
        let margin = 32.0, titleHeight = 64.0
        let offset = CGPoint(x: margin - bounds.minX, y: margin + titleHeight - bounds.minY)
        let width = max(640, bounds.width + margin * 2)
        var primitives: [Primitive] = []
        final class TextPresentation { var elidedLabels = 0 }
        let presentation = TextPresentation()
        func append(_ primitive: Primitive) throws {
            guard primitives.count < ERDiagramExportLimits.primitives else { throw ERDiagramExportFailure.tooLarge }
            primitives.append(primitive)
        }
        func translated(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: offset.x, dy: offset.y) }
        func text(_ raw: String, _ rect: CGRect, size: Double = 11, bold: Bool = false, mono: Bool = false, secondary: Bool = false) throws {
            let displayed = ERDiagramExportText.display(raw)
            let fitted = fit(displayed, width: rect.width, size: size, bold: bold, mono: mono)
            if Data(fitted.utf8) != Data(displayed.utf8) { presentation.elidedLabels += 1 }
            try append(.text(fitted, rect, size, bold, mono, secondary ? palette.secondary : palette.text))
        }
        try text(snapshot.title, CGRect(x: margin, y: margin, width: width - margin * 2, height: 26), size: 19, bold: true)
        try text(snapshot.profileName + " · " + snapshot.scope.label + " · " + String(snapshot.tables.count) + " tables", CGRect(x: margin, y: margin + 30, width: width - margin * 2, height: 22), secondary: true)
        for route in routes {
            try Task.checkCancellation()
            guard let edge = edges[route.relationshipID] else { continue }
            let logical = descriptions[edge.id]?.kind == .logical
            try append(.line(route.points.map { .init(x: $0.x + offset.x, y: $0.y + offset.y) }, logical ? palette.accent : palette.secondary, logical))
        }
        for table in snapshot.tables {
            try Task.checkCancellation()
            guard let rawRect = cards[table] else { throw ERDiagramExportFailure.invalid }
            let rect = translated(rawRect), facts = metadata[table]
            try append(.rectangle(rect, 9, palette.card, palette.border))
            try append(.rectangle(CGRect(x: rect.minX + 1, y: rect.minY + 1, width: rect.width - 2, height: ERDiagramLayout.header - 5), 7, palette.header, nil))
            try text(table.name, CGRect(x: rect.minX + 14, y: rect.minY + 10, width: 312, height: 22), size: 14, bold: true)
            try text(snapshot.profileNames[table.profileID].map { $0 + " · " + table.schema } ?? table.schema, CGRect(x: rect.minX + 14, y: rect.minY + 35, width: 312, height: 18), size: 10, secondary: true)
            let columns = ERDiagramLayout.columns(facts, collapsed: snapshot.collapsed.contains(table))
            if columns.isEmpty {
                try text(facts?.columnState.isAvailable == true ? "No columns reported" : "Columns not loaded", CGRect(x: rect.minX + 14, y: rect.minY + ERDiagramLayout.header + 5, width: 312, height: 20), secondary: true)
            }
            for (index, column) in columns.enumerated() {
                try Task.checkCancellation()
                let y = rect.minY + ERDiagramLayout.header + Double(index) * ERDiagramLayout.row
                let fk = facts?.relationshipState.isAvailable == true && facts?.foreignKeys.contains { key in key.columns.contains { Data($0.source.utf8) == Data(column.name.utf8) } } == true
                let pk = facts?.columnState.isAvailable == true ? column.primaryKeyPosition : nil
                let badge = pk.map { "PK" + String($0) + (fk ? "/FK" : "") } ?? (fk ? "FK" : "")
                try text(badge, CGRect(x: rect.minX + 10, y: y + 7, width: 44, height: 17), size: 8, bold: true, secondary: true)
                try text(column.name, CGRect(x: rect.minX + 58, y: y + 5, width: 116, height: 21), size: 12, mono: true)
                try text(column.nativeType + (column.nullable ? " ?" : ""), CGRect(x: rect.minX + 180, y: y + 6, width: 146, height: 20), size: 10, mono: true, secondary: true)
            }
            let total = facts?.columns.count ?? 0
            let count = columns.count < total ? String(columns.count) + " of " + String(total) + " columns" : String(total) + " columns"
            try text(count, CGRect(x: rect.minX + 14, y: rect.maxY - 23, width: 150, height: 17), size: 10, secondary: true)
            let state = stateLabel(facts)
            if !state.isEmpty { try text(state, CGRect(x: rect.minX + 172, y: rect.maxY - 23, width: 154, height: 17), size: 10, secondary: true) }
        }
        for route in routes {
            try Task.checkCancellation()
            guard let edge = edges[route.relationshipID] else { continue }
            let color = descriptions[edge.id]?.kind == .logical ? palette.accent : palette.secondary
            let head = route.arrowhead(zoom: 1, obstacles: Array(cards.values))
            if head.count == 3 { try append(.polygon(head.map { .init(x: $0.x + offset.x, y: $0.y + offset.y) }, color)) }
            if let rawLabel = externalLabels[edge.id] {
                let label = translated(rawLabel.rect)
                try text(rawLabel.table.label, CGRect(x: label.minX, y: label.minY, width: label.width, height: 21), size: 11, bold: true, secondary: true)
                let profile = rawLabel.profile ?? "Outside diagram area"
                try text(profile, CGRect(x: label.minX, y: label.minY + 23, width: label.width, height: 18), size: 10, secondary: true)
            }
        }
        var legend = ["Declared foreign key → referenced key", "Dashed line: confirmed local relationship", "Outside-area references are listed below; they do not imply loaded metadata."]
        if presentation.elidedLabels > 0 { legend.append(String(presentation.elidedLabels) + " labels are shortened with … to fit their cards. Original names are included in file metadata.") }
        var allRaw = [snapshot.title, snapshot.profileName] + Array(snapshot.profileNames.values)
        for table in snapshot.tables {
            allRaw += [table.schema, table.name]
            for column in metadata[table]?.columns ?? [] { allRaw += [column.name, column.nativeType] }
        }
        for edge in snapshot.relationships {
            allRaw += [edge.key.name, edge.source.schema, edge.source.name, edge.target.schema, edge.target.name]
            for pair in edge.key.columns { allRaw += [pair.source, pair.target] }
        }
        for description in snapshot.relationshipDescriptions { allRaw += [description.targetProfileName, description.sourceProfileName].compactMap { $0 } }
        if allRaw.contains(where: { Data(ERDiagramExportText.display($0).utf8) != Data($0.utf8) }) {
            legend.append("Control characters and backslashes are escaped in labels. Original names are included in file metadata.")
        }
        if snapshot.collapsed.count > 0 { legend.append("Collapsed cards show the same subset of columns as the diagram. Original column names are included in file metadata.") }
        if snapshot.placements.count != snapshot.tables.count { legend.append("Tables without a saved position were arranged locally for this export.") }
        if let notice = snapshot.notice, !notice.isEmpty { legend.append(notice) }
        for table in snapshot.tables {
            guard let facts = metadata[table] else { legend.append(table.label + ": metadata not loaded."); continue }
            if let reason = facts.columnState.reason { legend.append(table.label + ": columns — " + coverageLabel(facts.columnState) + reason) }
            if let reason = facts.relationshipState.reason { legend.append(table.label + ": relationships — " + coverageLabel(facts.relationshipState) + reason) }
        }
        for edge in snapshot.relationships {
            if let reason = descriptions[edge.id]?.validationNotice { legend.append("Local relationship " + edge.key.name + ": " + reason) }
        }
        let routed = Set(routes.map(\.relationshipID))
        for edge in snapshot.relationships where !routed.contains(edge.id) {
            let description = descriptions[edge.id]
            let kind = description?.kind == .logical ? "Local relationship" : "Declared foreign key"
            let profile = description?.targetProfileName.map { " [" + $0 + "]" } ?? ""
            let reason = !selected.contains(edge.source) || !selected.contains(edge.target) ? "outside this area" : "route unavailable for overlapping cards"
            legend.append(kind + " " + edge.key.name + ": " + edge.source.label + " → " + edge.target.label + profile + " (" + reason + ").")
        }
        var y = titleHeight + bounds.height + margin * 2 + 12
        try text("Legend and coverage", CGRect(x: margin, y: y, width: width - margin * 2, height: 24), size: 13, bold: true)
        y += 30
        for raw in legend {
            try Task.checkCancellation()
            let lines = wrap(ERDiagramExportText.display(raw), width: width - margin * 2, size: 11)
            for line in lines {
                try append(.text(line, CGRect(x: margin, y: y, width: width - margin * 2, height: 18), 11, false, false, palette.secondary)); y += 18
            }
            y += 5
            guard y <= ERDiagramExportLimits.vectorDimension else { throw ERDiagramExportFailure.tooLarge }
        }
        let original = try snapshot.originalMetadata(placements: placements)
        return .init(size: CGSize(width: ceil(width), height: ceil(y + margin)), palette: palette, primitives: primitives,
                     originalMetadata: original, graphBounds: translated(bounds), exportedTables: snapshot.tables)
    }

    private static func stateLabel(_ facts: ERTableMetadata?) -> String {
        guard let facts else { return "Not loaded" }
        let states = [facts.columnState, facts.relationshipState]
        if states.contains(where: { if case .stale = $0 { true } else { false } }) { return "Metadata stale" }
        if states.contains(where: { if case .unavailable = $0 { true } else { false } }) { return "Unavailable" }
        if states.contains(where: { if case .partial = $0 { true } else { false } }) { return "Partial metadata" }
        return states.contains(.notLoaded) ? "Not loaded" : ""
    }
    private static func coverageLabel(_ state: ERMetadataState) -> String {
        switch state {
        case .partial: "partial: "
        case .unavailable: "unavailable: "
        case .stale: "stale: "
        case .available, .notLoaded: ""
        }
    }

    static func font(size: Double, bold: Bool, mono: Bool) -> CTFont {
        CTFontCreateWithName((mono ? (bold ? "Menlo-Bold" : "Menlo-Regular") : (bold ? "Helvetica-Bold" : "Helvetica")) as CFString, size, nil)
    }
    private static func fit(_ value: String, width: Double, size: Double, bold: Bool, mono: Bool) -> String {
        let font = font(size: size, bold: bold, mono: mono)
        func measured(_ text: String) -> Double {
            let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil)
        }
        guard measured(value) > width else { return value }
        let characters = Array(value)
        var low = 0, high = characters.count
        while low < high {
            if Task.isCancelled { return "…" }
            let middle = (low + high + 1) / 2
            if measured(String(characters.prefix(middle)) + "…") <= width { low = middle }
            else { high = middle - 1 }
        }
        return String(characters.prefix(low)) + "…"
    }
    private static func wrap(_ value: String, width: Double, size: Double) -> [String] {
        let attributed = NSAttributedString(string: value, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font(size: size, bold: false, mono: false)])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let text = value as NSString
        var offset = 0, lines: [String] = []
        while offset < text.length {
            if Task.isCancelled { return [] }
            let count = CTTypesetterSuggestLineBreak(typesetter, offset, width)
            guard count > 0 else { return [value] }
            lines.append(text.substring(with: NSRange(location: offset, length: count))); offset += count
            if lines.count >= ERDiagramExportLimits.primitives { return [value] }
        }
        return lines
    }
}
