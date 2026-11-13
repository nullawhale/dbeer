import SwiftUI

struct EngineDiagnosticView: View {
    let diagnostic: EngineDiagnostic

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 10) {
                if let mongodb = diagnostic.mongodb {
                    Text("MongoDB · " + mongodb.verbosity).font(.headline)
                    Text("Planner and execution sections retain their server paths. Stage estimates overlap and are not exclusive time or an additive wall-clock total. Explain bypasses the plan cache.")
                        .font(.caption).appSecondaryText()
                    metrics(mongodb.metrics)
                    DisclosureGroup("Reported sections · \(mongodb.sections.count)") {
                        ForEach(mongodb.sections.indices, id: \.self) { index in
                            Text(mongodb.sections[index]).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    ForEach(mongodb.stages.indices, id: \.self) { index in
                        let stage = mongodb.stages[index]
                        GroupBox {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(stage.operation).fontWeight(.medium)
                                Text(stage.path).font(.system(.caption, design: .monospaced)).appSecondaryText().textSelection(.enabled)
                                metrics(stage.metrics)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if mongodb.stages.isEmpty { Text("No recognized stage records were reported. Inspect the captured raw output.").appSecondaryText() }
                } else if let cassandra = diagnostic.cassandra {
                    Text("Cassandra · Read Trace").font(.headline)
                    Text("First server page only · page size \(cassandra.pageSize) · \(cassandra.hasMorePages ? "more result pages exist" : "no further result page reported")")
                        .font(.caption).appSecondaryText()
                    Text("Trace metadata consistency: \(cassandra.collectionConsistency) · Collection: \(cassandra.collectionStatus)")
                        .font(.caption).appSecondaryText()
                    Text("Tracing executes this read. Trace events are eventually recorded; this bounded observation is incomplete. Source elapsed values belong to each source node's clock. Cross-node timestamps do not establish a global order, and elapsed values must not be added. Preparation may produce a separate trace session.")
                        .font(.caption).foregroundStyle(.orange)
                    ForEach(cassandra.traceSessions.indices, id: \.self) { index in
                        let session = cassandra.traceSessions[index]
                        GroupBox {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(session.command + " · " + session.id).font(.headline).textSelection(.enabled)
                                Text("Coordinator: \(session.coordinator) · Started: \(session.startedAt)").font(.caption).textSelection(.enabled)
                                Text(session.duration.label).font(.caption).textSelection(.enabled)
                                ForEach(session.events.indices, id: \.self) { eventIndex in
                                    let event = session.events[eventIndex]
                                    Divider()
                                    Text(event.activity).textSelection(.enabled)
                                    Text("\(event.source) · \(event.thread) · \(event.timestamp)").font(.caption).appSecondaryText().textSelection(.enabled)
                                    Text(event.sourceElapsed.label).font(.caption).textSelection(.enabled)
                                    Text(event.id).font(.system(.caption2, design: .monospaced)).appSecondaryText().textSelection(.enabled)
                                }
                                if session.events.isEmpty { Text("No events were observed for this trace session.").font(.caption).appSecondaryText() }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if cassandra.traceSessions.isEmpty { Text("No trace session records were available in this bounded observation.").appSecondaryText() }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metrics(_ values: [String: DiagnosticMetric]) -> some View {
        ForEach(values.keys.sorted(), id: \.self) { key in
            Text(key + ": " + values[key]!.label).font(.caption).textSelection(.enabled)
        }
    }
}
