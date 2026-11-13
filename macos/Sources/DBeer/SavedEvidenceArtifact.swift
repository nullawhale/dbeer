import Foundation

enum SavedEvidenceKind: String, Codable, CaseIterable, Sendable {
    case structure, diagnostic
    var title: String { self == .structure ? "Structure outcome" : "Session diagnostic" }
}

struct SavedEvidenceReference: Codable, Hashable, Sendable, Identifiable {
    var kind: SavedEvidenceKind
    var id: UUID
}

/// A copied observation has no live baseline handle. Its display projection is
/// local-only and cannot resolve an operation in any helper session.
struct SavedStructureObservation: Codable, Equatable, Sendable {
    var target: StructureTarget
    var engine: String
    var fingerprint: String
    var columns: [StructureObservedColumn]
    var limitations: [String]
    var keys: [StructureKey]?
    var indexes: [StructureIndex]?
    var dependencyProof: Bool?

    init(_ value: StructureBaseline) {
        target = value.target; engine = value.engine; fingerprint = value.fingerprint
        columns = value.columns; limitations = value.limitations; keys = value.keys
        indexes = value.indexes; dependencyProof = value.dependencyProof
    }
    var displayBaseline: StructureBaseline {
        .init(id: "offline-evidence", target: target, engine: engine, fingerprint: fingerprint,
            columns: columns, limitations: limitations, keys: keys, indexes: indexes, dependencyProof: dependencyProof)
    }
    var valid: Bool { displayBaseline.valid }
}

struct SavedStructureEvidence: Codable, Equatable, Sendable {
    var historicalPlanID: String
    var historicalExecutionID: String
    var digest: String
    var target: StructureTarget
    var resultTarget: StructureTarget?
    var sql: [String]
    var risks: [String]
    var destructive: Bool?
    var droppedTarget: Bool? = nil
    var consequences: [StructureConsequence]? = nil
    var validationChecks: [StructureValidationCheck]? = nil
    var validation: StructureValidationOutcome? = nil
    var draft: StructureDraft
    var state: String
    var steps: [StructureStepOutcome]
    var refreshError: String?
    var observed: SavedStructureObservation?

    init(_ review: TableStructureExecutionReview) throws {
        guard review.plan.valid, review.draft.valid, review.outcome.valid,
              review.outcome.planId.utf8.elementsEqual(review.plan.id.utf8),
              review.outcome.droppedTarget == (review.plan.droppedTarget && review.outcome.state == "applied"),
              Self.validStepCount(state: review.outcome.state, steps: review.outcome.steps, sqlCount: review.plan.sql.count) else {
            throw PlanArtifactError.invalid
        }
        historicalPlanID = review.plan.id; historicalExecutionID = review.outcome.executionId
        digest = review.plan.digest; target = review.plan.target; resultTarget = review.plan.resultTarget
        sql = review.plan.sql; risks = review.plan.risks; destructive = review.plan.destructive
        droppedTarget = review.plan.droppedTarget ? true : nil; consequences = review.plan.consequences.isEmpty ? nil : review.plan.consequences
        validationChecks = review.plan.validationChecks.isEmpty ? nil : review.plan.validationChecks; validation = review.validation
        draft = review.draft; state = review.outcome.state; steps = review.outcome.steps
        refreshError = review.outcome.refreshError; observed = review.outcome.observed.map(SavedStructureObservation.init)
    }
    /// Historical labels are displayed, never submitted. No apply/preview owner is retained.
    var displayReview: TableStructureExecutionReview {
        .init(outcome: .init(executionId: historicalExecutionID, planId: historicalPlanID, state: state,
                steps: steps, observed: observed?.displayBaseline, refreshError: refreshError, droppedTarget: droppedTarget == true && state == "applied"),
            plan: .init(id: historicalPlanID, baselineId: "offline-evidence", digest: digest,
                target: target, sql: sql, risks: risks, destructive: destructive, resultTarget: resultTarget, droppedTarget: droppedTarget ?? false, consequences: consequences ?? [], validationChecks: validationChecks ?? []), draft: draft, validation: validation)
    }
    private static func validStepCount(state: String, steps: [StructureStepOutcome], sqlCount: Int) -> Bool {
        // A lost aggregate completion is retained as recorded, without fabricated step acknowledgements.
        steps.count == sqlCount || state == "outcomeUnknown" && steps.count == 1 && steps[0].state == "unknown"
    }
    var valid: Bool {
        guard displayReview.plan.valid, draft.valid, displayReview.outcome.valid,
              Self.validStepCount(state: state, steps: steps, sqlCount: sql.count), observed?.valid ?? true,
              validation.map { $0.valid && $0.planId.utf8.elementsEqual(historicalPlanID.utf8) && $0.digest == digest && $0.checks.map({ Data($0.id.utf8) }) == (validationChecks ?? []).map({ Data($0.id.utf8) }) } ?? true else { return false }
        guard let observed else { return true }
        return (observed.target.create == (droppedTarget == true && state == "applied")) && StructureTarget.sameIdentifier(observed.target.schema, target.schema) &&
            (StructureTarget.sameIdentifier(observed.target.table, target.table) || resultTarget.map { StructureTarget.sameIdentifier(observed.target.table, $0.table) } == true)
    }
}

struct SavedEvidenceArtifact: Codable, Equatable, Sendable, Identifiable {
    static let currentVersion = 4
    static let maximumBytes = 8 * 1_024 * 1_024
    var version = Self.currentVersion
    var id: UUID
    var kind: SavedEvidenceKind
    var title: String
    var savedAt: Date
    var engine: DatabaseEngine
    var profileName: String?
    var environment: ConnectionEnvironment
    var sourceWasStale: Bool
    var structure: SavedStructureEvidence?
    var diagnostic: SessionMonitorSnapshot?
    var reference: SavedEvidenceReference { .init(kind: kind, id: id) }
    var complete: Bool {
        if let structure { return !["applying", "outcomeUnknown"].contains(structure.state) }
        return diagnostic.map { $0.sessionsComplete && $0.waitsComplete } == true
    }
    var valid: Bool {
        guard version == Self.currentVersion, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 16_384, !title.contains("\0"), savedAt.timeIntervalSince1970.isFinite,
              (profileName?.utf8.count ?? 0) <= 16_384, profileName?.contains("\0") != true else { return false }
        switch kind {
        case .structure:
            return diagnostic == nil && structure?.valid == true && [.postgresql, .mysql, .sqlite].contains(engine) &&
                (structure?.observed.map { $0.engine == engine.rawValue } ?? true)
        case .diagnostic:
            return structure == nil && diagnostic?.valid == true && diagnostic?.engine == engine
        }
    }

    @MainActor static func capture(_ model: TableStructureEditorModel, title: String) throws -> Self {
        guard let review = model.outcomeReview else { throw PlanArtifactError.invalid }
        let value = Self(id: UUID(), kind: .structure, title: title, savedAt: saveTime(), engine: model.profile.engine,
            profileName: model.profile.name, environment: model.profile.policy.environment, sourceWasStale: model.invalidated,
            structure: try SavedStructureEvidence(review), diagnostic: nil)
        guard value.valid else { throw PlanArtifactError.invalid }
        return value
    }
    @MainActor static func capture(_ model: SessionMonitorModel, title: String) throws -> Self {
        guard let snapshot = model.snapshot else { throw PlanArtifactError.invalid }
        let value = Self(id: UUID(), kind: .diagnostic, title: title, savedAt: saveTime(), engine: snapshot.engine,
            profileName: model.profile.name, environment: model.profile.policy.environment, sourceWasStale: model.isStale,
            structure: nil, diagnostic: snapshot)
        guard value.valid else { throw PlanArtifactError.invalid }
        return value
    }
    private static func saveTime() -> Date { Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1_000).rounded() / 1_000) }

    func encoded() throws -> String {
        guard valid else { throw PlanArtifactError.invalid }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw PlanArtifactError.invalid }
        return String(decoding: data, as: UTF8.self)
    }
    static func decode(_ text: String) throws -> Self {
        let data = Data(text.utf8)
        try ExactJSONKeys.validate(data, maximumBytes: maximumBytes)
        let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let allowed: Set<String> = ["version", "id", "kind", "title", "savedAt", "engine", "profileName", "environment", "sourceWasStale", "structure", "diagnostic"]
        guard let fields, Set(fields.keys).isSubset(of: allowed), !fields.values.contains(where: { $0 is NSNull }) else { throw PlanArtifactError.invalid }
        func closed(_ object: Any?, keys: Set<String>) throws -> [String: Any] {
            guard let object = object as? [String: Any], Set(object.keys).isSubset(of: keys),
                  !object.values.contains(where: { $0 is NSNull }) else { throw PlanArtifactError.invalid }
            return object
        }
        if let structure = fields["structure"] {
            let record = try closed(structure, keys: ["historicalPlanID", "historicalExecutionID", "digest", "target", "resultTarget", "sql", "risks", "destructive", "droppedTarget", "consequences", "validationChecks", "validation", "draft", "state", "steps", "refreshError", "observed"])
            if let observed = record["observed"] {
                _ = try closed(observed, keys: ["target", "engine", "fingerprint", "columns", "limitations", "keys", "indexes", "dependencyProof"])
            }
            for step in record["steps"] as? [Any] ?? [] { _ = try closed(step, keys: ["state", "message"]) }
        }
        if let diagnostic = fields["diagnostic"] {
            let record = try closed(diagnostic, keys: ["engine", "collectionStartedAt", "collectedAt", "sessions", "waits", "sessionsComplete", "waitsComplete", "notices"])
            for session in record["sessions"] as? [Any] ?? [] {
                _ = try closed(session, keys: ["id", "user", "database", "client", "application", "state", "query", "queryAgeMs", "transactionAgeMs", "waitType", "waitEvent", "isMonitor", "queryTruncated"])
            }
            for wait in record["waits"] as? [Any] ?? [] { _ = try closed(wait, keys: ["waitingId", "blockingId", "kind", "object", "lockMode"]) }
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        var value = try decoder.decode(Self.self, from: data)
        if value.version < 4, let structure = fields["structure"] as? [String: Any], let draft = structure["draft"] as? [String: Any] {
            guard !draft.keys.contains(where: { ["backfills", "columnOrder", "reconstruct"].contains($0) }),
                  value.structure?.draft.authoringVersion != 5 else { throw PlanArtifactError.invalid }
        }
        guard [1, 2, 3, Self.currentVersion].contains(value.version),
              value.version != 1 || (value.structure.map { !$0.draft.requiresIndexAuthoring && $0.draft.authoringVersion != 3 && !($0.observed?.indexes ?? []).contains { $0.definition != nil } } ?? true),
              value.version >= 3 || (value.structure.map { !$0.draft.requiresDestructiveAuthoring && $0.draft.authoringVersion != 4 && $0.droppedTarget == nil && $0.consequences == nil && $0.validationChecks == nil && $0.validation == nil && !($0.observed?.displayBaseline.requiresDestructiveAuthoring ?? false) } ?? true) else { throw PlanArtifactError.invalid }
        value.version = Self.currentVersion
        guard value.valid else { throw PlanArtifactError.invalid }
        return value
    }
}

struct SavedEvidenceSummary: Identifiable, Equatable, Sendable {
    var reference: SavedEvidenceReference
    var id: UUID { reference.id }
    var kind: SavedEvidenceKind { reference.kind }
    var title: String
    var savedAt: Date
    var engine: DatabaseEngine
    var profileName: String?
    var complete: Bool
    var isAvailable = true
    init(_ value: SavedEvidenceArtifact) {
        reference = value.reference; title = value.title; savedAt = value.savedAt; engine = value.engine
        profileName = value.profileName; complete = value.complete
    }
    init(unavailable id: UUID) {
        reference = .init(kind: .structure, id: id); title = "Unavailable saved evidence"
        savedAt = .distantPast; engine = .postgresql; profileName = nil; complete = false; isAvailable = false
    }
}
