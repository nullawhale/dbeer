import Foundation
import Testing
@testable import DBeer

struct StructureDraftDocumentTests {
    private func document() -> StructureDraftDocument {
        .init(engine: .postgresql, target: .init(schema: "public", table: "samples", create: true),
              draft: .init(columns: [.init(name: "amount", type: .init(kind: "numeric", precision: 38, scale: 8), nullable: false,
                                          default: .init(kind: "numeric", value: "123456789012345678901234567890.12345678"))]))
    }

    @Test func portableIntentRoundTripsWithoutExecutionOrConnectionState() throws {
        let original = document()
        let text = try StructureDraftStore.text(original)
        let decoded = try JSONDecoder().decode(StructureDraftDocument.self, from: Data(text.utf8))
        #expect(decoded == original)
        let fields = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(Set(fields.keys) == Set(["formatVersion", "engine", "target", "draft"]))
        #expect(!text.contains("baselineId") && !text.contains("sessionId") && !text.contains("authorization"))
        #expect(decoded.draft.columns[0].default.value == "123456789012345678901234567890.12345678")
    }

    @Test func incompleteIntentCanBeSavedButFutureAndUnknownFieldsAreRejected() throws {
        let incomplete = StructureDraftDocument(engine: .postgresql, target: .init(schema: "public", table: "", create: true),
                                                draft: .init(columns: [.init(name: "", type: .init(kind: "varchar", length: 0), nullable: true, default: .init(kind: "none"))]))
        #expect(incomplete.valid && !incomplete.draft.valid)
        #expect(try JSONDecoder().decode(StructureDraftDocument.self, from: Data(StructureDraftStore.text(incomplete).utf8)) == incomplete)
        let text = try StructureDraftStore.text(document())
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(StructureDraftDocument.self, from: Data(text.replacingOccurrences(of: "\"formatVersion\" : 1", with: "\"formatVersion\" : 2").utf8))
        }
        let extra = text.replacingOccurrences(of: "\"formatVersion\" : 1", with: "\"credentials\" : \"forbidden\", \"formatVersion\" : 1")
        #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(StructureDraftDocument.self, from: Data(extra.utf8)) }
    }

    @Test func destructiveChoiceIsFreshAfterTransferAndUnicodeBytesStayExact() throws {
        let key = StructureKeyEdit(action: "drop", kind: "unique", name: "old_key")
        let value = StructureDraftDocument(engine: .postgresql, target: .init(schema: "é", table: "samples", create: false),
                                          draft: .init(columns: [], keys: [key], allowDestructive: true))
        #expect(value.draft.allowDestructive == nil && !value.draft.valid)
        let text = try StructureDraftStore.text(value)
        #expect(!text.contains("allowDestructive"))
        let decoded = try JSONDecoder().decode(StructureDraftDocument.self, from: Data(text.utf8))
        #expect(decoded.target.schema.utf8.elementsEqual("é".utf8))
        #expect(!decoded.target.schema.utf8.elementsEqual("é".utf8))
    }

    @Test func publicationRejectsExternalChangesAndBoundedReadRejectsLargeFiles() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("build/structure-drafts/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("draft.dbeerstructure")
        let version = try StructureDraftStore.write(document(), to: url, expectedVersion: nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        try Data("external version".utf8).write(to: url)
        #expect(throws: (any Error).self) { _ = try StructureDraftStore.write(document(), to: url, expectedVersion: version) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "external version")
        let huge = folder.appendingPathComponent("large.dbeerstructure")
        try Data(repeating: 32, count: StructureDraftDocument.maximumBytes + 1).write(to: huge)
        #expect(throws: (any Error).self) { _ = try StructureDraftStore.read(huge) }
        #expect(throws: (any Error).self) { _ = try SQLFileBinding.read(huge, maximumBytes: 64) }
    }

    @Test func sqlExportPreservesOrderAndCommentsEveryWarningAndTargetLine() throws {
        let plan = StructurePlan(id: "plan", baselineId: "baseline", digest: String(repeating: "a", count: 64),
                                 target: .init(schema: "public\nSELECT unsafe;", table: "samples", create: false),
                                 sql: ["ALTER TABLE \"samples\" ADD COLUMN \"one\" integer;", "CREATE INDEX \"two\" ON \"samples\" (\"one\");"],
                                 risks: ["first line\nSELECT danger;"])
        let sql = try StructureDraftStore.sql(plan)
        #expect(sql.contains("-- SELECT unsafe;") && sql.contains("-- Warning: SELECT danger;"))
        #expect(sql.range(of: plan.sql[0])!.lowerBound < sql.range(of: plan.sql[1])!.lowerBound)
        #expect(sql.contains("-- Step 1") && sql.contains("-- Step 2"))
    }
}

@MainActor
private final class DraftPersistenceBackend {
    var calls: [String] = []
    var loseApply = false
    let target = StructureTarget(schema: "public", table: "samples", create: true)
    var baseline: StructureBaseline {
        .init(id: "fresh-baseline", target: target, engine: "postgresql", fingerprint: String(repeating: "a", count: 64), columns: [], limitations: [])
    }
    var plan: StructurePlan {
        .init(id: "fresh-plan", baselineId: "fresh-baseline", digest: String(repeating: "b", count: 64), target: target,
              sql: ["CREATE TABLE \"public\".\"samples\" (\"value\" integer);"], risks: ["fixture warning"])
    }
    func model() -> TableStructureEditorModel {
        .init(profile: .init(name: "Synthetic", settings: .init(host: "synthetic.invalid", port: 5432, database: "synthetic", user: "synthetic", password: "", sslMode: "disable")),
              schema: "public", table: "samples", create: true,
              connect: { self.calls.append("connect"); return "session" }, send: request,
              authorize: { _, _, _ in "grant" }, bindingIsCurrent: { true }, changed: { _ in })
    }
    func request(_ command: BackendCommand) async throws -> BackendMessage {
        calls.append(command.type)
        var result = BackendMessage(type: command.type + ".result", requestId: command.requestId, sessionId: command.sessionId, queryId: command.queryId)
        switch command.type {
        case "structure.load": result.structure = .init(baseline: baseline)
        case "structure.preview": result.structure = .init(plan: plan)
        case "structure.apply":
            if loseApply { throw BackendTransportError(.unexpectedEOF, outcomeUnknown: true) }
        default: break
        }
        return result
    }
}

@MainActor
struct TableStructureDraftPersistenceTests {
    private func file() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("build/structure-drafts/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("draft.dbeerstructure")
    }
    private func intent(_ target: StructureTarget, name: String = "restored") -> StructureDraftDocument {
        .init(engine: .postgresql, target: target,
              draft: .init(columns: [.init(name: name, type: .init(kind: "integer"), nullable: true, default: .init(kind: "none"))]))
    }

    @Test func openRequiresFreshExplicitLoadAndRetainsIntentAcrossIt() async throws {
        let backend = DraftPersistenceBackend()
        let model = backend.model()
        let url = try file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let document = intent(backend.target)
        _ = try StructureDraftStore.write(document, to: url, expectedVersion: nil)
        await model.openDraft(from: url, expectedDocument: model.portableDraft, replaceReviewed: false)
        #expect(backend.calls.isEmpty && model.baseline == nil && model.preview == nil && !model.canApply)
        #expect(model.draft == document.draft && model.fileNotice != nil)
        await model.load()
        #expect(model.baseline?.id == "fresh-baseline" && model.draft == document.draft && model.preview == nil)
        #expect(!backend.calls.contains("structure.preview") && !backend.calls.contains("structure.apply"))
        await model.preparePreview()
        #expect(model.canApply)
    }

    @Test func incompatibleOrUnreviewedReplacementKeepsCurrentIntent() async throws {
        let backend = DraftPersistenceBackend()
        let model = backend.model()
        await model.load()
        model.draft.columns[0].name = "local"
        await model.preparePreview()
        let preview = model.preview
        let original = model.portableDraft
        let url = try file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try StructureDraftStore.write(intent(.init(schema: "public", table: "other", create: true)), to: url, expectedVersion: nil)
        await model.openDraft(from: url, expectedDocument: original, replaceReviewed: false)
        #expect(model.portableDraft == original && model.preview == preview && model.error != nil)
        await model.openDraft(from: url, expectedDocument: original, replaceReviewed: true)
        #expect(model.portableDraft == original && model.preview == preview && model.error != nil)
    }

    @Test func failedSavePreservesDirtyIntentAndOriginalFileBinding() async throws {
        let backend = DraftPersistenceBackend()
        let model = backend.model()
        model.draft.columns[0].name = "one"
        let url = try file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await model.saveDraft(to: url, expectedDocument: model.portableDraft, expectedVersion: nil)
        let savedVersion = try #require(model.draftFileVersion)
        model.draft.columns[0].name = "two"
        try Data("external".utf8).write(to: url)
        await model.saveDraft(to: url, expectedDocument: model.portableDraft, expectedVersion: savedVersion)
        #expect(model.error != nil && model.draft.columns[0].name == "two" && model.draftFileVersion == savedVersion)
        #expect(model.draftFileLabel?.contains("Edited") == true)
        #expect(try String(contentsOf: url, encoding: .utf8) == "external")
    }

    @Test func unknownOutcomeRemainsSeparateFromSavedIntentAndCannotBeReplaced() async throws {
        let backend = DraftPersistenceBackend()
        let model = backend.model()
        await model.load()
        model.draft.columns[0].name = "value"
        await model.preparePreview()
        backend.loseApply = true
        await model.apply()
        let report = try #require(model.outcomeReview)
        let url = try file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        await model.saveDraft(to: url, expectedDocument: model.portableDraft, expectedVersion: nil)
        let loaded = try StructureDraftStore.read(url)
        #expect(loaded.document.draft == report.draft)
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("outcomeUnknown"))
        await model.openDraft(from: url, expectedDocument: model.portableDraft, replaceReviewed: true)
        #expect(model.outcome?.state == "outcomeUnknown" && model.outcomeReview?.plan == report.plan && !model.canApply)
    }
}
