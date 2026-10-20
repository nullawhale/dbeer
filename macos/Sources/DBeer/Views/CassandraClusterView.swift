import SwiftUI

struct CassandraClusterView: View {
    let inspection: CassandraClusterInspection
    let refresh: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cluster Nodes").font(.title2)
                    Text(inspection.title).appSecondaryText()
                }
                Spacer()
                if inspection.isLoading { ProgressView().controlSize(.small) }
                Button("Refresh", action: refresh).controlHover()
                    .disabled(inspection.isLoading)
                    .accessibilityIdentifier("refreshClusterNodes")
                Button("Done", action: close).controlHover().keyboardShortcut(.cancelAction)
            }
            Text("Status reflects this connection's view of each node, not overall cluster health. Refresh updates the snapshot from the driver without probing nodes.")
                .font(.caption).appSecondaryText().fixedSize(horizontal: false, vertical: true)
            if let error = inspection.error {
                Text(error).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let notice = inspection.notice {
                Text(notice).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            Table(inspection.nodes) {
                TableColumn("Address") { node in
                    Text(node.address).textSelection(.enabled).help(node.address)
                }.width(min: 160, ideal: 190)
                TableColumn("Driver Status") { node in
                    Label(node.status, systemImage: "circle.fill")
                        .foregroundStyle(node.status == "UP" ? Color.green : node.status == "DOWN" ? Color.orange : Color.secondary)
                }.width(110)
                TableColumn("Datacenter") { node in
                    Text(node.datacenter.isEmpty ? "Unknown" : node.datacenter).textSelection(.enabled)
                }
                TableColumn("Rack") { node in
                    Text(node.rack.isEmpty ? "Unknown" : node.rack).textSelection(.enabled)
                }
                TableColumn("Host ID") { node in
                    Text(node.hostID).textSelection(.enabled).help(node.hostID)
                }.width(min: 180, ideal: 250)
            }
            .accessibilityIdentifier("clusterNodesTable")
            HStack {
                if Int64(inspection.nodes.count) < inspection.totalNodeCount {
                    Text("\(inspection.nodes.count) of \(inspection.totalNodeCount) discovered nodes")
                } else {
                    Text("\(inspection.nodes.count) discovered nodes")
                }
                Spacer()
                if let date = inspection.refreshedAt {
                    Text("Snapshot: \(date.formatted(date: .omitted, time: .standard))")
                }
            }.font(.caption).appSecondaryText()
            if inspection.nodes.isEmpty && !inspection.isLoading && inspection.error == nil {
                Text("The driver has not discovered any nodes.").font(.callout).appSecondaryText()
            }
        }
        .padding(20)
        .frame(minWidth: 860, minHeight: 440)
        .tint(AppPalette.accent)
        .focusEffectDisabled()
    }
}
