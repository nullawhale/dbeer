import Foundation
import Testing
@testable import DBeer

/// Private local files, immutable values and injected model callbacks only.
/// No windows, Keychain, helpers, status reads or database connections are used.
@MainActor
struct SavedEvidenceTests {
    private func folder() throws -> URL {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let value = repository.appendingPathComponent("build/saved-evidence-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }
    private func fixtures() throws -> [SavedEvidenceArtifact] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/saved-evidence-v1.json"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["artifacts"] as? [[String: Any]]).map {
            try SavedEvidenceArtifact.decode(String(decoding: JSONSerialization.data(withJSONObject: $0), as: UTF8.self))
        }
    }
    private func plan() throws -> PlanArtifact {
        let result = try #require(ExplainFixture.load().results.first { $0.status == "tree" && $0.mode == .plan })
        var model = ExplainPlanModel(request: .init(sql: "SELECT synthetic_plan", mode: .plan), sourceText: "SELECT synthetic_plan",
            sourceRange: NSRange(location: 0, length: 21), profileID: UUID())
        model.result = result
        return try PlanArtifact.capture(model, title: "Existing plan")
    }

    @Test func captureKeepsUnknownAcknowledgementAndStripsAllRuntimeHandles() async throws {
        let target = StructureTarget(schema: "public", table: "samples", create: false)
        let baseline = StructureBaseline(id: "private-baseline-handle", target: target, engine: "postgresql",
            fingerprint: String(repeating: "a", count: 64), columns: [], limitations: [])
        let reviewed = StructurePlan(id: "historical-plan", baselineId: baseline.id, digest: String(repeating: "b", count: 64),
            target: target, sql: ["ALTER TABLE public.samples ADD COLUMN note text"], risks: ["Synthetic warning"])
        var calls: [String] = []
        let profile = SavedConnection(name: "Retained profile", settings: .init(host: "private-host", port: 5432,
            database: "private-database", user: "private-user", password: "private-password", sslMode: "disable"))
        let model = TableStructureEditorModel(profile: profile, schema: "public", table: "samples", create: false,
            connect: { calls.append("connect"); return "private-runtime-session" }, send: { request in
                calls.append(request.type)
                var response = BackendMessage(type: request.type + ".result", requestId: request.requestId,
                    sessionId: request.sessionId, queryId: request.queryId, transactionStatus: .idle, connected: true)
                switch request.type {
                case "structure.load": response.structure = .init(baseline: baseline)
                case "structure.preview": response.structure = .init(plan: reviewed)
                case "structure.apply":
                    response.structure = .init(outcome: .init(executionId: request.structure?.apply?.executionId ?? "missing",
                        planId: reviewed.id, state: "outcomeUnknown", steps: [.init(state: "unknown")], observed: baseline))
                case "disconnect": return .init(type: "disconnect.ack", requestId: request.requestId, sessionId: request.sessionId)
                default: response.structure = .init()
                }
                return response
            }, authorize: { _, _, _ in "private-live-authorization" }, bindingIsCurrent: { true }, changed: { _ in })
        await model.load()
        model.draft = .init(columns: [.init(name: "note", type: .init(kind: "text"), nullable: true, default: .init(kind: "none"))])
        await model.preparePreview()
        await model.apply()
        let before = calls
        let value = try SavedEvidenceArtifact.capture(model, title: "Unknown outcome")
        let text = try value.encoded()
        #expect(calls == before && value.structure?.state == "outcomeUnknown" && !value.complete)
        #expect(value.structure?.sql == reviewed.sql && value.structure?.steps.first?.state == "unknown")
        for excluded in ["private-baseline-handle", "private-runtime-session", "private-live-authorization", "private-host", "private-user", "private-password", "baselineId", "authorization"] {
            #expect(!text.contains(excluded))
        }
        #expect(try SavedEvidenceArtifact.decode(text) == value)
        #expect(await model.close())
    }

    @Test func sharedFixturesRoundTripAndRejectFutureOrAmbiguousEvidence() throws {
        for artifact in try fixtures() {
            let text = try artifact.encoded()
            #expect(try SavedEvidenceArtifact.decode(text) == artifact)
            #expect(throws: (any Error).self) { try SavedEvidenceArtifact.decode(text.replacingOccurrences(of: "\"version\" : \(SavedEvidenceArtifact.currentVersion)", with: "\"version\" : 99")) }
            var object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            object["authorization"] = "must not survive"
            #expect(throws: (any Error).self) { try SavedEvidenceArtifact.decode(String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self)) }
            #expect(throws: (any Error).self) { try SavedEvidenceArtifact.decode(text.replacingOccurrences(of: "Synthetic saved evidence", with: "\\ud800")) }
        }
    }

    @Test func existingPlansAndNewEvidenceShareGuardedStorageAndVersionedLinks() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PlanArtifactStore(rootURL: root)
        let old = try plan(); _ = try await store.save(old)
        let value = try #require(fixtures().first); _ = try await store.saveEvidence(value)
        let snapshot = UUID()
        try await store.attach(planID: old.id, snapshotID: snapshot)
        let sidecar = root.appendingPathComponent("attachments.json")
        #expect((try JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])?["version"] as? Int == 1)
        try await store.attachEvidence(value.reference, snapshotID: snapshot)
        let restarted = PlanArtifactStore(rootURL: root)
        #expect(try await restarted.load(old.id) == old)
        #expect(try await restarted.loadEvidence(value.id) == value)
        #expect(try await restarted.links(snapshotID: snapshot).count == 1)
        #expect(try await restarted.evidenceLinks(snapshotID: snapshot).map(\.evidence) == [value.reference])
        await #expect(throws: PlanArtifactError.referenced) { try await restarted.deleteEvidence(id: value.id, investigationIDs: []) }
        try await restarted.removeSnapshotLinks(snapshot)
        #expect(try await restarted.links().isEmpty)
        #expect(try await restarted.evidenceLinks().isEmpty)
        try await restarted.deleteEvidence(id: value.id, investigationIDs: [])
        #expect(try await restarted.listEvidence().isEmpty)
        #expect(try await restarted.list().count == 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
    }

    @Test func offlineDiagnosticOwnerNeverConnectsRefreshesOrStartsTimers() async throws {
        let artifact = try #require(fixtures().first { $0.kind == .diagnostic })
        let model = try SessionMonitorModel.offline(artifact)
        #expect(model.isOffline && model.snapshot == artifact.diagnostic)
        model.autoRefresh = true
        await model.refresh()
        #expect(model.snapshot == artifact.diagnostic && !model.isBusy)
        #expect(model.snapshot?.sessions.first?.queryAgeMs == "9007199254740993")
        let bytes = try artifact.encoded()
        #expect(bytes.contains(".123456789Z") && !artifact.complete)
        await model.close()
    }

    @Test func immutablePublicationCorruptionAndReferenceAwareDeletionPreserveOtherFiles() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = PlanArtifactStore(rootURL: root)
        let values = try fixtures(); let value = values[0]
        _ = try await store.saveEvidence(value)
        let path = root.appendingPathComponent(value.id.uuidString.lowercased() + ".dbeerevidence")
        let bytes = try Data(contentsOf: path)
        await #expect(throws: (any Error).self) { try await store.saveEvidence(value) }
        #expect(try Data(contentsOf: path) == bytes)
        let source = root.appendingPathComponent("import.dbeerevidence")
        try bytes.write(to: source)
        let imported = try await store.importEvidence(from: source)
        #expect(imported.id != value.id && imported.structure == value.structure)
        await #expect(throws: PlanArtifactError.referenced) { try await store.deleteEvidence(id: value.id, investigationIDs: [UUID()]) }
        try Data([0xff, 0xfe]).write(to: path)
        #expect(try await store.listEvidence().first { $0.id == value.id }?.isAvailable == false)
        try await store.deleteEvidence(id: value.id, investigationIDs: [])
        #expect(try await store.loadEvidence(imported.id).structure == value.structure)
        #expect((try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(imported.id.uuidString.lowercased() + ".dbeerevidence").path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func markdownReferencesAreTypedLocalAndProtectUnloadedInvestigations() async throws {
        let value = try #require(fixtures().first)
        let markdown = SavedEvidenceLink.markdown(value.reference, title: "Evidence [one]")
        #expect(SavedEvidenceLink.references(in: markdown) == [value.reference])
        #expect(SavedEvidenceLink.references(in: "`" + markdown + "`").isEmpty)
        #expect(SavedEvidenceLink.reference(from: URL(string: SavedEvidenceLink.url(value.reference).absoluteString + "?execute=1")!) == nil)
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let investigations = FileInvestigationStore(fileURL: root.appendingPathComponent("investigations.json"))
        let document = StoredInvestigation(title: "Retained reference", blocks: [.init(kind: .markdown, text: markdown)])
        try await investigations.save(.init(documents: [document]))
        let library = InvestigationLibraryModel(store: investigations, snapshotStore: ResultSnapshotStore(rootURL: root.appendingPathComponent("snapshots")), autosaveDelay: nil)
        await library.restore()
        #expect(try await library.referencingInvestigations(evidenceID: value.id) == [document.id])
        #expect(library.document(id: document.id) == nil)
    }
    @Test func aggregateUnknownReportIsSavedWithoutInventedStepAcknowledgements() throws {
        var value = try #require(fixtures().first { $0.kind == .structure })
        value.structure?.sql = ["synthetic step one", "synthetic step two", "synthetic step three"]
        #expect(value.valid && value.structure?.steps.count == 1 && !value.complete)
        let restored = try SavedEvidenceArtifact.decode(value.encoded())
        #expect(restored.structure?.steps.count == 1 && restored.structure?.sql.count == 3)
    }

}
