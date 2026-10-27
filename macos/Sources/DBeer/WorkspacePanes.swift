import Foundation

/// Pane assignment is presentation state; documents own their working sessions.
struct WorkspacePaneID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init() { rawValue = UUID().uuidString }
    static let left = Self(rawValue: "left")
    static let right = Self(rawValue: "right")

    var isValid: Bool { self == .left || self == .right || UUID(uuidString: rawValue) != nil }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
        guard isValid else { throw SQLDocumentStoreError.read }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(rawValue)
    }
}

enum WorkspaceSplitDirection: String, CaseIterable, Sendable {
    case left, right, up, down
    var title: String { "Split " + rawValue.capitalized }
    var axis: WorkspaceSplitAxis { self == .left || self == .right ? .horizontal : .vertical }
    var insertsFirst: Bool { self == .left || self == .up }
}

enum WorkspaceSplitAxis: String, Codable, Sendable { case horizontal, vertical }

indirect enum WorkspacePaneNode: Codable, Equatable, Sendable {
    case pane(WorkspacePaneID)
    case split(id: UUID, axis: WorkspaceSplitAxis, fraction: Double, first: Self, second: Self)

    static let legacySplitID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    var paneIDs: [WorkspacePaneID] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, _, let first, let second): first.paneIDs + second.paneIDs
        }
    }

    var splitIDs: [UUID] {
        switch self {
        case .pane: []
        case .split(let id, _, _, let first, let second): [id] + first.splitIDs + second.splitIDs
        }
    }

    var fraction: Double? {
        if case .split(_, _, let fraction, _, _) = self { fraction } else { nil }
    }

    func isValid(depth: Int = 0) -> Bool {
        guard depth < 16 else { return false }
        switch self {
        case .pane(let id): return id.isValid
        case .split(_, _, let fraction, let first, let second):
            return fraction.isFinite && WorkspacePaneLayout.splitRange.contains(fraction) &&
                first.isValid(depth: depth + 1) && second.isValid(depth: depth + 1)
        }
    }

    func replacingPane(_ pane: WorkspacePaneID, with replacement: Self) -> Self {
        switch self {
        case .pane(let id): return id == pane ? replacement : self
        case .split(let id, let axis, let fraction, let first, let second):
            return .split(id: id, axis: axis, fraction: fraction,
                first: first.replacingPane(pane, with: replacement), second: second.replacingPane(pane, with: replacement))
        }
    }

    func settingFraction(_ fraction: Double, for splitID: UUID) -> Self {
        switch self {
        case .pane: return self
        case .split(let id, let axis, let current, let first, let second):
            return .split(id: id, axis: axis, fraction: id == splitID ? fraction : current,
                first: first.settingFraction(fraction, for: splitID), second: second.settingFraction(fraction, for: splitID))
        }
    }

    func siblingPane(for pane: WorkspacePaneID) -> WorkspacePaneID? {
        guard case .split(_, _, _, let first, let second) = self else { return nil }
        if first == .pane(pane) { return second.paneIDs.first }
        if second == .pane(pane) { return first.paneIDs.last }
        return first.siblingPane(for: pane) ?? second.siblingPane(for: pane)
    }

    func removingPane(_ pane: WorkspacePaneID) -> Self? {
        switch self {
        case .pane(let id): return id == pane ? nil : self
        case .split(let id, let axis, let fraction, let first, let second):
            guard let remainingFirst = first.removingPane(pane) else { return second }
            guard let remainingSecond = second.removingPane(pane) else { return first }
            return .split(id: id, axis: axis, fraction: fraction, first: remainingFirst, second: remainingSecond)
        }
    }

    private enum CodingKeys: String, CodingKey { case paneID, splitID, axis, fraction, first, second }

    init(from decoder: Decoder) throws {
        guard decoder.codingPath.count < 64 else { throw SQLDocumentStoreError.read }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.paneID) {
            try requirePaneKeys(decoder, allowed: ["paneID"])
            self = .pane(try values.decode(WorkspacePaneID.self, forKey: .paneID))
        } else {
            try requirePaneKeys(decoder, allowed: ["splitID", "axis", "fraction", "first", "second"])
            self = .split(id: try values.decode(UUID.self, forKey: .splitID),
                axis: try values.decode(WorkspaceSplitAxis.self, forKey: .axis),
                fraction: try values.decode(Double.self, forKey: .fraction),
                first: try values.decode(Self.self, forKey: .first), second: try values.decode(Self.self, forKey: .second))
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let id): try values.encode(id, forKey: .paneID)
        case .split(let id, let axis, let fraction, let first, let second):
            try values.encode(id, forKey: .splitID)
            try values.encode(axis, forKey: .axis)
            try values.encode(fraction, forKey: .fraction)
            try values.encode(first, forKey: .first)
            try values.encode(second, forKey: .second)
        }
    }
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
    static let maximumPanes = 32
    // Keep the original slots so v8/v9 layouts migrate without renaming panes.
    var left: WorkspacePaneState
    var right: WorkspacePaneState
    var activePaneID: WorkspacePaneID
    var splitFraction: Double
    var tree: WorkspacePaneNode?
    private var additionalPanes: [String: WorkspacePaneState] = [:]

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
        get {
            if pane == .left { return left }
            if pane == .right { return right }
            return additionalPanes[pane.rawValue] ?? WorkspacePaneState()
        }
        set {
            if pane == .left { left = newValue }
            else if pane == .right { right = newValue }
            else { additionalPanes[pane.rawValue] = newValue }
        }
    }

    var root: WorkspacePaneNode {
        if let tree { return tree }
        if !right.documentIDs.isEmpty || activePaneID == .right {
            return .split(id: WorkspacePaneNode.legacySplitID, axis: .horizontal, fraction: splitFraction,
                first: .pane(.left), second: .pane(.right))
        }
        return .pane(.left)
    }

    var paneIDs: [WorkspacePaneID] { root.paneIDs }
    var storedPaneIDs: [WorkspacePaneID] { [.left, .right] + additionalPanes.keys.sorted().map { WorkspacePaneID(rawValue: $0) } }
    var selectedDocumentID: UUID? { self[activePaneID].selectedDocumentID }
    var isSplit: Bool { paneIDs.count > 1 }
    var canSplit: Bool { paneIDs.count < Self.maximumPanes && root.isValid(depth: 1) }

    func pane(containing id: UUID) -> WorkspacePaneID? {
        storedPaneIDs.first { self[$0].documentIDs.contains(id) }
    }

    mutating func ensurePane(_ pane: WorkspacePaneID) {
        guard !paneIDs.contains(pane) else { return }
        if tree == nil, pane == .right { tree = root }
        tree = .split(id: UUID(), axis: .horizontal, fraction: splitFraction, first: root, second: .pane(pane))
        self[pane] = self[pane]
    }

    mutating func split(_ pane: WorkspacePaneID, direction: WorkspaceSplitDirection) -> WorkspacePaneID? {
        guard canSplit, paneIDs.contains(pane) else { return nil }
        let destination = !paneIDs.contains(.right) && self[.right].documentIDs.isEmpty ? WorkspacePaneID.right : WorkspacePaneID()
        let branch = WorkspacePaneNode.split(id: UUID(), axis: direction.axis, fraction: 0.5,
            first: .pane(direction.insertsFirst ? destination : pane), second: .pane(direction.insertsFirst ? pane : destination))
        tree = root.replacingPane(pane, with: branch)
        self[destination] = WorkspacePaneState()
        return destination
    }

    /// Remove only this leaf, merging its tabs into the nearest sibling leaf.
    @discardableResult
    mutating func unsplit(_ pane: WorkspacePaneID) -> WorkspacePaneID? {
        guard let destination = root.siblingPane(for: pane), let remaining = root.removingPane(pane) else { return nil }
        let source = self[pane]
        var target = self[destination]
        target.documentIDs += source.documentIDs
        if pane == activePaneID { target.selectedDocumentID = source.selectedDocumentID ?? target.selectedDocumentID }
        if target.selectedDocumentID == nil { target.selectedDocumentID = source.selectedDocumentID ?? target.documentIDs.first }
        self[destination] = target
        self[pane] = WorkspacePaneState()
        additionalPanes[pane.rawValue] = nil
        tree = remaining
        if activePaneID == pane { activePaneID = destination }
        return destination
    }

    mutating func unsplitAll() {
        let selection = selectedDocumentID
        let ids = paneIDs.flatMap { self[$0].documentIDs }
        let fraction = splitFraction
        self = .singlePane(documentIDs: ids, selectedDocumentID: selection)
        splitFraction = fraction
    }

    mutating func setFraction(_ fraction: Double, for splitID: UUID) {
        if tree == nil, splitID == WorkspacePaneNode.legacySplitID { splitFraction = fraction }
        else { tree = root.settingFraction(fraction, for: splitID) }
    }

    func isValid(documentIDs: [UUID]) -> Bool {
        let ids = paneIDs
        let assigned = storedPaneIDs.flatMap { self[$0].documentIDs }
        guard splitFraction.isFinite, Self.splitRange.contains(splitFraction), root.isValid(),
              ids.count <= Self.maximumPanes, Set(ids).count == ids.count, ids.contains(activePaneID),
              Set(root.splitIDs).count == root.splitIDs.count,
              Set(ids.filter { $0 != .left && $0 != .right }.map(\.rawValue)) == Set(additionalPanes.keys),
              Set(additionalPanes.keys).allSatisfy({ key in
                  let id = WorkspacePaneID(rawValue: key)
                  return id.isValid && id != .left && id != .right && ids.contains(id)
              }),
              Set(documentIDs).count == documentIDs.count,
              assigned.count == documentIDs.count, Set(assigned) == Set(documentIDs) else { return false }
        return storedPaneIDs.allSatisfy { pane in
            let state = self[pane]
            if !ids.contains(pane), !state.documentIDs.isEmpty || state.selectedDocumentID != nil { return false }
            return state.documentIDs.isEmpty ? state.selectedDocumentID == nil
                : state.selectedDocumentID.map(state.documentIDs.contains) == true
        }
    }

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
        // Original two-pane callers can still explicitly open the right pane.
        if tree != nil || (pane != .left && pane != .right) { ensurePane(pane) }
        removeDocument(id)
        var state = self[pane]
        state.documentIDs.insert(id, at: min(max(0, index ?? state.documentIDs.count), state.documentIDs.count))
        if select || state.selectedDocumentID == nil { state.selectedDocumentID = id }
        self[pane] = state
    }

    private enum CodingKeys: String, CodingKey { case left, right, activePaneID, splitFraction, tree, additionalPanes }

    init(from decoder: Decoder) throws {
        try requirePaneKeys(decoder, allowed: ["left", "right", "activePaneID", "splitFraction", "tree", "additionalPanes"])
        try self.init(values: decoder.container(keyedBy: CodingKeys.self))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if values.contains(.tree) { tree = try values.decode(WorkspacePaneNode.self, forKey: .tree) }
        if values.contains(.additionalPanes) { additionalPanes = try values.decode([String: WorkspacePaneState].self, forKey: .additionalPanes) }
    }

    init(legacyFrom decoder: Decoder) throws {
        try requirePaneKeys(decoder, allowed: ["left", "right", "activePaneID", "splitFraction"])
        try self.init(values: decoder.container(keyedBy: CodingKeys.self))
        guard activePaneID == .left || activePaneID == .right else { throw SQLDocumentStoreError.read }
    }

    private init(values: KeyedDecodingContainer<CodingKeys>) throws {
        left = try values.decode(WorkspacePaneState.self, forKey: .left)
        right = try values.decode(WorkspacePaneState.self, forKey: .right)
        activePaneID = try values.decode(WorkspacePaneID.self, forKey: .activePaneID)
        splitFraction = try values.decode(Double.self, forKey: .splitFraction)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(left, forKey: .left)
        try values.encode(right, forKey: .right)
        try values.encode(activePaneID, forKey: .activePaneID)
        try values.encode(splitFraction, forKey: .splitFraction)
        try values.encodeIfPresent(tree, forKey: .tree)
        if !additionalPanes.isEmpty { try values.encode(additionalPanes, forKey: .additionalPanes) }
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
