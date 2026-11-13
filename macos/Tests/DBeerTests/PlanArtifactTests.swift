import Darwin
import Foundation
import Testing
@testable import DBeer

private func planTestDirectory() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let folder = root.appendingPathComponent("build/plan-artifacts/" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

private func planTestModel() throws -> ExplainPlanModel {
    let result = try #require(ExplainFixture.load().results.first { $0.status == "tree" && $0.mode == .plan })
    var plan = ExplainPlanModel(request: .init(sql: "SELECT 'captured 🍺'", mode: .plan),
        sourceText: "SELECT 'unrelated document text'", sourceRange: NSRange(location: 0, length: 10), profileID: UUID())
    plan.result = result
    plan.sessionID = "private-runtime-session"
    return plan
}

struct PlanArtifactTests {
    @Test func explicitCaptureRetainsOriginalRequestAndExactMetrics() throws {
        let plan = try planTestModel()
        let artifact = try PlanArtifact.capture(plan, title: "Before index", baselineName: "original", sourceWasStale: true)
        let encoded = try artifact.encoded()
        let restored = try PlanArtifact.decode(encoded)
        #expect(restored == artifact)
        #expect(restored.request.sql == plan.request.sql && restored.result == plan.result)
        #expect(abs(restored.capturedAt.timeIntervalSince(plan.capturedAt)) < 0.001)
        #expect(restored.sourceWasStale == true)
        #expect(!encoded.contains("private-runtime-session") && !encoded.contains("unrelated document text"))
        #expect(!encoded.contains("authorization") && !encoded.contains("sessionID") && !encoded.contains("profileBinding"))
        #expect(restored.result.nodes.flatMap { $0.metrics.values }.compactMap(\.value).sorted() == artifact.result.nodes.flatMap { $0.metrics.values }.compactMap(\.value).sorted())
    }

    @Test func invalidTopologyFutureVersionAndOversizedSourceAreRejected() throws {
        var artifact = try PlanArtifact.capture(planTestModel(), title: "Valid")
        let text = try artifact.encoded()
        #expect(throws: (any Error).self) {
            _ = try PlanArtifact.decode(text.replacingOccurrences(of: "\"version\" : \(PlanArtifact.currentVersion)", with: "\"version\" : 99"))
        }
        artifact.result.nodes[0].children = [artifact.result.nodes[0].id]
        #expect(!artifact.valid)
        #expect(throws: PlanArtifactError.invalid) { _ = try artifact.encoded() }
        artifact = try PlanArtifact.capture(planTestModel(), title: "Valid")
        artifact.request.sql = String(repeating: "x", count: 1_048_577)
        #expect(!artifact.valid)
    }

    @Test func storeRestartMetadataAndImportedIdentityPreserveEvidence() async throws {
        let root = try planTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlanArtifactStore(rootURL: root.appendingPathComponent("plans"))
        let original = try PlanArtifact.capture(planTestModel(), title: "Before")
        _ = try await store.save(original)
        let changed = try await store.updateMetadata(id: original.id, title: "Baseline", baselineName: "before change")
        #expect(changed.result == original.result && changed.request == original.request && changed.id == original.id)
        let restarted = PlanArtifactStore(rootURL: root.appendingPathComponent("plans"))
        #expect(try await restarted.load(original.id) == changed)
        #expect(try await restarted.list().map(\.baselineName) == ["before change"])
        let export = root.appendingPathComponent("portable.dbeerplan")
        _ = try SQLFileBinding.write(changed.encoded(), to: export, expectedVersion: nil)
        let imported = try await restarted.importArtifact(from: export)
        #expect(imported.id != changed.id && imported.result == changed.result && imported.request == changed.request)
        #expect(try await restarted.list().count == 2)
        let permissions = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("plans").path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
        let file = root.appendingPathComponent("plans/" + original.id.uuidString.lowercased() + ".dbeerplan")
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func unreadableArtifactIsListedAndExplicitlyRemovableWithoutLosingOthers() async throws {
        let root = try planTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlanArtifactStore(rootURL: root)
        let first = try PlanArtifact.capture(planTestModel(), title: "Keep")
        let second = try PlanArtifact.capture(planTestModel(), title: "Damaged")
        _ = try await store.save(first)
        _ = try await store.save(second)
        let damaged = root.appendingPathComponent(second.id.uuidString.lowercased() + ".dbeerplan")
        try Data([0xff, 0xfe]).write(to: damaged)
        let listed = try await store.list()
        #expect(listed.first { $0.id == second.id }?.isAvailable == false)
        try await store.delete(id: second.id, investigationIDs: [])
        #expect(try await store.list().map(\.id) == [first.id])
        #expect(try await store.load(first.id) == first)
    }

    @Test func snapshotLinksProtectDeletionUntilRemovedAndPersistOnRestart() async throws {
        let root = try planTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlanArtifactStore(rootURL: root)
        let artifact = try PlanArtifact.capture(planTestModel(), title: "Attached")
        _ = try await store.save(artifact)
        let snapshot = UUID()
        try await store.attach(planID: artifact.id, snapshotID: snapshot)
        try await store.attach(planID: artifact.id, snapshotID: snapshot)
        #expect(try await PlanArtifactStore(rootURL: root).links(snapshotID: snapshot).count == 1)
        await #expect(throws: PlanArtifactError.referenced) { try await store.delete(id: artifact.id, investigationIDs: []) }
        try await store.removeSnapshotLinks(snapshot)
        try await store.delete(id: artifact.id, investigationIDs: [])
        #expect(try await store.list().isEmpty)
    }

    @Test func parentIdentityGuardRefusesDifferentDirectoryAndReferenceParserIsLocalOnly() throws {
        let root = try planTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try Data("source".utf8).write(to: source)
        #expect(throws: SQLFileBindingError.self) {
            _ = try SQLFileBinding.read(source, expectedParent: SQLFileIdentity(device: 0, inode: 0))
        }
        #expect(throws: SQLFileBindingError.self) {
            _ = try SQLFileBinding.write("replacement", to: source, expectedVersion: nil, expectedParent: SQLFileIdentity(device: 0, inode: 0))
        }
        #expect(try String(contentsOf: source, encoding: .utf8) == "source")
        let reviewed = try SQLFileBinding.read(source).version
        let grown = String(repeating: "large", count: 100)
        try Data(grown.utf8).write(to: source)
        #expect(throws: SQLFileBindingError.self) {
            _ = try SQLFileBinding.write("small", to: source, expectedVersion: reviewed, maximumBytes: 16)
        }
        #expect(try String(contentsOf: source, encoding: .utf8) == grown)

        let id = UUID()
        let markdown = PlanArtifactReference.markdown(id: id, title: "Nested [plan] 🍺\nname")
        #expect(PlanArtifactReference.ids(in: markdown) == [id])
        #expect(PlanArtifactReference.id(from: URL(string: "https://example.invalid/" + id.uuidString)!) == nil)
        #expect(PlanArtifactReference.id(from: URL(string: "dbeer-plan://user@" + id.uuidString.lowercased())!) == nil)
        #expect(PlanArtifactReference.id(from: URL(string: PlanArtifactReference.url(id).absoluteString + "?extra=1")!) == nil)
        #expect(PlanArtifactReference.ids(in: "[web](https://example.invalid/" + id.uuidString + ")").isEmpty)
    }

    @Test func comparisonMarksDuplicateCandidatesAndChangedShapeWithoutRoundingMetrics() throws {
        let original = try PlanArtifact.capture(planTestModel(), title: "Before")
        var changed = original
        changed.id = UUID()
        changed.result.nodes[0].metrics["totalCost"] = .init(value: "9007199254740993.125", unit: "cost", basis: "inclusive")
        let comparison = PlanComparison(before: original, after: changed)
        #expect(!comparison.shapeChanged && comparison.metricsComparable)
        var otherVersion = changed
        otherVersion.result.support.serverVersion = "different recorded server version"
        #expect(!PlanComparison(before: original, after: otherVersion).metricsComparable)
        #expect(comparison.matches.contains { $0.after.first?.metrics["totalCost"]?.value == "9007199254740993.125" })
        var duplicate = changed.result.nodes[0]
        duplicate.id = "duplicate"
        duplicate.children = []
        changed.result.roots.append(duplicate.id)
        changed.result.nodes.append(duplicate)
        #expect(changed.valid)
        let ambiguous = PlanComparison(before: original, after: changed)
        #expect(ambiguous.shapeChanged && ambiguous.matches.contains(where: \.isAmbiguous))
        var unknown = original
        unknown.result.status = "rawOnly"
        unknown.result.nodes = []
        unknown.result.roots = []
        unknown.result.diagnostic = "Unknown format"
        #expect(unknown.valid)
        #expect(!PlanComparison(before: unknown, after: unknown).shapeAvailable)
    }
    @Test func canonicallyEquivalentByteDistinctIdentifiersNeverPairOrHideShapeChanges() throws {
        let firstName = "a\u{0301}\u{0323}"
        let secondName = "a\u{0323}\u{0301}"
        #expect(firstName == secondName && firstName.utf8.count == secondName.utf8.count)
        #expect(!firstName.utf8.elementsEqual(secondName.utf8))
        var before = try PlanArtifact.capture(planTestModel(), title: "Before")
        before.result.nodes[0].details["Relation Name"] = firstName
        var after = before
        after.id = UUID()
        after.result.nodes[0].details["Relation Name"] = secondName
        let changed = PlanComparison(before: before, after: after)
        #expect(changed.shapeChanged)
        let identityNodes = changed.matches.filter { !$0.before.isEmpty || !$0.after.isEmpty }
        #expect(identityNodes.contains { $0.before.first?.id == before.result.nodes[0].id && $0.after.isEmpty })
        #expect(identityNodes.contains { $0.after.first?.id == after.result.nodes[0].id && $0.before.isEmpty })
        var repeated = before
        var distinct = before.result.nodes[0]
        distinct.id = "distinct-unicode-relation"
        distinct.children = []
        distinct.details["Relation Name"] = secondName
        repeated.result.roots.append(distinct.id)
        repeated.result.nodes.append(distinct)
        #expect(repeated.valid)
        let stable = PlanComparison(before: repeated, after: repeated)
        #expect(!stable.shapeChanged && stable.matches.allSatisfy { !$0.isAmbiguous })
    }

    @Test func changedUnicodeLiteralEvidenceIsReportedByNodeAndDetails() throws {
        let firstLiteral = "a\u{0301}\u{0323}"
        let secondLiteral = "a\u{0323}\u{0301}"
        var before = try PlanArtifact.capture(planTestModel(), title: "Before")
        before.result.nodes[0].details["Filter"] = "(label = '\(firstLiteral)')"
        var after = before
        after.id = UUID()
        after.result.nodes[0].details["Filter"] = "(label = '\(secondLiteral)')"
        let comparison = PlanComparison(before: before, after: after)
        #expect(!comparison.shapeChanged)
        let matched = try #require(comparison.matches.first { $0.before.first?.id == before.result.nodes[0].id })
        #expect(matched.status == "Matched operation")
        let changes = PlanComparison.detailChanges(before: before.result.nodes[0].details, after: after.result.nodes[0].details)
        let filter = try #require(changes.first { $0.name == "Filter" })
        #expect(filter.unicodeRepresentationChanged)
        #expect(filter.before?.utf8.elementsEqual(before.result.nodes[0].details["Filter"]!.utf8) == true)
        #expect(filter.after?.utf8.elementsEqual(after.result.nodes[0].details["Filter"]!.utf8) == true)
        var changedOperation = after
        changedOperation.result.nodes[0].operation = "Read " + secondLiteral
        before.result.nodes[0].operation = "Read " + firstLiteral
        #expect(PlanComparison(before: before, after: changedOperation).shapeChanged)
        before.result.support.serverVersion = firstLiteral
        changedOperation.result.support.serverVersion = secondLiteral
        #expect(!PlanComparison(before: before, after: changedOperation).metricsComparable)
        var invalidReference = before
        invalidReference.result.nodes[0].id = firstLiteral
        invalidReference.result.roots[0] = secondLiteral
        #expect(!invalidReference.valid)
    }

}

private actor PlanUnreadableInvestigationStore: InvestigationStore {
    func load() throws -> StoredInvestigations { throw InvestigationStoreError.read }
    func save(_ value: StoredInvestigations) throws { throw InvestigationStoreError.write }
}

@MainActor
struct PlanArtifactReferenceTests {
    @Test func savedAndUnsavedInvestigationReferencesProtectDeletionAndOldFormatReads() async throws {
        let root = try planTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlanArtifactStore(rootURL: root)
        let artifact = try PlanArtifact.capture(planTestModel(), title: "Evidence")
        _ = try await store.save(artifact)
        let library = InvestigationLibraryModel(store: MemoryInvestigationStore(), autosaveDelay: nil)
        await library.restore()
        let document = try #require(library.create())
        let block = try #require(document.addMarkdown(text: PlanArtifactReference.markdown(id: artifact.id, title: artifact.title)))
        let model = PlanArtifactsModel(store: store)
        model.investigationReferences = { try await library.referencingInvestigations(planID: $0) }
        #expect(!(await model.delete(artifact.id)))
        #expect(try await library.referencingInvestigations(planID: artifact.id) == [document.id])
        #expect(await library.saveInvestigation(document.id))
        #expect(document.removeBlockAfterLifecycle(block))
        #expect(try await library.referencingInvestigations(planID: artifact.id) == [document.id])
        #expect(await library.saveInvestigation(document.id))
        #expect(try await library.referencingInvestigations(planID: artifact.id).isEmpty)
        #expect(await model.delete(artifact.id))
        let legacy = StoredInvestigations(documents: [StoredInvestigation(blocks: [.init(kind: .markdown, text: "Legacy note")])])
        let data = try JSONEncoder().encode(legacy)
        #expect(try JSONDecoder().decode(StoredInvestigations.self, from: data) == legacy)
    }

    @Test func unreadableInvestigationLibraryBlocksPlanDeletion() async throws {
        let root = try planTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlanArtifactStore(rootURL: root)
        let artifact = try PlanArtifact.capture(planTestModel(), title: "Keep")
        _ = try await store.save(artifact)
        let library = InvestigationLibraryModel(store: PlanUnreadableInvestigationStore())
        await library.restore()
        let model = PlanArtifactsModel(store: store)
        model.investigationReferences = { try await library.referencingInvestigations(planID: $0) }
        #expect(!(await model.delete(artifact.id)))
        #expect(try await store.load(artifact.id) == artifact)
    }

    @Test func referencesPublishedAfterRestoreAndLaterLibraryCorruptionBlockDeletion() async throws {
        let root = try planTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = try PlanArtifact.capture(planTestModel(), title: "Protected")
        let plans = PlanArtifactStore(rootURL: root.appendingPathComponent("plans"))
        _ = try await plans.save(artifact)
        let libraryFile = root.appendingPathComponent("investigations/library.json")
        let fileStore = FileInvestigationStore(fileURL: libraryFile)
        let library = InvestigationLibraryModel(store: fileStore, autosaveDelay: nil)
        await library.restore()
        let external = StoredInvestigation(blocks: [.init(kind: .markdown, text: PlanArtifactReference.markdown(id: artifact.id, title: artifact.title))])
        try await fileStore.save(StoredInvestigations(documents: [external]))
        #expect(try await library.referencingInvestigations(planID: artifact.id) == [external.id])
        let model = PlanArtifactsModel(store: plans)
        model.investigationReferences = { try await library.referencingInvestigations(planID: $0) }
        #expect(!(await model.delete(artifact.id)))
        try Data("{broken library".utf8).write(to: libraryFile)
        #expect(!(await model.delete(artifact.id)))
        #expect(model.error?.contains("Investigation references") == true)
        #expect(try await plans.load(artifact.id) == artifact)
    }

    @Test func savedPlanAcknowledgementSurvivesLaterAttachmentInventoryFailure() async throws {
        let root = try planTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlanArtifactStore(rootURL: root)
        let model = PlanArtifactsModel(store: store)
        await model.refresh()
        try Data("{damaged attachment metadata".utf8).write(to: root.appendingPathComponent("attachments.json"))
        let saved = try #require(await model.save(planTestModel(), title: "Published evidence", baselineName: nil))
        #expect(try await store.load(saved.id).request == saved.request)
        #expect(model.artifacts.contains { $0.id == saved.id })
        #expect(model.error?.contains("was saved") == true)
        #expect(await model.updateMetadata(id: saved.id, title: "Renamed published evidence", baselineName: "baseline"))
        #expect(try await store.load(saved.id).title == "Renamed published evidence")
        #expect(model.artifacts.first { $0.id == saved.id }?.title == "Renamed published evidence")
        #expect(try await store.list().count == 1)
    }

    @Test func acknowledgedSnapshotDeletionCleansAttachmentsWithoutAnyConnection() async throws {
        let root = try planTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let plans = PlanArtifactsModel(store: PlanArtifactStore(rootURL: root.appendingPathComponent("plans")))
        let snapshots = ResultSnapshotsModel(store: ResultSnapshotStore(rootURL: root.appendingPathComponent("snapshots")))
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(),
            resultSnapshots: snapshots, planArtifacts: plans, investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(), autosaveDelay: nil))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("plans").path))
        await workspace.investigations.restore()
        let artifact = try #require(await plans.save(planTestModel(), title: "Attached", baselineName: nil))
        let snapshot = try #require(await snapshots.save(.init(title: "Result", sql: "SELECT 1", engine: .postgresql,
            columns: [.init(index: 0, name: "value", nativeType: "integer")], rows: [["1"]])))
        #expect(await plans.attach(planID: artifact.id, snapshotID: snapshot.id, snapshotStore: snapshots.store))
        let deletion = try #require(snapshots.requestDeletion(snapshot.id))
        #expect(await snapshots.deleteConfirmed(deletion))
        #expect(try await plans.store.links().isEmpty)
        #expect(await plans.delete(artifact.id))
        #expect(workspace.services.isEmpty && workspace.documents.isEmpty && workspace.library.sessionId == nil)
        await workspace.shutdown()
    }
}
