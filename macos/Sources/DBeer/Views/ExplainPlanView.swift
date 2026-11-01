import SwiftUI

struct ExplainPlanView: View {
    let plan: ExplainPlanModel
    let stale: Bool
    private var raw = SwiftUI.State(initialValue: false)
    private var selected = SwiftUI.State<String?>(initialValue: nil)
    private var collapsed = SwiftUI.State(initialValue: Set<String>())
    private struct Row: Identifiable { let node: ExplainNode; let depth: Int; var id: String { node.id } }
    private var rows: [Row] {
        guard let result = plan.result else { return [] }
        let indexed = Dictionary(uniqueKeysWithValues: result.nodes.map { ($0.id, $0) })
        var pending = result.roots.reversed().map { ($0, 0) }
        var rows: [Row] = []
        while let (id, depth) = pending.popLast(), let node = indexed[id] {
            rows.append(Row(node: node, depth: depth))
            if !collapsed.wrappedValue.contains(id) { pending.append(contentsOf: node.children.reversed().map { ($0, depth + 1) }) }
        }
        return rows
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Execution Plan · \(plan.request.mode.title)").font(.headline)
                Text(plan.status).foregroundStyle(.secondary)
                Spacer()
                Picker("Plan display", selection: raw.projectedValue) { Text("Tree").tag(false); Text("Raw Plan").tag(true) }
                    .pickerStyle(.segmented).frame(width: 180)
            }
            if let profile = plan.profile { Text("Source: \(profile.name) · \(profile.host):\(profile.port)/\(profile.database)").font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("Captured SQL") {
                ScrollView { Text(plan.request.sql).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100)
            }
            if stale { Label("Earlier query or connection — run Explain again to refresh", systemImage: "clock.arrow.circlepath").foregroundStyle(.orange) }
            if let failure = plan.failure { Text(failure.message).foregroundStyle(.red).textSelection(.enabled) }
            if let result = plan.result {
                Text("\(result.support.engine.displayName) \(result.support.serverVersion) · \(result.support.format.uppercased()) · SQL completed")
                    .font(.caption).foregroundStyle(.secondary)
                if let diagnostic = result.diagnostic { Text(diagnostic).foregroundStyle(.orange).textSelection(.enabled) }
                if raw.wrappedValue || result.status != "tree" {
                    ScrollView([.horizontal, .vertical]) {
                        Text(result.raw).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Text(result.complete ? "Original captured server output" : "Incomplete plan output").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy Raw Plan") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.raw, forType: .string) }.controlHover()
                    }
                } else {
                    let ranking = ExplainRanking(result)
                    Text(ranking.basis).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        ForEach(ranking.entries) { entry in
                            Button { reveal(entry.id, in: result) } label: { Label(entry.operation, systemImage: "flame").lineLimit(1) }.controlHover()
                        }
                    }
                    Text("Inclusive parent and child values overlap. Do not add them; parallel work can exceed wall time.")
                        .font(.caption).foregroundStyle(.secondary)
                    HSplitView {
                        ScrollViewReader { proxy in
                        List(selection: selected.projectedValue) {
                            ForEach(rows) { row in
                                HStack(spacing: 4) {
                                    if !row.node.children.isEmpty {
                                        Button { if !collapsed.wrappedValue.insert(row.id).inserted { collapsed.wrappedValue.remove(row.id) } } label: {
                                            Image(systemName: collapsed.wrappedValue.contains(row.id) ? "chevron.right" : "chevron.down")
                                        }.buttonStyle(.plain).accessibilityLabel(collapsed.wrappedValue.contains(row.id) ? "Expand operation" : "Collapse operation")
                                    }
                                    if ranking.entries.contains(where: { $0.id == row.id }) { Image(systemName: "flame").foregroundStyle(.orange) }
                                    Text(row.node.operation).lineLimit(2)
                                    if result.roots.contains(row.id) { Text("Plan total").font(.caption).foregroundStyle(.secondary) }
                                }.padding(.leading, CGFloat(row.depth) * 12).tag(row.id).id(row.id)
                            }
                        }.onChange(of: selected.wrappedValue) { _, id in
                            if let id { proxy.scrollTo(id, anchor: .center) }
                        }
                        }.frame(minWidth: 240)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                if let node = result.nodes.first(where: { $0.id == selected.wrappedValue }) ?? result.nodes.first {
                                    Text(node.operation).font(.headline)
                                    Text(node.execution == "notExecuted" ? "Not executed" : node.execution.capitalized).foregroundStyle(.secondary)
                                    ForEach(node.metrics.keys.sorted(), id: \.self) { key in
                                        Text("\(metricTitle(key)): \(node.metrics[key]!.label)").textSelection(.enabled)
                                    }
                                    ForEach(node.details.keys.sorted(), id: \.self) { key in
                                        Text("\(key): \(node.details[key]!)").textSelection(.enabled)
                                    }
                                    Divider()
                                    ForEach(result.metrics.keys.sorted(), id: \.self) { key in
                                        Text("Server \(metricTitle(key)): \(result.metrics[key]!.label)").textSelection(.enabled)
                                    }
                                    if let duration = plan.clientDurationMs { Text("Client elapsed: \(duration.formatted(.number.precision(.fractionLength(2)))) ms").foregroundStyle(.secondary) }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }.frame(minWidth: 260)
                    }
                }
            } else { Text("Plan evidence will appear after the helper reports completion.").foregroundStyle(.secondary); Spacer() }
        }.padding(10)
    }
    private func reveal(_ id: String, in result: ExplainResult) {
        var parents: [String: String] = [:]
        for node in result.nodes { for child in node.children { parents[child] = node.id } }
        var current = id
        while let parent = parents[current] { collapsed.wrappedValue.remove(parent); current = parent }
        raw.wrappedValue = false
        selected.wrappedValue = id
    }
    private func metricTitle(_ key: String) -> String {
        switch key {
        case "startupCost": "Startup cost"
        case "totalCost": "Total cost"
        case "estimatedRows": "Estimated rows per invocation"
        case "actualRows": "Actual rows per invocation"
        case "loops": "Loops"
        case "startupTime": "First-row time"
        case "totalTime": "Last-row time"
        case "planningTime": "planning time"
        case "executionTime": "execution time"
        default: key
        }
    }
}
