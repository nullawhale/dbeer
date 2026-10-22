import Foundation

/// Pane assignment is presentation state; documents remain the sole owners of
/// their working sessions, editor state and result drafts.
enum WorkspacePaneID: String, Codable, CaseIterable, Sendable {
    case left, right

    var other: WorkspacePaneID { self == .left ? .right : .left }
}

struct WorkspacePaneState: Codable, Equatable, Sendable {
    var documentIDs: [UUID]
    var selectedDocumentID: UUID?

    init(documentIDs: [UUID] = [], selectedDocumentID: UUID? = nil) {
        self.documentIDs = documentIDs
        self.selectedDocumentID = selectedDocumentID
    }

    private enum CodingKeys: String, CodingKey { case documentIDs, selectedDocumentID }

    init(from decoder: Decoder) throws {
        try requirePaneKeys(decoder, allowed: ["documentIDs", "selectedDocumentID"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        documentIDs = try values.decode([UUID].self, forKey: .documentIDs)
        selectedDocumentID = try values.decodeIfPresent(UUID.self, forKey: .selectedDocumentID)
    }
}

struct WorkspacePaneLayout: Codable, Equatable, Sendable {
    static let splitRange = 0.2...0.8
    var left: WorkspacePaneState
    var right: WorkspacePaneState
    var activePaneID: WorkspacePaneID
    var splitFraction: Double

    init(left: WorkspacePaneState = WorkspacePaneState(), right: WorkspacePaneState = WorkspacePaneState(),
         activePaneID: WorkspacePaneID = .left, splitFraction: Double = 0.5) {
        self.left = left
        self.right = right
        self.activePaneID = activePaneID
        self.splitFraction = splitFraction
    }

    static func singlePane(documentIDs: [UUID] = [], selectedDocumentID: UUID? = nil) -> Self {
        Self(left: WorkspacePaneState(documentIDs: documentIDs,
            selectedDocumentID: selectedDocumentID ?? documentIDs.first))
    }

    subscript(_ pane: WorkspacePaneID) -> WorkspacePaneState {
        get { pane == .left ? left : right }
        set {
            switch pane {
            case .left: left = newValue
            case .right: right = newValue
            }
        }
    }

    var selectedDocumentID: UUID? { self[activePaneID].selectedDocumentID }

    func pane(containing id: UUID) -> WorkspacePaneID? {
        WorkspacePaneID.allCases.first { self[$0].documentIDs.contains(id) }
    }

    func isValid(documentIDs: [UUID]) -> Bool {
        let assigned = left.documentIDs + right.documentIDs
        guard splitFraction.isFinite, Self.splitRange.contains(splitFraction),
              Set(documentIDs).count == documentIDs.count,
              assigned.count == documentIDs.count, Set(assigned) == Set(documentIDs) else { return false }
        return WorkspacePaneID.allCases.allSatisfy { pane in
            let state = self[pane]
            return state.documentIDs.isEmpty ? state.selectedDocumentID == nil
                : state.selectedDocumentID.map(state.documentIDs.contains) == true
        }
    }

    /// Removing a selected tab chooses its next neighbor, or its previous
    /// neighbor at the end, without changing another pane or active ownership.
    mutating func removeDocument(_ id: UUID) {
        guard let pane = pane(containing: id), let index = self[pane].documentIDs.firstIndex(of: id) else { return }
        var state = self[pane]
        state.documentIDs.remove(at: index)
        if state.selectedDocumentID == id {
            state.selectedDocumentID = state.documentIDs.isEmpty ? nil
                : state.documentIDs[min(index, state.documentIDs.count - 1)]
        }
        self[pane] = state
    }

    mutating func insertDocument(_ id: UUID, in pane: WorkspacePaneID, at index: Int? = nil, select: Bool = true) {
        removeDocument(id)
        var state = self[pane]
        state.documentIDs.insert(id, at: min(max(0, index ?? state.documentIDs.count), state.documentIDs.count))
        if select || state.selectedDocumentID == nil { state.selectedDocumentID = id }
        self[pane] = state
    }

    private enum CodingKeys: String, CodingKey { case left, right, activePaneID, splitFraction }

    init(from decoder: Decoder) throws {
        try requirePaneKeys(decoder, allowed: ["left", "right", "activePaneID", "splitFraction"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        left = try values.decode(WorkspacePaneState.self, forKey: .left)
        right = try values.decode(WorkspacePaneState.self, forKey: .right)
        activePaneID = try values.decode(WorkspacePaneID.self, forKey: .activePaneID)
        splitFraction = try values.decode(Double.self, forKey: .splitFraction)
    }
}

private struct PaneCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func requirePaneKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let values = try decoder.container(keyedBy: PaneCodingKey.self)
    guard values.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else { throw SQLDocumentStoreError.read }
}
