import Combine
import Foundation

struct LogicalRelationshipDirection: Identifiable, Sendable {
    let relationship: LogicalRelationship
    let isReversed: Bool
    var id: String { relationship.id.uuidString + (isReversed ? ":reverse" : ":forward") }
    var oriented: LogicalRelationship { isReversed ? relationship.reversed : relationship }
}

@MainActor
final class LogicalRelationshipRead: ObservableObject {
    let id = UUID()
    @Published var phase = "Reading current relationship metadata…"
    @Published private(set) var cancelled = false
    var pending: (session: String, request: CatalogMetadataRequest)?
    weak var targetDocument: SQLDocument?
    private var stopping: Task<Void, Never>?
    var stopHandler: (@MainActor () async -> Void)?
    func stop() async {
        if let stopping { await stopping.value; return }
        cancelled = true; phase = "Stopping related-row navigation…"
        let stopping = Task { @MainActor [self] in _ = await stopHandler?() }
        self.stopping = stopping
        await stopping.value
    }
}

struct LogicalRelationshipSource {
    let reference: TableReference
    let columns: [ResultColumn]
    let declarations: [String]
    let typeOIDs: [UInt32]
    let baseTypeOIDs: [UInt32]
    let fromQuery: Bool
}
