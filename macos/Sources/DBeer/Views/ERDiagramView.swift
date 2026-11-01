import AppKit
import SwiftUI

struct ERDiagramView: View {
    @ObservedObject var document: SQLDocument
    @ObservedObject var model: ERDiagramModel
    @ObservedObject var workspace: ApplicationWorkspace
    private var schemaState = SwiftUI.State<String>(initialValue: "")
    private var schema: String {
        get { schemaState.wrappedValue }
        nonmutating set { schemaState.wrappedValue = newValue }
    }
    private var searchState = SwiftUI.State<String>(initialValue: "")
    private var search: String {
        get { searchState.wrappedValue }
        nonmutating set { searchState.wrappedValue = newValue }
    }
    private var exactNameState = SwiftUI.State<String>(initialValue: "")
    private var exactName: String {
        get { exactNameState.wrappedValue }
        nonmutating set { exactNameState.wrappedValue = newValue }
    }
    private var listSearchState = SwiftUI.State<String>(initialValue: "")
    private var listSearch: String {
        get { listSearchState.wrappedValue }
        nonmutating set { listSearchState.wrappedValue = newValue }
    }
    private var canvasSizeState = SwiftUI.State<CGSize>(initialValue: CGSize(width: 800, height: 600))
    private var canvasSize: CGSize {
        get { canvasSizeState.wrappedValue }
        nonmutating set { canvasSizeState.wrappedValue = newValue }
    }

    private var connected: Bool { workspace.erDiagramContext(model) != nil }
    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(8)
            Divider()
            HSplitView {
                area.frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                GeometryReader { proxy in
                    ERDiagramCanvas(model: model)
                        .onAppear { canvasSize = proxy.size }
                        .onChange(of: proxy.size) { _, size in canvasSize = size }
                }.frame(minWidth: 240)
                details.frame(minWidth: 230, idealWidth: 260, maxWidth: 380)
            }
            Divider()
            Text(model.notice ?? "Metadata is not loaded.")
                .font(.caption).appSecondaryText().textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .background(AppPalette.panel).foregroundStyle(AppPalette.text).tint(AppPalette.accent)
        .accessibilityIdentifier("erDiagram")
        .onAppear {
            if schema.isEmpty { schema = model.initialSchema ?? model.stored.tables.first?.schema ?? (model.stored.engine == .mysql ? model.stored.database : "public") }
        }
    }
    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(workspace.library.savedConnections.first(where: { $0.id == model.stored.profileID })?.name ?? "Missing connection")
                .font(.headline).lineLimit(1)
            Text("\(model.stored.tables.count)/100 tables").font(.caption).appSecondaryText()
            if model.isLoading {
                ProgressView().controlSize(.small)
                Text("\(model.progress)/\(model.stored.tables.count)").font(.caption)
                Button("Stop") { workspace.stopERDiagram(model) }
            } else {
                Button(connected ? "Build / Update" : "Connect and Build") {
                    Task { await workspace.buildERDiagram(document, connect: !connected) }
                }.disabled(model.stored.tables.isEmpty || model.request?.finished == false || model.isSearching)
                    .accessibilityIdentifier("erBuild")
            }
            Spacer(minLength: 4)
            Button { zoom(1 / 1.2) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out")
            Text("\(Int(model.stored.viewport.zoom * 100))%").font(.caption).monospacedDigit()
            Button { zoom(1.2) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
            Button("Fit All") { fit() }
            Menu("Layout") {
                Button("Auto Layout (Keep Manual Positions)") { model.autoLayout(); fit() }
                Button("Reset Layout") { model.autoLayout(reset: true); fit() }
            }.fixedSize()
        }.buttonStyle(.borderless).controlHover()
    }
    private var area: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diagram Area").font(.headline)
            TextField("Schema / database (exact)", text: schemaState.projectedValue).accessibilityLabel("Schema or database")
            HStack {
                TextField("Table search", text: searchState.projectedValue)
                Button("Search") { Task { await workspace.searchERDiagram(document, schema: schema, search: search) } }
                    .disabled(!connected || model.isLoading || model.isSearching || !ERTableID.validName(schema))
            }
            if model.isSearching { ProgressView().controlSize(.small) }
            if let notice = model.candidateNotice { Text(notice).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if !model.candidates.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.candidates) { table in
                            HStack {
                                Text(table.label).font(.caption).lineLimit(1)
                                Spacer()
                                Button(model.stored.tables.contains(table) ? "Added" : "Add") { model.add(table) }
                                    .disabled(model.stored.tables.contains(table) || model.isLoading)
                            }
                        }
                    }
                }.frame(maxHeight: 150)
            }
            HStack {
                TextField("Exact table name", text: exactNameState.projectedValue)
                Button("Add") {
                    model.add(.init(profileID: model.stored.profileID, schema: schema, name: exactName))
                    exactName = ""
                }.disabled(model.isLoading || !ERTableID.validName(schema) || !ERTableID.validName(exactName))
            }
            Text("Schema and table names are separate exact identifiers. Build validates availability.")
                .font(.caption).appSecondaryText()
            Divider()
            TextField("Find selected table", text: listSearchState.projectedValue)
            List(selection: Binding(get: { model.stored.selected }, set: { model.select($0); focus() })) {
                ForEach(model.stored.tables.filter { listSearch.isEmpty || $0.label.localizedCaseInsensitiveContains(listSearch) }) { table in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(table.label).lineLimit(2)
                        if let state = model.metadata[table]?.columnState.reason { Text(state).font(.caption).appSecondaryText().lineLimit(2) }
                    }.tag(table)
                }
            }.listStyle(.plain)
            HStack {
                Button("Focus") { focus() }.disabled(model.stored.selected == nil)
                Button("Remove") { if let table = model.stored.selected { model.remove(table) } }
                    .disabled(model.stored.selected == nil || model.isLoading)
                Spacer()
            }
            if model.draftDiffersFromGraph { Text("Area changed. Build / Update to load this selection.").font(.caption).foregroundStyle(.orange) }
        }.padding(10)
    }
    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let table = model.stored.selected {
                    Text(table.label).font(.headline).textSelection(.enabled)
                    HStack {
                        Button("Open Data") { Task { await workspace.openERTable(document, table: table) } }
                        Menu("More") {
                            Button("Open Data in New Tab") { Task { await workspace.openERTable(document, table: table, newTab: true) } }
                            Button("Show Structure") { Task { await workspace.openERTable(document, table: table, structure: true) } }
                        }
                    }
                    Button(model.stored.collapsed.contains(table) ? "Show All Columns" : "Collapse Non-key Columns") { model.toggleCollapse(table) }
                    if let facts = model.metadata[table] {
                        if let reason = facts.columnState.reason { Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                        if let reason = facts.relationshipState.reason { Text("Relationships: " + reason).font(.caption).foregroundStyle(.orange) }
                        if !facts.columnState.isAvailable || !facts.relationshipState.isAvailable {
                            Button("Retry Metadata") { Task { await workspace.buildERDiagram(document, retryFailuresOnly: true) } }.disabled(model.isLoading || !connected)
                        }
                        ForEach(Array(facts.columns.enumerated()), id: \.offset) { _, column in
                            HStack(alignment: .firstTextBaseline) {
                                Text(column.name).font(.system(.caption, design: .monospaced))
                                Spacer()
                                Text(column.nativeType).font(.caption).appSecondaryText()
                                if facts.columnState.isAvailable, let position = column.primaryKeyPosition { Text("PK \(position)").font(.caption).accessibilityLabel("Primary key position \(position)") }
                            }.textSelection(.enabled)
                        }
                    }
                    Divider()
                }
                Text("Declared Relationships").font(.headline)
                Text("FK → referenced table. No cardinality is inferred.").font(.caption).appSecondaryText()
                let relationships = model.relationships.filter { edge in
                    model.stored.selected == nil || edge.source == model.stored.selected || edge.target == model.stored.selected
                }
                if relationships.isEmpty { Text("No loaded relationships in this selection. Unavailable metadata is not an empty FK set.").font(.caption).appSecondaryText() }
                ForEach(relationships) { edge in
                    VStack(alignment: .leading, spacing: 5) {
                        Button(edge.key.name) {
                            model.selectedRelationshipID = edge.id
                            if !model.stored.tables.contains(edge.target) { return }
                            model.stored.collapsed.removeAll { $0 == edge.source || $0 == edge.target }; model.changed?()
                        }.fontWeight(model.selectedRelationshipID == edge.id ? .bold : .regular)
                        Text(edge.source.label + " → " + edge.target.label).font(.caption).textSelection(.enabled)
                        ForEach(Array(edge.key.columns.enumerated()), id: \.offset) { _, pair in
                            Text("\(pair.position). \(pair.source) → \(pair.target)").font(.caption).textSelection(.enabled)
                        }
                        if !model.stored.tables.contains(edge.target) {
                            Text("Outside area / availability unknown").font(.caption).appSecondaryText()
                            Button("Add to Diagram") { model.add(edge.target) }.disabled(model.isLoading)
                        } else if model.metadata[edge.target]?.columnState.isAvailable != true {
                            Text("Target columns unavailable or not current. Table-level reference only.").font(.caption).foregroundStyle(.orange)
                        }
                        Divider()
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
    }
    private func zoom(_ factor: Double) {
        model.stored.viewport.scale(factor, around: .init(x: canvasSize.width / 2, y: canvasSize.height / 2)); model.changed?()
    }
    private func fit() {
        model.stored.viewport = ERDiagramLayout.fit(model.stored.placements, metadata: model.metadata,
            collapsed: Set(model.stored.collapsed), size: canvasSize); model.changed?()
    }
    private func focus() {
        guard let selected = model.stored.selected, let placement = model.stored.placements.first(where: { $0.table == selected }) else { return }
        model.stored.viewport = ERDiagramLayout.focus(placement.point, viewport: model.stored.viewport, size: canvasSize)
        model.changed?()
    }
}

private struct ERDiagramCanvas: NSViewRepresentable {
    @ObservedObject var model: ERDiagramModel
    func makeNSView(context: Context) -> ERCanvasView { ERCanvasView() }
    func updateNSView(_ view: ERCanvasView, context: Context) { view.model = model; view.needsDisplay = true }
}

private final class ERCanvasView: NSView {
    weak var model: ERDiagramModel?
    private var dragged: ERTableID?
    private var previous = NSPoint.zero
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityLabel() -> String? { "ER diagram canvas. Use the adjacent table list and relationship details for keyboard navigation." }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    private func world(_ event: NSEvent) -> ERPoint {
        let p = convert(event.locationInWindow, from: nil)
        return model?.stored.viewport.world(.init(x: p.x, y: p.y)) ?? ERPoint()
    }
    override func draw(_ dirtyRect: NSRect) {
        AppPalette.backgroundNS.setFill(); bounds.fill()
        guard let model, let context = NSGraphicsContext.current?.cgContext else { return }
        let viewport = model.stored.viewport
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: viewport.pan.x, y: viewport.pan.y); context.scaleBy(x: viewport.zoom, y: viewport.zoom)
        let a = viewport.world(.init(x: bounds.minX, y: bounds.minY)), b = viewport.world(.init(x: bounds.maxX, y: bounds.maxY))
        let visible = NSRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        let positions = Dictionary(uniqueKeysWithValues: model.stored.placements.map { ($0.table, $0.point) })
        for (i, edge) in model.relationships.sorted(by: { $0.id < $1.id }).enumerated() {
            guard let source = positions[edge.source], let target = positions[edge.target] else { continue }
            let sourceAnchor = anchor(edge.source, column: edge.key.columns.first?.source, point: source, right: true, model: model)
            let targetAnchor = anchor(edge.target, column: edge.key.columns.first?.target, point: target, right: false, model: model)
            let path = NSBezierPath(); path.move(to: sourceAnchor)
            let offset = Double(i % 9) * 8
            if edge.source == edge.target {
                path.curve(to: NSPoint(x: source.x + ERDiagramLayout.width, y: source.y + 20),
                    controlPoint1: NSPoint(x: sourceAnchor.x + 90 + offset, y: sourceAnchor.y + 60),
                    controlPoint2: NSPoint(x: sourceAnchor.x + 90 + offset, y: source.y - 50))
            } else {
                let distance = max(50, abs(targetAnchor.x - sourceAnchor.x) * 0.45) + offset
                path.curve(to: targetAnchor, controlPoint1: NSPoint(x: sourceAnchor.x + distance, y: sourceAnchor.y),
                           controlPoint2: NSPoint(x: targetAnchor.x - distance, y: targetAnchor.y))
            }
            guard path.bounds.insetBy(dx: -20, dy: -20).intersects(visible) else { continue }
            let highlighted = model.selectedRelationshipID == edge.id || edge.source == model.stored.selected || edge.target == model.stored.selected
            (highlighted ? AppPalette.accentNS : AppPalette.secondaryTextNS).setStroke()
            path.lineWidth = highlighted ? 2.5 : 1.3; path.stroke()
            let end = edge.source == edge.target ? NSPoint(x: source.x + ERDiagramLayout.width, y: source.y + 20) : targetAnchor
            let arrow = NSBezierPath(); arrow.move(to: NSPoint(x: end.x + (edge.source == edge.target ? 9 : -9), y: end.y - 5))
            arrow.line(to: end); arrow.line(to: NSPoint(x: end.x + (edge.source == edge.target ? 9 : -9), y: end.y + 5)); arrow.lineWidth = 1.5; arrow.stroke()
        }
        for table in model.stored.tables {
            guard let point = positions[table] else { continue }
            let facts = model.metadata[table], collapsed = model.stored.collapsed.contains(table)
            let rect = NSRect(x: point.x, y: point.y, width: ERDiagramLayout.width, height: ERDiagramLayout.height(facts, collapsed: collapsed))
            guard rect.intersects(visible) else { continue }
            AppPalette.panelNS.setFill(); let card = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8); card.fill()
            (model.stored.selected == table ? AppPalette.accentNS : AppPalette.borderNS).setStroke(); card.lineWidth = model.stored.selected == table ? 2 : 1; card.stroke()
            text(table.schema, at: NSPoint(x: point.x + 10, y: point.y + 7), width: 315, size: 10, color: AppPalette.secondaryTextNS)
            text(table.name, at: NSPoint(x: point.x + 10, y: point.y + 23), width: 315, size: 12, color: AppPalette.textNS, bold: true)
            let columns = ERDiagramLayout.columns(facts, collapsed: collapsed)
            for (index, column) in columns.enumerated() {
                let y = point.y + ERDiagramLayout.header + Double(index) * ERDiagramLayout.row
                guard y + ERDiagramLayout.row >= visible.minY, y <= visible.maxY else { continue }
                let matching = model.selectedRelationship.map { edge in
                    edge.key.columns.contains { (edge.source == table && Data($0.source.utf8) == Data(column.name.utf8)) || (edge.target == table && Data($0.target.utf8) == Data(column.name.utf8)) }
                } ?? false
                if matching { AppPalette.selectionNS.setFill(); NSRect(x: point.x + 2, y: y, width: ERDiagramLayout.width - 4, height: ERDiagramLayout.row).fill() }
                let pk = facts?.columnState.isAvailable == true ? column.primaryKeyPosition.map { "PK\($0) " } ?? "" : ""
                let fk = facts?.relationshipState.isAvailable == true && facts?.foreignKeys.contains(where: { $0.columns.contains { Data($0.source.utf8) == Data(column.name.utf8) } }) == true ? "FK " : ""
                text(pk + fk + column.name, at: NSPoint(x: point.x + 10, y: y + 3), width: 180, size: 11, color: AppPalette.textNS)
                text(column.nativeType + (column.nullable ? " ?" : ""), at: NSPoint(x: point.x + 195, y: y + 3), width: 135, size: 10, color: AppPalette.secondaryTextNS)
            }
            let hidden = max(0, (facts?.columns.count ?? 0) - columns.count)
            let status = facts?.columnState.reason ?? (hidden > 0 ? "\(hidden) columns collapsed" : "\(columns.count) columns")
            text(status, at: NSPoint(x: point.x + 10, y: rect.maxY - 29), width: 315, size: 10, color: AppPalette.secondaryTextNS)
            if let reason = facts?.relationshipState.reason { text("FK: " + reason, at: NSPoint(x: point.x + 10, y: rect.maxY - 15), width: 315, size: 9, color: AppPalette.secondaryTextNS) }
        }
    }
    private func anchor(_ table: ERTableID, column: String?, point: ERPoint, right: Bool, model: ERDiagramModel) -> NSPoint {
        let facts = model.metadata[table]
        let columns = ERDiagramLayout.columns(facts, collapsed: model.stored.collapsed.contains(table))
        let index = facts?.columnState.isAvailable == true ? columns.firstIndex(where: { Data($0.name.utf8) == Data((column ?? "").utf8) }) : nil
        return NSPoint(x: point.x + (right ? ERDiagramLayout.width : 0),
            y: point.y + (index.map { ERDiagramLayout.header + Double($0) * ERDiagramLayout.row + ERDiagramLayout.row / 2 } ?? 24))
    }
    private func text(_ string: String, at point: NSPoint, width: Double, size: Double, color: NSColor, bold: Bool = false) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (string as NSString).draw(in: NSRect(x: point.x, y: point.y, width: width, height: size + 6), withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: color, .paragraphStyle: paragraph])
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self); previous = convert(event.locationInWindow, from: nil)
        guard let model else { return }
        let p = world(event)
        dragged = model.stored.placements.reversed().first { item in
            NSRect(x: item.point.x, y: item.point.y, width: ERDiagramLayout.width,
                   height: ERDiagramLayout.height(model.metadata[item.table], collapsed: model.stored.collapsed.contains(item.table))).contains(NSPoint(x: p.x, y: p.y))
        }?.table
        model.select(dragged); needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let model else { return }
        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - previous.x, dy = current.y - previous.y; previous = current
        if let table = dragged, let position = model.stored.placements.first(where: { $0.table == table }) {
            model.move(table, to: .init(x: position.point.x + dx / model.stored.viewport.zoom, y: position.point.y + dy / model.stored.viewport.zoom))
        } else {
            let pan = ERPoint(x: model.stored.viewport.pan.x + dx, y: model.stored.viewport.pan.y + dy)
            if pan.isValid { model.stored.viewport.pan = pan; model.changed?() }
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { dragged = nil }
    override func scrollWheel(with event: NSEvent) {
        guard let model else { return }
        let p = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.option) { model.stored.viewport.scale(pow(1.01, event.scrollingDeltaY), around: .init(x: p.x, y: p.y)) }
        else {
            let pan = ERPoint(x: model.stored.viewport.pan.x + event.scrollingDeltaX, y: model.stored.viewport.pan.y + event.scrollingDeltaY)
            if pan.isValid { model.stored.viewport.pan = pan }
        }
        model.changed?(); needsDisplay = true
    }
    override func magnify(with event: NSEvent) {
        guard let model else { return }
        let p = convert(event.locationInWindow, from: nil)
        model.stored.viewport.scale(1 + event.magnification, around: .init(x: p.x, y: p.y)); model.changed?(); needsDisplay = true
    }
}
