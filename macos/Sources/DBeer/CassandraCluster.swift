import Foundation

struct CassandraClusterNode: Identifiable {
    let id = UUID()
    let address: String
    let status: String
    let datacenter: String
    let rack: String
    let hostID: String

    init(_ record: [String: String]) {
        address = record["address"] ?? ""
        let observed = record["status"] ?? "UNKNOWN"
        status = ["UP", "DOWN"].contains(observed) ? observed : "UNKNOWN"
        datacenter = record["datacenter"] ?? ""
        rack = record["rack"] ?? ""
        hostID = record["hostId"] ?? ""
    }
}

struct CassandraClusterInspection: Identifiable {
    let id = UUID()
    let profileID: UUID
    let sessionID: String
    let title: String
    var nodes: [CassandraClusterNode] = []
    var totalNodeCount: Int64 = 0
    var refreshedAt: Date?
    var notice: String?
    var error: String?
    var isLoading = false
}
