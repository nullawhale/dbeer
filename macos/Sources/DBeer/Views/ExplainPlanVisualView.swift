import SwiftUI

enum ExplainPlanDisplay: String, CaseIterable, Identifiable {
    case tree, graph, flame, raw
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct ExplainPlanVisualView: View {
    let result: ExplainResult
    let display: ExplainPlanDisplay
    @Binding var selection: String?
    @Environment(\.applicationPaletteRevision) private var paletteRevision
    private var zoom = SwiftUI.State(initialValue: 1.0)
    private var basis = SwiftUI.State(initialValue: ExplainFlameBasis.inclusiveTime)
    private var layout: ExplainPlanLayout { ExplainPlanLayout(result) }

    var body: some View {
        let _ = paletteRevision
        VStack(alignment: .leading, spacing: 8) {
            if layout.limited { Text(layout.limitLabel).font(.caption).appSecondaryText() }
            if display == .graph {
                HStack {
                    Text("Plan structure · arrows connect parent to input").font(.caption).appSecondaryText()
                    Spacer()
                    Button("Zoom Out", systemImage: "minus.magnifyingglass") { zoom.wrappedValue = max(0.5, zoom.wrappedValue - 0.25) }.labelStyle(.iconOnly).controlHover().disabled(zoom.wrappedValue <= 0.5)
                    Button("\(Int(zoom.wrappedValue * 100))%") { zoom.wrappedValue = 1 }.controlHover().accessibilityLabel("Reset graph zoom")
                    Button("Zoom In", systemImage: "plus.magnifyingglass") { zoom.wrappedValue = min(2, zoom.wrappedValue + 0.25) }.labelStyle(.iconOnly).controlHover().disabled(zoom.wrappedValue >= 2)
                }
                graph
            } else {
                Picker("Flame metric", selection: basis.projectedValue) {
                    ForEach(ExplainFlameBasis.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.menu)
                Text(basis.wrappedValue.explanation).font(.caption).appSecondaryText()
                Text("Widths are approximate; positive values have a minimum visible width. Exact values and unavailable reasons appear on every lane.").font(.caption).appSecondaryText()
                flame
            }
            Text("Use Tab to focus an operation and Return to select it. Arrow keys select adjacent operations. Tree view provides the full keyboard and VoiceOver list.")
                .font(.caption).appSecondaryText()
        }
        .foregroundStyle(AppPalette.text)
        .onMoveCommand { direction in
            if direction == .down || direction == .right { move(1) }
            if direction == .up || direction == .left { move(-1) }
        }
    }

    private var graph: some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        for edge in layout.edges {
                            var path = Path()
                            let start = CGPoint(x: edge.parent.x + 220, y: edge.parent.y + 27)
                            let end = CGPoint(x: edge.child.x, y: edge.child.y + 27)
                            path.move(to: start)
                            path.addLine(to: CGPoint(x: start.x + 8, y: start.y))
                            path.addLine(to: CGPoint(x: start.x + 8, y: end.y))
                            path.addLine(to: end)
                            path.move(to: CGPoint(x: end.x - 5, y: end.y - 4))
                            path.addLine(to: end)
                            path.addLine(to: CGPoint(x: end.x - 5, y: end.y + 4))
                            context.stroke(path, with: .color(AppPalette.secondaryText), lineWidth: 1)
                        }
                    }.accessibilityHidden(true)
                    ForEach(layout.rows) { row in
                        Button { selection = row.id } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.node.operation).font(.callout).lineLimit(1)
                                Text(ExplainMetricPresentation.rowBadge(row.node) ?? (row.node.execution == "notExecuted" ? "Not executed" : row.node.execution.capitalized))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(width: 200, height: 38, alignment: .leading).padding(8)
                                .background(selection == row.id ? AppPalette.accent.opacity(0.16) : AppPalette.control, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selection == row.id ? AppPalette.accent : AppPalette.border))
                        }.buttonStyle(.plain).controlHover().id(row.id)
                            .accessibilityLabel("\(row.node.operation), level \(row.depth + 1), \(ExplainMetricPresentation.rowComparison(row.node))")
                            .accessibilityAddTraits(selection == row.id ? .isSelected : [])
                            .position(x: row.x + 110, y: row.y + 27)
                    }
                }.frame(width: layout.width, height: layout.height)
                    .scaleEffect(zoom.wrappedValue, anchor: .topLeading)
                    .frame(width: layout.width * zoom.wrappedValue, height: layout.height * zoom.wrappedValue, alignment: .topLeading)
            }.onChange(of: selection) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    private var flame: some View {
        let metrics = layout.rows.compactMap { basis.wrappedValue.metric($0.node) }
        let maximum = metrics.compactMap { ExplainPlanLayout.magnitude($0) }.max()
        return ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 5) {
                    if metrics.allSatisfy({ $0.value == nil }) {
                        Text("No reported values for this visual basis. Unavailable evidence is retained below.").font(.callout).appSecondaryText()
                    }
                    ForEach(layout.rows) { row in
                        let metric = basis.wrappedValue.metric(row.node)
                        let fraction = ExplainPlanLayout.fraction(metric, maximumMagnitude: maximum)
                        Button { selection = row.id } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(String(repeating: "  ", count: min(row.depth, 12)) + row.node.operation).font(.callout).lineLimit(1)
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3).fill(AppPalette.secondaryText.opacity(0.08))
                                    if let fraction, fraction > 0 {
                                        RoundedRectangle(cornerRadius: 3).fill(AppPalette.accent.opacity(0.35)).frame(width: max(8, 600 * fraction))
                                    }
                                    Text(metric.map(ExplainMetricPresentation.label) ?? "Unavailable — this capture did not report this metric")
                                        .font(.system(.caption, design: .monospaced)).lineLimit(1).padding(.horizontal, 6)
                                }.frame(width: 600, height: 24)
                            }.padding(5).background(selection == row.id ? AppPalette.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 4))
                        }.buttonStyle(.plain).controlHover().id(row.id)
                            .accessibilityLabel("\(row.node.operation), level \(row.depth + 1), \(basis.wrappedValue.title), \(metric.map(ExplainMetricPresentation.label) ?? "unavailable")")
                            .accessibilityAddTraits(selection == row.id ? .isSelected : [])
                    }
                }.padding(4)
            }.onChange(of: selection) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    private func move(_ offset: Int) {
        guard !layout.rows.isEmpty else { return }
        let index = selection.flatMap { id in layout.rows.firstIndex { $0.id == id } } ?? (offset > 0 ? -1 : layout.rows.count)
        selection = layout.rows[min(layout.rows.count - 1, max(0, index + offset))].id
    }
}

struct ExplainAdvancedMetricsView: View {
    let node: ExplainNode
    var body: some View {
        if let advanced = node.advancedMetrics {
            Text("Execution scope: \(advanced.executionScope)").font(.callout).appSecondaryText()
            Text(ExplainMetricPresentation.rowComparison(node)).textSelection(.enabled)
            Text("Proven exclusive time: \(ExplainMetricPresentation.label(advanced.exclusiveTime))").textSelection(.enabled)
            Text("Rows are per invocation and loops are total. Each timing metric states whether it is per invocation or an inclusive total across loops. Do not multiply inclusive totals by loops or sum ancestor and descendant counters.")
                .font(.caption).appSecondaryText()
            if !advanced.counters.isEmpty {
                DisclosureGroup("Buffers, I/O, WAL and Workers") { metricRows(advanced.counters) }
            }
            if let jit = advanced.jit {
                DisclosureGroup("Query JIT · aggregate including workers") { jitRows(jit) }
            }
            if !advanced.workers.isEmpty {
                DisclosureGroup("Reported Workers (\(advanced.workers.count))") {
                    Text("Per-worker evidence is separate from aggregate node and query values. Do not add it to those aggregates.").font(.caption).appSecondaryText()
                    ForEach(advanced.workers.sorted { $0.number < $1.number }, id: \.number) { worker in
                        DisclosureGroup("Worker \(worker.number)") {
                            metricRows(worker.metrics)
                            if let jit = worker.jit { DisclosureGroup("Worker JIT") { jitRows(jit) } }
                        }
                    }
                }
            }
        } else {
            Text(ExplainMetricPresentation.rowComparison(node)).font(.caption).appSecondaryText()
        }
    }
    @ViewBuilder private func metricRows(_ metrics: [String: ExplainMetric]) -> some View {
        ForEach(metrics.keys.sorted(), id: \.self) { key in
            Text("\(ExplainMetricPresentation.title(key)): \(ExplainMetricPresentation.label(metrics[key]!))").textSelection(.enabled)
        }
    }
    @ViewBuilder private func jitRows(_ jit: ExplainJITMetrics) -> some View {
        Text("JIT phases overlap: generation includes deform. Query aggregate already includes worker JIT; these are not additive.").font(.caption).appSecondaryText()
        ForEach(jit.metrics.keys.sorted(), id: \.self) { key in
            Text("\(key == "totalTime" ? "Total JIT time" : ExplainMetricPresentation.title(key)): \(ExplainMetricPresentation.label(jit.metrics[key]!))").textSelection(.enabled)
        }
    }
}
