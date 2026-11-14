import Foundation

enum ERStructureAction: Sendable {
    case create(profileID: UUID, schema: String)
    case edit(ERTableID)
    case addForeignKey(ERTableID)
    case createForeignKey(ERRelationship)

    var profileID: UUID {
        switch self {
        case .create(let id, _): id
        case .edit(let table), .addForeignKey(let table): table.profileID
        case .createForeignKey(let edge): edge.source.profileID
        }
    }
    var schema: String {
        switch self {
        case .create(_, let schema): schema
        case .edit(let table), .addForeignKey(let table): table.schema
        case .createForeignKey(let edge): edge.source.schema
        }
    }
    var table: ERTableID? {
        switch self {
        case .create: nil
        case .edit(let table), .addForeignKey(let table): table
        case .createForeignKey(let edge): edge.source
        }
    }
    var createsTable: Bool { if case .create = self { true } else { false } }
    var initialDraft: StructureDraft? {
        switch self {
        case .create, .edit: nil
        case .addForeignKey(let table):
            .init(columns: [], keys: [.init(action: "add", kind: "foreign", name: "", columns: [],
                reference: .init(schema: table.schema, table: "", create: false), referenceColumns: [],
                onUpdate: "NO ACTION", onDelete: "NO ACTION")])
        case .createForeignKey(let edge):
            .init(columns: [], keys: [.init(action: "add", kind: "foreign", name: "", columns: edge.key.columns.map(\.source),
                reference: .init(schema: edge.target.schema, table: edge.target.name, create: false),
                referenceColumns: edge.key.columns.map(\.target), onUpdate: "NO ACTION", onDelete: "NO ACTION")])
        }
    }

    @MainActor
    func validate(in model: ERDiagramModel) throws {
        if createsTable, model.stored.tables.count >= ERDiagramLimits.tables {
            throw ERDiagramFailure("Remove a local diagram card before creating a table from this area; diagrams retain at most 100 tables.")
        }
        guard StructureTarget.identifier(schema), table.map({ StructureTarget.identifier($0.name) }) ?? true else {
            throw ERDiagramFailure("This exact identifier exceeds the shared structure editor's supported identifier limits.")
        }
        if let table, !model.stored.tables.contains(table) {
            throw ERDiagramFailure("The source table is no longer in this diagram. Select its exact card again.")
        }
        guard case .createForeignKey(let edge) = self else { return }
        guard edge.kind == .logical else { throw ERDiagramFailure("This link is already a declared foreign key. Use Edit Structure to review its constraint.") }
        guard edge.source.profileID == edge.target.profileID else {
            throw ERDiagramFailure("A database foreign key requires both tables on the same captured saved profile. This cross-profile link remains a local mapping.")
        }
        guard edge.key.target.kind == "table", model.stored.tables.contains(edge.target) else {
            throw ERDiagramFailure("Add both exact table endpoints to this diagram before proposing a database foreign key. Views cannot be foreign-key targets.")
        }
        guard edge.isValid, edge.validationNotice == nil,
              model.relationships.contains(where: { $0.id == edge.id && $0.source == edge.source && $0.target == edge.target && $0.key.sameMapping(as: edge.key) }),
              let source = model.metadata[edge.source], let target = model.metadata[edge.target],
              source.columnState.isAvailable, target.columnState.isAvailable,
              edge.key.columns.allSatisfy({ pair in
                  source.columns.filter { Data($0.name.utf8) == Data(pair.source.utf8) }.count == 1 &&
                  target.columns.filter { Data($0.name.utf8) == Data(pair.target.utf8) }.count == 1
              }), let key = initialDraft?.keys?.first,
              StructureTarget.columns(key.columns ?? []), key.reference?.valid == true,
              StructureTarget.columns(key.referenceColumns ?? []) else {
            throw ERDiagramFailure("Build both endpoints and validate this exact local mapping before proposing a database foreign key. Shared Preview will check the actual keys, types and dependencies.")
        }
    }
}

@MainActor
final class ERStructureInvocation {
    let documentID: UUID
    let source: ERDiagramSource
    let context: ERDiagramLoadContext
    let action: ERStructureAction
    private let sourceLifetime: UUID?
    private let tableLifetime: UUID?
    private let targetLifetime: UUID?
    private(set) var acknowledgedTable: ERTableID?

    init(documentID: UUID, source: ERDiagramSource, context: ERDiagramLoadContext, action: ERStructureAction, model: ERDiagramModel) {
        self.documentID = documentID; self.source = source; self.context = context; self.action = action
        sourceLifetime = model.sourceBindingLifetime(source.profileID)
        tableLifetime = action.table.flatMap { model.tableBindingLifetime($0) }
        if case .createForeignKey(let edge) = action { targetLifetime = model.tableBindingLifetime(edge.target) }
        else { targetLifetime = nil }
    }
    func bindingLifetimesAreCurrent(in model: ERDiagramModel) -> Bool {
        guard let sourceLifetime, model.sourceBindingLifetime(source.profileID) == sourceLifetime else { return false }
        if let table = action.table {
            guard let tableLifetime else { return false }
            let originalIsCurrent = model.stored.tables.contains(table) && model.tableBindingLifetime(table) == tableLifetime
            let renamedIsCurrent = acknowledgedTable.map { model.stored.tables.contains($0) && model.tableBindingLifetime($0) == tableLifetime } == true
            guard originalIsCurrent || renamedIsCurrent else { return false }
        }
        if case .createForeignKey(let edge) = action, edge.target != edge.source {
            guard let targetLifetime, model.stored.tables.contains(edge.target), model.tableBindingLifetime(edge.target) == targetLifetime else { return false }
        }
        return true
    }
    func acknowledge(_ review: TableStructureExecutionReview) {
        guard review.outcome.state == "applied", let original = acknowledgedTable ?? action.table,
              StructureTarget.sameIdentifier(review.plan.target.schema, original.schema),
              StructureTarget.sameIdentifier(review.plan.target.table, original.name), let result = review.plan.resultTarget else { return }
        acknowledgedTable = .init(profileID: source.profileID, schema: result.schema, name: result.table)
    }
}

extension ERDiagramModel {
    /// Only a known completed rename changes card identity; layout remains local.
    func acceptStructureResult(_ review: TableStructureExecutionReview, profileID: UUID, addCreatedTable: Bool) {
        guard review.outcome.state == "applied" else { return }
        let original = ERTableID(profileID: profileID, schema: review.plan.target.schema, name: review.plan.target.table)
        let result = review.plan.resultTarget ?? review.plan.target
        let target = ERTableID(profileID: profileID, schema: result.schema, name: result.table)
        if review.plan.target.create {
            if addCreatedTable { add(target) }
        } else if original != target, stored.tables.contains(original) {
            guard !stored.tables.contains(target) else {
                notice = "The acknowledged rename overlaps another diagram card. Review the exact cards before removing either local entry."
                return
            }
            adoptCanonicalIdentity(original, resolved: target, preservingStructureBinding: true)
        }
    }
}
