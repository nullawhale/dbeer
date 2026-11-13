import AppKit
import SwiftUI

struct ERDiagramView: View {
    @ObservedObject var document: SQLDocument
    @ObservedObject var model: ERDiagramModel
    @ObservedObject var workspace: ApplicationWorkspace
    private var tablesPanel = SwiftUI.State(initialValue: true)
    private var inspectorPanel = SwiftUI.State(initialValue: true)
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
                if tablesPanel.wrappedValue {
                    ERDiagramAreaPanel(model: model, workspace: workspace, document: document, focus: focus)
                        .frame(minWidth: 210, idealWidth: 230, maxWidth: 290)
                }
                GeometryReader { proxy in
                    ERDiagramCanvas(model: model)
                        .onAppear { canvasSize = proxy.size }
                        .onChange(of: proxy.size) { _, size in canvasSize = size }
                        .overlay {
                            if model.stored.tables.isEmpty {
                                VStack(spacing: 12) {
                                    Image(systemName: "square.3.layers.3d").font(.system(size: 32, weight: .light))
                                        .foregroundStyle(AppPalette.secondaryText)
                                    Text("Choose tables for your diagram").font(.headline)
                                    Text("Add tables in the Tables panel, then Build to load their columns and relationships.")
                                        .font(.callout).appSecondaryText().multilineTextAlignment(.center).frame(maxWidth: 280)
                                    if !tablesPanel.wrappedValue {
                                        Button("Show Tables") { tablesPanel.wrappedValue = true }.controlHover()
                                    }
                                }.padding(24)
                            }
                        }
                }.frame(minWidth: 280)
                if inspectorPanel.wrappedValue {
                    ERDiagramInspector(model: model, workspace: workspace, document: document)
                        .frame(minWidth: 240, idealWidth: 270, maxWidth: 340)
                }
            }
            Divider()
            HStack(spacing: 12) {
                Text(model.displayNotice ?? "Metadata is not loaded.")
                    .lineLimit(2).textSelection(.enabled).help(model.displayNotice ?? "Metadata is not loaded.")
                Spacer(minLength: 8)
                Label("FK → key · dashed: local mapping", systemImage: "arrow.right").fixedSize()
            }.font(.caption).appSecondaryText().padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(AppPalette.panel).foregroundStyle(AppPalette.text).tint(AppPalette.accent)
        .accessibilityIdentifier("erDiagram")
    }
    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.ownerName(model.activeSourceID))
                    .font(.headline).lineLimit(1)
                Text("\(model.stored.tables.count) tables · \(model.relationships.count) relationships")
                    .font(.caption).appSecondaryText().lineLimit(1)
                    .help("Diagrams support up to 100 tables. Declared foreign keys and confirmed local mappings are shown separately.")
            }
            Divider().frame(height: 24)
            if model.activeSourceIsLoading {
                ProgressView().controlSize(.small)
                Text("\(model.progress)/\(model.stored.tables.filter { $0.profileID == model.activeSourceID }.count)").font(.caption).monospacedDigit()
                Button("Stop Source") { workspace.stopERDiagramSource(model, profileID: model.activeSourceID) }.controlHover()
            } else {
                Button {
                    Task { await workspace.buildERDiagram(document, connect: !connected) }
                } label: {
                    Label(connected ? (model.metadata.keys.contains(where: { $0.profileID == model.activeSourceID }) ? "Update Source" : "Build Source") : "Connect and Build", systemImage: "arrow.clockwise")
                }.controlHover()
                .disabled(!model.stored.tables.contains(where: { $0.profileID == model.activeSourceID }) || model.request?.finished == false || model.isSearching || model.source(model.activeSourceID) == nil)
                .accessibilityIdentifier("erBuild")
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                ControlIconButton(systemName: "minus.magnifyingglass") { zoom(1 / 1.2) }.help("Zoom out").accessibilityLabel("Zoom out")
                Button("\(Int(model.stored.viewport.zoom * 100))%") {
                    model.stored.viewport.scale(1 / model.stored.viewport.zoom, around: .init(x: canvasSize.width / 2, y: canvasSize.height / 2)); model.changed?()
                }.buttonStyle(.borderless).controlHover().font(.caption.monospacedDigit()).frame(minWidth: 40)
                    .help("Reset zoom to 100%").accessibilityLabel("Reset zoom to 100 percent")
                ControlIconButton(systemName: "plus.magnifyingglass") { zoom(1.2) }.help("Zoom in").accessibilityLabel("Zoom in")
                Button("Fit All", action: fit).buttonStyle(.borderless).controlHover().padding(.horizontal, 6)
            }
            Divider().frame(height: 22)
            ERDiagramExportControls(document: document, graph: model, workspace: workspace)
            Menu {
                Button("Auto Layout (Keep Manual Positions)") { model.autoLayout(); fit() }
                Button("Reset Layout") { model.autoLayout(reset: true); fit() }
            } label: { Image(systemName: "rectangle.3.group") }
                .menuStyle(.borderlessButton).fixedSize().controlHover().help("Arrange tables").accessibilityLabel("Diagram layout")
            ControlIconButton(systemName: "sidebar.left") { tablesPanel.wrappedValue.toggle() }
                .foregroundStyle(tablesPanel.wrappedValue ? AppPalette.accent : AppPalette.secondaryText)
                .help(tablesPanel.wrappedValue ? "Hide Tables panel" : "Show Tables panel").accessibilityLabel("Toggle Tables panel")
                .accessibilityValue(tablesPanel.wrappedValue ? "Shown" : "Hidden")
            ControlIconButton(systemName: "sidebar.right") { inspectorPanel.wrappedValue.toggle() }
                .foregroundStyle(inspectorPanel.wrappedValue ? AppPalette.accent : AppPalette.secondaryText)
                .help(inspectorPanel.wrappedValue ? "Hide Inspector" : "Show Inspector").accessibilityLabel("Toggle Inspector")
                .accessibilityValue(inspectorPanel.wrappedValue ? "Shown" : "Hidden")
        }.controlSize(.small).padding(.horizontal, 4).padding(.vertical, 2)
    }
    private func zoom(_ factor: Double) {
        model.stored.viewport.scale(factor, around: .init(x: canvasSize.width / 2, y: canvasSize.height / 2)); model.changed?()
    }
    private func fit() {
        model.stored.viewport = ERDiagramLayout.fit(model.stored.placements, metadata: model.metadata,
            collapsed: Set(model.stored.collapsed), size: canvasSize, routes: model.relationshipRoutes); model.changed?()
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
    override var wantsDefaultClipping: Bool { true }
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
        context.clip(to: bounds)
        context.translateBy(x: viewport.pan.x, y: viewport.pan.y); context.scaleBy(x: viewport.zoom, y: viewport.zoom)
        let a = viewport.world(.init(x: bounds.minX, y: bounds.minY)), b = viewport.world(.init(x: bounds.maxX, y: bounds.maxY))
        let visible = NSRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        drawGrid(in: visible, zoom: viewport.zoom)
        let positions = Dictionary(uniqueKeysWithValues: model.stored.placements.map { ($0.table, $0.point) })
        let edges = Dictionary(uniqueKeysWithValues: model.relationships.map { ($0.id, $0) })
        let routes = model.relationshipRoutes
        let selectedRelationship = model.selectedRelationship
        let cardRects = model.stored.tables.compactMap { table -> CGRect? in
            guard let point = positions[table] else { return nil }
            return CGRect(x: point.x, y: point.y, width: ERDiagramLayout.width,
                height: ERDiagramLayout.height(model.metadata[table], collapsed: model.stored.collapsed.contains(table)))
        }
        for route in routes {
            guard let edge = edges[route.relationshipID], route.points.count >= 2,
                  let geometry = route.roundedPath(zoom: viewport.zoom, obstacles: cardRects) else { continue }
            let path = NSBezierPath(); path.move(to: geometry.start)
            for segment in geometry.segments {
                switch segment {
                case .line(let point): path.line(to: point)
                case .curve(let point, let control1, let control2):
                    path.curve(to: point, controlPoint1: control1, controlPoint2: control2)
                }
            }
            guard path.bounds.insetBy(dx: -20, dy: -20).intersects(visible) else { continue }
            let style = connectionStyle(edge, selectedRelationshipID: selectedRelationship?.id, selectedTable: model.stored.selected)
            style.color.setStroke()
            path.lineWidth = style.width / viewport.zoom; path.lineJoinStyle = .round
            if edge.kind == .logical { path.setLineDash([6 / viewport.zoom, 4 / viewport.zoom], count: 2, phase: 0) }
            path.stroke()
            if edge.kind == .logical {
                if !model.stored.tables.contains(edge.source), let endpoint = route.points.first {
                    text((edge.sourceProfileName ?? edge.source.profileID.uuidString) + " · " + edge.source.label,
                         at: .init(x: endpoint.x - 20, y: endpoint.y - 22), width: 260, size: 11, color: style.color)
                }
                if !model.stored.tables.contains(edge.target), let endpoint = route.points.last {
                    text((edge.targetProfileName ?? edge.target.profileID.uuidString) + " · " + edge.target.label,
                         at: .init(x: endpoint.x - 80, y: endpoint.y + 8), width: 260, size: 11, color: style.color)
                }
            }
        }
        for table in model.stored.tables {
            guard let point = positions[table] else { continue }
            let facts = model.metadata[table], collapsed = model.stored.collapsed.contains(table)
            let rect = NSRect(x: point.x, y: point.y, width: ERDiagramLayout.width, height: ERDiagramLayout.height(facts, collapsed: collapsed))
            guard rect.intersects(visible) else { continue }
            drawCard(table, at: point, rect: rect, facts: facts, collapsed: collapsed, model: model, context: context, visible: visible, relationship: selectedRelationship)
        }
        // Heads are a foreground layer: card borders must not cover their tips.
        for route in routes {
            guard let edge = edges[route.relationshipID] else { continue }
            let style = connectionStyle(edge, selectedRelationshipID: selectedRelationship?.id, selectedTable: model.stored.selected)
            if let start = route.points.first {
                let radius = 2.5 / viewport.zoom
                let portRect = NSRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2)
                if portRect.insetBy(dx: -1 / viewport.zoom, dy: -1 / viewport.zoom).intersects(visible) {
                    let port = NSBezierPath(ovalIn: portRect)
                    AppPalette.panelNS.setFill(); port.fill()
                    style.color.setStroke(); port.lineWidth = 1.4 / viewport.zoom; port.stroke()
                }
            }
            let head = route.arrowhead(zoom: viewport.zoom, obstacles: cardRects)
            guard let tip = head.first else { continue }
            let arrow = NSBezierPath(); arrow.move(to: tip)
            for point in head.dropFirst() { arrow.line(to: point) }
            arrow.close()
            guard arrow.bounds.insetBy(dx: -2 / viewport.zoom, dy: -2 / viewport.zoom).intersects(visible) else { continue }
            AppPalette.backgroundNS.setStroke(); arrow.lineWidth = 2 / viewport.zoom; arrow.lineJoinStyle = .round; arrow.stroke()
            style.color.setFill(); arrow.fill()
        }
    }
    private func connectionStyle(_ edge: ERRelationship, selectedRelationshipID: String?, selectedTable: ERTableID?) -> (color: NSColor, width: Double) {
        if let selected = selectedRelationshipID {
            return selected == edge.id ? (AppPalette.accentNS, 2.5) : (AppPalette.secondaryTextNS.withAlphaComponent(0.3), 1.1)
        }
        let related = edge.source == selectedTable || edge.target == selectedTable
        return related ? (AppPalette.accentNS.withAlphaComponent(0.85), 1.8) : (AppPalette.secondaryTextNS.withAlphaComponent(0.65), 1.2)
    }
    private func drawGrid(in visible: CGRect, zoom: Double) {
        let step = 32 * pow(2, floor(log2(1 / zoom)))
        let diameter = 1.25 / zoom
        AppPalette.borderNS.withAlphaComponent(0.3).setFill()
        for x in stride(from: floor(visible.minX / step) * step, through: visible.maxX, by: step) {
            for y in stride(from: floor(visible.minY / step) * step, through: visible.maxY, by: step) {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: diameter, height: diameter)).fill()
            }
        }
    }
    private func drawCard(_ table: ERTableID, at point: ERPoint, rect: CGRect, facts: ERTableMetadata?, collapsed: Bool,
                          model: ERDiagramModel, context: CGContext, visible: CGRect, relationship: ERRelationship?) {
        let zoom = model.stored.viewport.zoom
        let selected = model.stored.selected == table
        let related = relationship.map { $0.source == table || $0.target == table } ?? false
        let card = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: NSColor.black.withAlphaComponent(0.12).cgColor)
        AppPalette.panelNS.setFill(); card.fill()
        context.restoreGState()
        context.saveGState(); card.addClip()
        AppPalette.controlNS.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: ERDiagramLayout.header - 4).fill()
        if selected || related {
            AppPalette.accentNS.withAlphaComponent(0.1).setFill()
            NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: ERDiagramLayout.header - 4).fill()
        }
        text(table.name, at: NSPoint(x: point.x + 14, y: point.y + 12), width: 312, size: 14, color: AppPalette.textNS, bold: true)
        text(model.ownerName(table.profileID) + " · " + table.schema, at: NSPoint(x: point.x + 14, y: point.y + 35), width: 312, size: 10.5, color: AppPalette.secondaryTextNS)
        AppPalette.borderNS.setFill()
        NSRect(x: rect.minX, y: point.y + ERDiagramLayout.header - 4, width: rect.width, height: 1 / zoom).fill()
        let columns = ERDiagramLayout.columns(facts, collapsed: collapsed)
        if columns.isEmpty {
            text(facts?.columnState.isAvailable == true ? "No columns reported" : "Columns not loaded", at: NSPoint(x: point.x + 14, y: point.y + ERDiagramLayout.header + 5),
                 width: 312, size: 11, color: AppPalette.secondaryTextNS)
        }
        for (index, column) in columns.enumerated() {
            let y = point.y + ERDiagramLayout.header + Double(index) * ERDiagramLayout.row
            guard y + ERDiagramLayout.row >= visible.minY, y <= visible.maxY else { continue }
            let rowRect = NSRect(x: point.x, y: y, width: rect.width, height: ERDiagramLayout.row)
            if index % 2 == 1 { AppPalette.controlNS.withAlphaComponent(0.35).setFill(); rowRect.fill() }
            let matching = relationship.map { edge in
                edge.key.columns.contains { (edge.source == table && Data($0.source.utf8) == Data(column.name.utf8)) || (edge.target == table && Data($0.target.utf8) == Data(column.name.utf8)) }
            } ?? false
            if matching { AppPalette.accentNS.withAlphaComponent(0.14).setFill(); rowRect.fill() }
            let pk = facts?.columnState.isAvailable == true ? column.primaryKeyPosition : nil
            let fk = facts?.relationshipState.isAvailable == true && facts?.foreignKeys.contains(where: { $0.columns.contains { Data($0.source.utf8) == Data(column.name.utf8) } }) == true
            if pk != nil || fk {
                let badge = pk.map { "PK\($0)" + (fk ? "/FK" : "") } ?? "FK"
                let badgeRect = NSRect(x: point.x + 10, y: y + 5, width: 40, height: 17)
                (pk != nil ? AppPalette.accentNS.withAlphaComponent(0.12) : AppPalette.secondaryTextNS.withAlphaComponent(0.1)).setFill()
                NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4).fill()
                text(badge, at: NSPoint(x: badgeRect.minX, y: y + 7), width: badgeRect.width, size: pk != nil && fk ? 8 : 9,
                     color: pk != nil ? AppPalette.accentNS : AppPalette.secondaryTextNS, bold: true, alignment: .center)
            }
            text(column.name, at: NSPoint(x: point.x + 58, y: y + 5), width: 116, size: 12, color: AppPalette.textNS, monospaced: true)
            text(column.nativeType, at: NSPoint(x: point.x + 180, y: y + 6), width: column.nullable ? 132 : 144, size: 10.5,
                 color: AppPalette.secondaryTextNS, monospaced: true, alignment: .right)
            if column.nullable { text("?", at: NSPoint(x: point.x + 322, y: y + 6), width: 8, size: 10.5, color: AppPalette.secondaryTextNS) }
        }
        AppPalette.borderNS.withAlphaComponent(0.65).setFill()
        NSRect(x: rect.minX, y: rect.maxY - ERDiagramLayout.footer, width: rect.width, height: 1 / zoom).fill()
        let count = facts?.columns.count ?? 0
        let countLabel: String
        if let facts, facts.columnState.isAvailable {
            countLabel = columns.count < count ? "\(columns.count) of \(count) columns" : "\(count) columns"
        } else {
            countLabel = columns.isEmpty ? "Columns not loaded" : "\(columns.count) columns shown"
        }
        text(countLabel, at: NSPoint(x: point.x + 14, y: rect.maxY - 22), width: 170, size: 10, color: AppPalette.secondaryTextNS)
        if let label = metadataLabel(facts) {
            text(label, at: NSPoint(x: point.x + 182, y: rect.maxY - 22), width: 144, size: 10,
                 color: AppPalette.accentNS, alignment: .right)
        }
        context.restoreGState()
        (selected || related ? AppPalette.accentNS : AppPalette.borderNS).setStroke()
        card.lineWidth = (selected ? 1.8 : related ? 1.3 : 1) / zoom; card.stroke()
    }
    private func metadataLabel(_ facts: ERTableMetadata?) -> String? {
        guard let facts else { return nil }
        let states = [facts.columnState, facts.relationshipState]
        if states.contains(where: { if case .stale = $0 { true } else { false } }) { return "Metadata stale" }
        if states.contains(where: { if case .unavailable = $0 { true } else { false } }) { return "Unavailable" }
        if states.contains(where: { if case .partial = $0 { true } else { false } }) { return "Partial metadata" }
        if states.contains(.notLoaded) { return "Not loaded" }
        return nil
    }
    private func text(_ string: String, at point: NSPoint, width: Double, size: Double, color: NSColor, bold: Bool = false,
                      monospaced: Bool = false, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail; paragraph.alignment = alignment
        let weight: NSFont.Weight = bold ? .semibold : .regular
        (string as NSString).draw(in: NSRect(x: point.x, y: point.y, width: width, height: size + 6), withAttributes: [
            .font: monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color, .paragraphStyle: paragraph])
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
