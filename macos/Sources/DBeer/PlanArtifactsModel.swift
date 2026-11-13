import Combine
import Foundation

struct PlanComparison {
    struct Match: Identifiable {
        let id: Int
        let before: [ExplainNode]
        let after: [ExplainNode]
        var isAmbiguous: Bool { before.count > 1 || after.count > 1 }
        var label: String { before.first?.operation ?? after.first?.operation ?? "Operation" }
        var status: String {
            if isAmbiguous { return "Ambiguous candidates" }
            if before.isEmpty { return "Added operation" }
            if after.isEmpty { return "Removed operation" }
            let first = before[0], second = after[0]
            return PlanComparison.sameBytes(first.operation, second.operation) &&
                PlanComparison.detailChanges(before: first.details, after: second.details).isEmpty &&
                PlanComparison.sameBytes(first.execution, second.execution) &&
                PlanComparison.metricPairs(before: first.metrics, after: second.metrics).allSatisfy { $0.sameValue } &&
                first.children.count == second.children.count ? "Same recorded node properties" : "Matched operation"
        }
    }
    struct DetailChange: Identifiable {
        let id: Data
        let name: String
        let before: String?
        let after: String?
        var unicodeRepresentationChanged: Bool { before == after && !PlanComparison.sameBytes(before, after) }
    }

    struct MetricPair: Identifiable {
        let id: Data
        let name: String
        let before: ExplainMetric?
        let after: ExplainMetric?
        var sameValue: Bool {
            guard let before, let after else { return before == nil && after == nil }
            return PlanComparison.sameBytes(before.value, after.value) && PlanComparison.sameBytes(before.unit, after.unit) &&
                PlanComparison.sameBytes(before.basis, after.basis) && PlanComparison.sameBytes(before.unavailableReason, after.unavailableReason)
        }
        var sameDefinition: Bool {
            guard let before, let after else { return false }
            return PlanComparison.sameBytes(before.unit, after.unit) && PlanComparison.sameBytes(before.basis, after.basis)
        }
    }

    static func sameBytes(_ first: String?, _ second: String?) -> Bool {
        switch (first, second) {
        case (.none, .none): true
        case (.some(let first), .some(let second)): first.utf8.elementsEqual(second.utf8)
        default: false
        }
    }

    static func detailChanges(before: [String: String], after: [String: String]) -> [DetailChange] {
        let left = Dictionary(uniqueKeysWithValues: before.map { (Data($0.key.utf8), $0) })
        let right = Dictionary(uniqueKeysWithValues: after.map { (Data($0.key.utf8), $0) })
        return Set(left.keys).union(right.keys).sorted { $0.lexicographicallyPrecedes($1) }.compactMap { key in
            let first = left[key], second = right[key]
            guard !sameBytes(first?.value, second?.value) else { return nil }
            return DetailChange(id: key, name: first?.key ?? second!.key, before: first?.value, after: second?.value)
        }
    }

    static func metricPairs(before: [String: ExplainMetric], after: [String: ExplainMetric]) -> [MetricPair] {
        let left = Dictionary(uniqueKeysWithValues: before.map { (Data($0.key.utf8), $0) })
        let right = Dictionary(uniqueKeysWithValues: after.map { (Data($0.key.utf8), $0) })
        return Set(left.keys).union(right.keys).sorted { $0.lexicographicallyPrecedes($1) }.map { key in
            let first = left[key], second = right[key]
            return MetricPair(id: key, name: first?.key ?? second!.key, before: first?.value, after: second?.value)
        }
    }

    let matches: [Match]
    let comparableEngine: Bool
    let metricsComparable: Bool
    let shapeChanged: Bool
    let shapeAvailable: Bool
    let incomplete: Bool
    let diagnosticMessage: String?

    init(before: PlanArtifact, after: PlanArtifact) {
        let sameEngine = before.result.support.engine == after.result.support.engine
        if before.result.engineDiagnostic != nil || after.result.engineDiagnostic != nil {
            comparableEngine = sameEngine
            metricsComparable = false
            shapeChanged = false
            shapeAvailable = false
            incomplete = !before.result.complete || !after.result.complete
            matches = []
            diagnosticMessage = before.result.evidenceKind == after.result.evidenceKind && sameEngine ?
                "Engine diagnostic evidence is shown independently. Trace and stage measurements retain their original scope; relational node matching is unavailable." :
                "Different evidence kinds. Engine diagnostics and relational plans cannot be compared as one plan tree."
            return
        }
        diagnosticMessage = nil
        comparableEngine = sameEngine
        metricsComparable = sameEngine && Self.sameBytes(before.result.support.serverVersion, after.result.support.serverVersion) &&
            Self.sameBytes(before.result.support.format, after.result.support.format) && before.request.mode == after.request.mode && before.request.planKind == after.request.planKind &&
            before.request.options == after.request.options && before.result.format == after.result.format
        incomplete = !before.result.complete || !after.result.complete || before.result.status != "tree" || after.result.status != "tree"
        shapeAvailable = sameEngine && before.result.status == "tree" && after.result.status == "tree"
        func signature(_ node: ExplainNode) -> Data {
            let fields = ["Schema", "Relation Name", "Alias", "Index Name", "Parent Relationship"]
            let components = [node.operation] + fields.map { node.details[$0] ?? "" }
            // Length-prefixing prevents names containing separators from
            // colliding with a different set of native identity properties.
            return Data(components.map { "\($0.utf8.count)#\($0)" }.joined().utf8)
        }
        let left = Dictionary(grouping: before.result.nodes, by: signature)
        let right = Dictionary(grouping: after.result.nodes, by: signature)
        let ordered = (sameEngine ? Set(left.keys).union(right.keys) : Set(left.keys)).sorted { $0.lexicographicallyPrecedes($1) }
        matches = ordered.enumerated().map { index, key in
            Match(id: index, before: left[key] ?? [], after: sameEngine ? right[key] ?? [] : [])
        } + (sameEngine ? [] : after.result.nodes.enumerated().map { index, node in
            Match(id: ordered.count + index, before: [], after: [node])
        })
        func shape(_ result: ExplainResult) -> [Data] {
            let index = Dictionary(uniqueKeysWithValues: result.nodes.map { (Data($0.id.utf8), $0) })
            var entries: [Data] = []
            var stack = result.roots.reversed().map { (Data($0.utf8), 0) }
            while let (id, depth) = stack.popLast(), let node = index[id] {
                entries.append(Data("\(depth):".utf8) + signature(node))
                stack.append(contentsOf: node.children.reversed().map { (Data($0.utf8), depth + 1) })
            }
            return entries
        }
        shapeChanged = !sameEngine || shape(before.result) != shape(after.result)
    }
}

@MainActor
final class PlanArtifactsModel: ObservableObject {
    let store: PlanArtifactStore
    @Published private(set) var artifacts: [PlanArtifactSummary] = []
    @Published private(set) var links: [PlanSnapshotLink] = []
    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var isBusy = false {
        didSet {
            if !isBusy {
                let waiters = idleWaiters
                idleWaiters = []
                for waiter in waiters { waiter.resume() }
            }
        }
    }
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    @Published private(set) var error: String?
    var investigationReferences: @MainActor (UUID) async throws -> Set<UUID> = { _ in [] }

    init(store: PlanArtifactStore = PlanArtifactStore()) { self.store = store }

    func waitForPendingWork() async {
        if isBusy { await withCheckedContinuation { idleWaiters.append($0) } }
    }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do { try await reload(); error = nil }
        catch { report(error) }
    }

    @discardableResult
    func save(_ plan: ExplainPlanModel, title: String, baselineName: String?, sourceWasStale: Bool = false) async -> PlanArtifact? {
        guard !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            let artifact = try PlanArtifact.capture(plan, title: title, baselineName: baselineName, sourceWasStale: sourceWasStale)
            let saved = try await store.save(artifact)
            acknowledge(saved)
            await refreshAfterPublication("The execution plan was saved, but the local library could not be refreshed.")
            return saved
        } catch { report(error); return nil }
    }

    @discardableResult
    func importArtifact(from url: URL) async -> PlanArtifact? {
        guard !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            let artifact = try await store.importArtifact(from: url)
            acknowledge(artifact)
            await refreshAfterPublication("The execution plan was imported, but the local library could not be refreshed.")
            return artifact
        } catch { report(error); return nil }
    }

    func exportArtifact(_ id: UUID, to url: URL, expectedVersion: SQLFileVersion?) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let artifact = try await store.load(id)
            let text = try artifact.encoded()
            _ = try await Task.detached { try SQLFileBinding.write(text, to: url, expectedVersion: expectedVersion, maximumBytes: PlanArtifact.maximumBytes) }.value
            error = nil
            return true
        } catch { report(error); return false }
    }

    func updateMetadata(id: UUID, title: String, baselineName: String?) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let updated = try await store.updateMetadata(id: id, title: title, baselineName: baselineName)
            acknowledge(updated)
            await refreshAfterPublication("The plan name was saved, but the local library could not be refreshed.")
            return true
        } catch { report(error); return false }
    }

    func delete(_ id: UUID) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let references = try await investigationReferences(id)
            guard references.isEmpty else { throw PlanArtifactError.referenced }
            try await store.delete(id: id, investigationIDs: references)
            artifacts.removeAll { $0.id == id }
            links.removeAll { $0.planID == id }
            revision &+= 1
            await refreshAfterPublication("The execution plan was deleted, but the local library could not be refreshed.")
            return true
        } catch {
            if error is InvestigationStoreError { self.error = "Investigation references could not be checked. Resolve the local investigation library error before deleting execution plans." }
            else { report(error) }
            return false
        }
    }

    func attach(planID: UUID, snapshotID: UUID, snapshotStore: ResultSnapshotStore) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await snapshotStore.manifest(id: snapshotID)
            try await store.attach(planID: planID, snapshotID: snapshotID)
            // A snapshot can disappear while the plan store is awaited.
            do { _ = try await snapshotStore.manifest(id: snapshotID) }
            catch { try await store.detach(planID: planID, snapshotID: snapshotID); throw error }
            let link = PlanSnapshotLink(snapshotID: snapshotID, planID: planID)
            if !links.contains(link) { links.append(link) }
            revision &+= 1
            await refreshAfterPublication("The snapshot link was saved, but the local library could not be refreshed.")
            return true
        } catch { report(error); return false }
    }

    func detach(planID: UUID, snapshotID: UUID) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            try await store.detach(planID: planID, snapshotID: snapshotID)
            links.removeAll { $0.planID == planID && $0.snapshotID == snapshotID }
            revision &+= 1
            await refreshAfterPublication("The snapshot link was removed, but the local library could not be refreshed.")
            return true
        } catch { report(error); return false }
    }

    func snapshotDeleted(_ id: UUID) async {
        do { try await store.removeSnapshotLinks(id); links = try await store.links(); revision &+= 1 }
        catch { self.error = "The snapshot was deleted, but its execution-plan links could not be updated. Remove any retained snapshot link in the plan library before deleting the plan." }
    }

    func report(_ error: Error) {
        self.error = error is PlanArtifactError || error is SQLFileBindingError ? error.localizedDescription : PlanArtifactError.unavailable.localizedDescription
    }

    private func acknowledge(_ artifact: PlanArtifact) {
        artifacts.removeAll { $0.id == artifact.id }
        artifacts.append(PlanArtifactSummary(artifact))
        artifacts.sort { $0.capturedAt > $1.capturedAt }
        revision &+= 1
    }

    private func refreshAfterPublication(_ warning: String) async {
        do { try await reload(); error = nil }
        catch { self.error = warning }
    }

    private func reload() async throws {
        let loaded = try await store.list()
        let attachments = try await store.links()
        artifacts = loaded
        links = attachments
        revision &+= 1
    }
}
