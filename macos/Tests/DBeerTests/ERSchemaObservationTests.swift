import Foundation
import Testing
@testable import DBeer

struct SchemaObservationProtocolTests {
    @Test func sharedContractsMatchTheHelperAndRejectAmbiguousInputs() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/schema-observation-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for item in try #require(fixture["requests"] as? [[String: Any]]) {
            let expected = try #require(item["valid"] as? Bool)
            let bytes = try JSONSerialization.data(withJSONObject: try #require(item["command"]))
            let command = try? JSONDecoder().decode(BackendCommand.self, from: bytes)
            #expect((command?.validSchemaObservationCommand == true) == expected)
        }
        for item in try #require(fixture["observations"] as? [[String: Any]]) {
            let expected = try #require(item["valid"] as? Bool)
            let bytes = try JSONSerialization.data(withJSONObject: try #require(item["observation"]))
            let result = try? JSONDecoder().decode(SchemaObservation.self, from: bytes)
            #expect((result?.valid == true) == expected)
        }
    }
}

@MainActor
struct ERSchemaObservationTests {
    private let table = SchemaObservationTable(schema: "public", name: "orders")
    private func result(_ command: BackendCommand, revision: String, complete: Bool = true) -> BackendMessage {
        let request = command.schemaObservation!
        return .init(type: "monitor.schema.result", requestId: command.requestId, sessionId: command.sessionId, queryId: command.queryId,
            transactionStatus: .idle, connected: true, schemaObservation: .init(engine: .mysql, action: request.action, tables: request.tables,
                mode: "fingerprint", revision: revision, observedAt: "2026-11-05T12:34:56Z", installed: false, canInstall: false,
                canRemove: false, complete: complete, notices: complete ? [] : ["Metadata limited"]))
    }

    @Test func observationIsExplicitAndChangesOnlyInvalidateMetadata() async throws {
        var connections = 0
        var commands: [BackendCommand] = []
        var revision = String(repeating: "a", count: 64)
        var invalidations: [String] = []
        let observer = ERSchemaObservation(engine: .mysql, tables: [table], connect: { connections += 1; return "observer" }, send: { command in
            commands.append(command)
            if command.type == "monitor.schema" { return result(command, revision: revision) }
            return .init(type: "disconnect.ack", requestId: command.requestId, sessionId: command.sessionId)
        }, isCurrent: { true }, cancelPreparation: {}, metadataChanged: { invalidations.append($0) })
        #expect(connections == 0 && commands.isEmpty && !observer.enabled)
        await observer.start()
        #expect(connections == 1 && observer.enabled && invalidations.count == 1)
        await observer.refresh()
        #expect(invalidations.count == 1)
        revision = String(repeating: "b", count: 64)
        await observer.refresh()
        #expect(invalidations.count == 2)
        #expect(commands.allSatisfy { $0.type == "monitor.schema" && $0.sql == nil })
        await observer.stop()
        #expect(!observer.enabled && commands.last?.type == "disconnect")
    }

    @Test func invalidatedBindingClosesItsSessionAndNeverReconnectsAutomatically() async {
        var current = true, connections = 0
        var commands: [BackendCommand] = []
        let observer = ERSchemaObservation(engine: .mysql, tables: [table], connect: { connections += 1; return "observer" }, send: { command in
            commands.append(command)
            if command.type == "monitor.schema" { current = false; return result(command, revision: String(repeating: "a", count: 64)) }
            return .init(type: "disconnect.ack", requestId: command.requestId, sessionId: command.sessionId)
        }, isCurrent: { current }, cancelPreparation: {}, metadataChanged: { _ in })
        await observer.start()
        #expect(!observer.enabled && commands.last?.type == "disconnect" && connections == 1)
        await observer.refresh()
        #expect(connections == 1)
    }

    @Test func limitedObservationStopsAndReportsItsMissingEvidence() async {
        var commands: [BackendCommand] = []
        let observer = ERSchemaObservation(engine: .mysql, tables: [table], connect: { "observer" }, send: { command in
            commands.append(command)
            if command.type == "monitor.schema" { return result(command, revision: "", complete: false) }
            return .init(type: "disconnect.ack", requestId: command.requestId, sessionId: command.sessionId)
        }, isCurrent: { true }, cancelPreparation: {}, metadataChanged: { _ in })
        await observer.start()
        #expect(!observer.enabled && observer.notice?.contains("Metadata limited") == true && commands.last?.type == "disconnect")
    }
}

@MainActor
struct ERDiagramAsyncLayoutTests {
    @Test func detachedLayoutRetainsManualPositionsAndCancellationCannotPublish() async {
        let profile = UUID()
        let tables = (0..<100).map { ERTableID(profileID: profile, schema: "public", name: "table_\($0)") }
        let manual = ERPlacement(table: tables[0], point: .init(x: 71, y: 83), manual: true)
        let model = ERDiagramModel(stored: .init(profileID: profile, engine: .postgresql, database: "fixture", tables: tables, placements: [manual]))
        await model.autoLayout()
        #expect(model.stored.placements.count == tables.count && model.stored.placements.first { $0.table == tables[0] } == manual)
        let before = model.stored.placements
        let task = Task { await model.autoLayout(reset: true) }
        task.cancel()
        await task.value
        #expect(model.stored.placements == before && !model.isLayingOut)
    }
    @Test func cancellationInsideConnectedDepthFirstTraversalReturnsNoPartialLayout() {
        let profile = UUID()
        let tables = (0..<20).map { ERTableID(profileID: profile, schema: "public", name: String(format: "table_%02d", $0)) }
        let relationships = (0..<(tables.count - 1)).map { index in
            ERRelationship(source: tables[index], key: TableForeignKey(name: "parent", target: tables[index + 1].reference,
                columns: [.init(source: "parent_id", target: "id", position: 1)]))
        }
        // The third checkpoint cancels the first child before its DFS state
        // exists. Later checkpoints cover deeper recursion and unwinding.
        for cancellationPoint in 1...25 {
            var checks = 0
            let placements = ERDiagramLayout.positions(tables: tables, relationships: relationships, metadata: [:], preserving: [], collapsed: [], isCancelled: {
                checks += 1
                return checks >= cancellationPoint
            })
            #expect(checks >= cancellationPoint && placements.isEmpty)
        }
    }
    @Test func restoredStateContainsNeitherObservationNorLiveLayoutWork() throws {
        let profile = UUID()
        let stored = StoredERDiagram(profileID: profile, engine: .mysql, database: "fixture", tables: [.init(profileID: profile, schema: "fixture", name: "t")])
        let data = try JSONEncoder().encode(stored)
        let restored = ERDiagramModel(stored: try JSONDecoder().decode(StoredERDiagram.self, from: data))
        #expect(restored.schemaObservation == nil && !restored.isLayingOut && restored.context == nil)
        #expect(String(decoding: data, as: UTF8.self).contains("schemaObservation") == false)
    }
}
