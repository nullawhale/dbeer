import SwiftUI

struct IncomingRelationsSheet: View {
    @ObservedObject var document: SQLDocument
    @ObservedObject var workspace: ApplicationWorkspace
    @ObservedObject var grid: GridDraft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Incoming Relations").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Declared foreign keys from visible tables. Select one stored parent row to open matching child rows.")
                .font(.caption).appSecondaryText()
            if let model = document.incomingRelationships {
                IncomingRelationsContent(model: model, document: document, workspace: workspace, grid: grid)
            } else { Text("Choose Find Incoming Relations explicitly to inspect metadata.").appSecondaryText() }
            Spacer(minLength: 0)
        }.padding(18).frame(minWidth: 540, idealWidth: 640, minHeight: 380, idealHeight: 500)
    }
}

private struct IncomingRelationsContent: View {
    @ObservedObject var model: IncomingRelationshipDiscoveryModel
    @ObservedObject var document: SQLDocument
    @ObservedObject var workspace: ApplicationWorkspace
    @ObservedObject var grid: GridDraft
    private var rowID: UUID? {
        guard grid.selectedRows.count == 1, let index = grid.selectedRows.first, grid.rows.indices.contains(index) else { return nil }
        return grid.rows[index].id
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if model.isBusy { ProgressView().controlSize(.small) }
                Text("\(model.sourcesChecked) / \(model.sourceCount) source tables inspected · \(model.relationships.count) relations")
                    .font(.caption).monospacedDigit()
                Spacer()
                if model.isBusy { Button("Stop") { model.stop() }.controlHover() }
                else { Button("Refresh") { Task { await workspace.discoverIncomingRows(document) } }.controlHover() }
            }
            if let notice = model.notice { Text(notice).font(.caption).textSelection(.enabled).foregroundStyle(model.complete ? Color.secondary : Color.orange) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.relationships) { relationship in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(relationship.label).font(.callout).textSelection(.enabled)
                            Text(relationship.key.columns.map { $0.source + " → " + $0.target }.joined(separator: ", "))
                                .font(.caption).appSecondaryText().textSelection(.enabled)
                            HStack {
                                Button("Open Child Rows in New Tab") {
                                    guard let rowID else { return }
                                    Task { await workspace.followIncomingRelationship(relationship, rowID: rowID, in: document) }
                                }.controlHover()
                                Button("Open in This Tab") {
                                    guard let rowID else { return }
                                    Task { await workspace.followIncomingRelationship(relationship, rowID: rowID, in: document, inNewTab: false) }
                                }.controlHover()
                            }.controlSize(.small)
                                .disabled(model.isBusy || rowID == nil || !document.canNavigateTable || !model.reader.contextIsCurrent)
                        }
                    }
                    CatalogDiscoveryIssueList(issues: model.issues)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = document.tableNavigationError { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }
    }
}

struct VisibleTableDiscoveryPanel: View {
    @ObservedObject var discovery: VisibleTableDiscoveryModel
    @ObservedObject var diagram: ERDiagramModel
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                if discovery.isBusy { ProgressView().controlSize(.small) }
                Text("\(discovery.schemasChecked) / \(discovery.schemaCount) schemas · \(discovery.tables.count) tables")
                    .font(.caption2).monospacedDigit()
                Spacer(minLength: 0)
                if discovery.isBusy { Button("Stop") { discovery.stop() }.controlHover() }
            }
            if let notice = discovery.notice { Text(notice).font(.caption2).foregroundStyle(discovery.complete ? Color.secondary : Color.orange).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(discovery.tables) { table in
                        HStack {
                            Text(table.label).font(.caption).lineLimit(2).help(table.label)
                            Spacer(minLength: 0)
                            Button(diagram.stored.tables.contains(table) ? "Added" : "Add") { diagram.add(table) }
                                .controlHover().disabled(diagram.stored.tables.contains(table) || diagram.isLoading || diagram.stored.tables.count >= ERDiagramLimits.tables)
                        }
                    }
                    CatalogDiscoveryIssueList(issues: discovery.issues)
                }
            }.frame(maxHeight: 180)
        }.controlSize(.small)
    }
}

struct ERNeighbourDiscoveryPanel: View {
    @ObservedObject var discovery: IncomingRelationshipDiscoveryModel
    @ObservedObject var diagram: ERDiagramModel
    private var neighbours: [ERTableID] {
        var seen = Set<ERTableID>()
        return discovery.relationships.flatMap { [$0.source, $0.target] }.filter { $0 != (discovery.resolvedTarget ?? discovery.target) && seen.insert($0).inserted }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Neighbours").font(.callout).fontWeight(.medium)
                Spacer()
                if discovery.isBusy {
                    ProgressView().controlSize(.small)
                    Button("Stop") { discovery.stop() }.controlHover()
                }
            }
            Text("\(discovery.sourcesChecked) / \(discovery.sourceCount) incoming sources inspected")
                .font(.caption2).monospacedDigit().appSecondaryText()
            if let notice = discovery.notice { Text(notice).font(.caption2).foregroundStyle(discovery.complete ? Color.secondary : Color.orange).textSelection(.enabled) }
            ForEach(neighbours) { table in
                HStack {
                    Text(table.label).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button(diagram.stored.tables.contains(table) ? "Added" : "Add") { diagram.add(table) }
                        .controlHover().disabled(diagram.stored.tables.contains(table) || diagram.isLoading || diagram.stored.tables.count >= ERDiagramLimits.tables)
                }
            }
            Text("Add chosen neighbours, then Build to update the selected area (100 tables maximum).")
                .font(.caption2).appSecondaryText()
            CatalogDiscoveryIssueList(issues: discovery.issues)
        }.controlSize(.small)
    }
}

private struct CatalogDiscoveryIssueList: View {
    let issues: [CatalogDiscoveryIssue]
    var body: some View {
        ForEach(issues) { issue in
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.object).fontWeight(.medium)
                Text(issue.message)
            }.font(.caption2).foregroundStyle(.orange).textSelection(.enabled)
        }
    }
}
