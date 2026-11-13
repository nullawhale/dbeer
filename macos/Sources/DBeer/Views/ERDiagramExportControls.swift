import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ERDiagramExportControls: View {
    @ObservedObject private var document: SQLDocument
    @ObservedObject private var graph: ERDiagramModel
    @ObservedObject private var workspace: ApplicationWorkspace
    @ObservedObject private var export: ERDiagramExportModel
    private var scope = SwiftUI.State<ERDiagramExportScope>(initialValue: .diagram)
    private var appearance = SwiftUI.State<ERDiagramExportAppearance>(initialValue: .light)
    private var scale = SwiftUI.State<Double>(initialValue: 1)
    private var showStatus = SwiftUI.State(initialValue: false)

    init(document: SQLDocument, graph: ERDiagramModel, workspace: ApplicationWorkspace) {
        self.document = document; self.graph = graph; self.workspace = workspace
        self.export = workspace.makeERDiagramExport(document) ?? ERDiagramExportModel(documentID: document.id,
            profileID: graph.stored.profileID, startAllowed: { false }, available: { false })
    }
    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Area", selection: scope.projectedValue) {
                    ForEach(ERDiagramExportScope.allCases) { value in
                        Text(value.label).tag(value).disabled(value == .selectedTable && graph.stored.selected == nil)
                    }
                }
                Picker("Appearance", selection: appearance.projectedValue) {
                    ForEach(ERDiagramExportAppearance.allCases) { Text($0.label).tag($0) }
                }
                Picker("PNG Scale", selection: scale.projectedValue) {
                    Text("1×").tag(1.0); Text("2×").tag(2.0); Text("3×").tag(3.0)
                }
                Divider()
                ForEach(ERDiagramExportFormat.allCases) { format in
                    Button("Export " + format.label + "…") { choose(format) }
                }
                Divider()
                Text("Uses the diagram captured when Export is chosen.")
                Text("Choose a new filename. Existing files are kept.")
            } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .menuStyle(.borderlessButton).fixedSize().controlHover()
                .disabled(!export.canStart || graph.stored.tables.isEmpty)
                .help("Export the selected diagram area as PNG, PDF or SVG")
                .accessibilityIdentifier("erExport")
            if export.isWorking {
                if export.phase == .saving { ProgressView(value: export.progress).frame(width: 64) }
                else { ProgressView().controlSize(.small) }
                Button("Stop Export") { Task { await export.stop() } }.controlHover().disabled(export.phase == .stopping)
            } else if let status = export.status {
                Button { showStatus.wrappedValue.toggle() } label: {
                    Image(systemName: export.phase == .completed ? "checkmark.circle" : export.phase == .failed ? "exclamationmark.triangle" : "stop.circle")
                }.buttonStyle(.borderless).controlHover().help(status).accessibilityLabel(status)
                    .foregroundStyle(export.phase == .failed ? Color.red : AppPalette.secondaryText)
            }
        }
        .popover(isPresented: showStatus.projectedValue) {
            VStack(alignment: .leading, spacing: 8) {
                Text(export.status ?? "Diagram export").font(.callout).textSelection(.enabled)
                if let saved = export.savedURL { Text(saved.lastPathComponent).font(.caption).appSecondaryText().textSelection(.enabled) }
                Button("Done") { showStatus.wrappedValue = false }
            }.padding(14).frame(maxWidth: 360)
        }
        .onChange(of: export.phase) { _, phase in if phase == .failed { showStatus.wrappedValue = true } }
    }
    private func choose(_ format: ERDiagramExportFormat) {
        let invocation: ERDiagramExportInvocation
        do { invocation = try workspace.prepareERDiagramExport(document, scope: scope.wrappedValue) }
        catch { export.report(error); return }
        let options = ERDiagramExportOptions(scope: scope.wrappedValue, appearance: appearance.wrappedValue, scale: scale.wrappedValue)
        let panel = NSSavePanel()
        panel.title = "Export ER Diagram"; panel.prompt = "Export"; panel.canCreateDirectories = true
        panel.nameFieldStringValue = "diagram." + format.rawValue
        panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .data]
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            Task { await workspace.exportERDiagram(document, invocation: invocation, format: format, options: options, to: destination) }
        }
    }
}
