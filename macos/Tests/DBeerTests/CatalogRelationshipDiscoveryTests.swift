import Foundation
import Testing
@testable import DBeer

struct RelationshipDiscoveryProtocolTests {
    @Test func sharedStrictFixture() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/relationship-discovery-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for value in try #require(fixture["valid"] as? [[String: Any]]) {
            let command = try JSONDecoder().decode(BackendCommand.self, from: JSONSerialization.data(withJSONObject: value))
            if command.type.hasPrefix("catalog.") { #expect(command.catalogMetadata?.valid(for: command.type) == true) }
            else { #expect(command.catalog?.kind == "referencingTables") }
        }
        for raw in try #require(fixture["invalid"] as? [String]) {
            let command = try? JSONDecoder().decode(BackendCommand.self, from: Data(raw.utf8))
            #expect(command == nil || (command?.type != "catalog" && command?.catalogMetadata?.valid(for: command?.type ?? "") != true))
        }
        for value in try #require(fixture["responses"] as? [[String: Any]]) {
            let response = try JSONDecoder().decode(BackendMessage.self, from: JSONSerialization.data(withJSONObject: value))
            try response.validate()
        }
        for raw in try #require(fixture["invalidResponses"] as? [String]) {
            let response = try? JSONDecoder().decode(BackendMessage.self, from: Data(raw.utf8))
            #expect(response?.catalogMetadata?.valid != true)
        }
    }
}

@MainActor
struct CatalogRelationshipDiscoveryTests {
    private let profile = UUID()
    private func response(_ selector: CatalogRequest, fields: [String], rows: [[String?]],
                          onPage: CatalogMetadataPageHandler? = nil, state: String = "complete", issue: String? = nil,
                          target: CatalogRelationTarget? = nil) throws -> BackendMessage {
        let columns = fields.enumerated().map { ResultColumn(index: $0.offset, name: $0.element) }
        var page = CatalogMetadataCollection(selector: selector, captureId: "capture", observedAt: "2026-11-05T12:00:00Z", consistency: "bestEffort",
            state: state, columns: columns, rows: rows, issue: issue)
        if selector.kind == "referencingTables", !["unavailable", "stale"].contains(state) {
            page.target = target ?? .init(schema: selector.schema ?? "", name: selector.object ?? "")
        }
        try onPage?(page)
        var result = BackendMessage(type: "query.result", requestId: "r", columns: columns, rows: rows,
            rowCount: Int64(rows.count), truncated: state != "complete")
        result.displayNotice = issue
        return result
    }
    private let fkFields = ["name", "targetSchema", "targetTable", "sourceColumn", "targetColumn", "position"]
    private let listFields = ["schema", "name", "kind"]

    @Test func incomingGroupsStaySeparateAcrossSourcesAndRetainCompleteCompositeMappings() async throws {
        var requests: [CatalogRequest] = []
        let reader = CatalogDiscoveryReader(provider: { selector, _, onPage in
            requests.append(selector)
            if selector.kind == "referencingTables" {
                return try response(selector, fields: listFields,
                    rows: [["one", "child", "table"], ["two", "child", "table"], ["public", "parent", "table"]], onPage: onPage)
            }
            let rows: [[String?]] = [["same_name", "public", "parent", "child_b", "parent_b", "2"],
                                    ["same_name", "public", "parent", "child_a", "parent_a", "1"]]
            return try response(selector, fields: fkFields, rows: rows)
        }, isCurrent: { true }, cancel: { _ in })
        let target = ERTableID(profileID: profile, schema: "public", name: "parent")
        let model = IncomingRelationshipDiscoveryModel(target: target, reader: reader)
        #expect(requests.isEmpty && model.relationships.isEmpty)
        await model.discover(includeOutgoing: true)
        #expect(model.complete && model.relationships.count == 3 && Set(model.relationships.map(\.id)).count == 3)
        #expect(model.sourcesChecked == 3 && requests.count == 5)
        let key = try #require(model.relationships.first).inverseKey()
        #expect(key.columns.map(\.source) == ["parent_a", "parent_b"])
        #expect(key.columns.map(\.target) == ["child_a", "child_b"])
        let values = [ChangeValue(kind: "binary", value: "AP8="), .init(kind: "text", value: "9007199254740993.123456789")]
        let filters = try key.filters(sourceColumns: [.init(index: 0, name: "parent_b"), .init(index: 1, name: "parent_a")], values: values)
        #expect(filters.map(\.column) == ["child_a", "child_b"])
        #expect(filters.map(\.value) == ["9007199254740993.123456789", "AP8="])
    }

    @Test func inverseSQLiteValuesPreserveStorageBytesAndNullDoesNotMatchChildren() throws {
        let key = TableForeignKey(name: "fk", target: .init(schema: "main", name: "p", kind: "table"), columns: [
            .init(source: "child_a", target: "parent_a", position: 1), .init(source: "child_b", target: "parent_b", position: 2)])
        let inverse = DiscoveredTableRelationship(source: .init(profileID: profile, schema: "main", name: "c"), key: key).inverseKey()
        let columns = [ResultColumn(index: 0, name: "parent_a", engine: .sqlite), .init(index: 1, name: "parent_b", engine: .sqlite)]
        for storage in [SQLiteValue(type: "blob", value: "AP8="), SQLiteValue(type: "text", value: "QQBC"), SQLiteValue(type: "real", value: "8000000000000000")] {
            let values = [SQLiteValue(type: "integer", value: "9223372036854775807").changeValue, storage.changeValue]
            let filters = try inverse.filters(sourceColumns: columns, values: values)
            #expect(filters.map(\.sqliteValue) == values.map(\.sqliteValue) && filters.allSatisfy { $0.value == nil })
        }
        #expect(throws: TableNavigationFailure.self) { try inverse.filters(sourceColumns: columns, values: [.null, .init(kind: "text", value: "NULL")]) }
        #expect(throws: TableNavigationFailure.self) { try inverse.filters(sourceColumns: columns, values: [.default, .init(kind: "text", value: "")]) }
    }

    @Test func deniedAndPartialSourceMetadataRemainVisibleAndNeverBecomeEmptyCompleteEvidence() async {
        let reader = CatalogDiscoveryReader(provider: { selector, _, onPage in
            if selector.kind == "referencingTables" {
                return try response(selector, fields: listFields, rows: [["public", "denied", "table"], ["public", "partial", "table"]], onPage: onPage)
            }
            if selector.object == "denied" { throw ERDiagramFailure("Denied") }
            return try response(selector, fields: fkFields, rows: [["fk", "public", "p", "a", "a", "1"]], state: "partial", issue: "Capture limited")
        }, isCurrent: { true }, cancel: { _ in })
        let model = IncomingRelationshipDiscoveryModel(target: .init(profileID: profile, schema: "public", name: "p"), reader: reader)
        await model.discover()
        #expect(!model.complete && model.sourcesChecked == 2 && model.issues.count == 2 && model.relationships.isEmpty)
    }

    @Test func visibleSchemaDiscoveryIsProgressiveExactAndContinuesAfterOneDeniedSchema() async throws {
        var publishedDuringRequest = false
        var model: VisibleTableDiscoveryModel!
        let reader = CatalogDiscoveryReader(provider: { selector, _, onPage in
            if selector.kind == "schemas" { return try response(selector, fields: ["name"], rows: [["denied"], ["visible"]], onPage: onPage) }
            if selector.schema == "denied" { throw ERDiagramFailure("Denied") }
            let result = try response(selector, fields: listFields,
                rows: [["visible", "é", "table"], ["visible", "e\u{301}", "table"]], onPage: onPage)
            publishedDuringRequest = model.tables.count == 2
            return result
        }, isCurrent: { true }, cancel: { _ in })
        model = VisibleTableDiscoveryModel(profileID: profile, reader: reader)
        await model.discover()
        #expect(publishedDuringRequest && model.tables.count == 2 && Set(model.tables).count == 2)
        #expect(!model.complete && model.schemasChecked == 2 && model.issues.count == 1)
    }

    @Test func changedContextAndStopRejectLatePagePublicationAndCancelOwnedRequest() async {
        var current = true, cancellations = 0
        let reader = CatalogDiscoveryReader(provider: { selector, request, onPage in
            request.submitted = true
            current = false
            return try response(selector, fields: ["name"], rows: [["late"]], onPage: onPage)
        }, isCurrent: { current }, cancel: { _ in cancellations += 1 })
        let model = VisibleTableDiscoveryModel(profileID: profile, reader: reader)
        await model.discover()
        #expect(model.tables.isEmpty && !model.complete && !reader.contextIsCurrent)
        var stopped: VisibleTableDiscoveryModel!
        let stoppedReader = CatalogDiscoveryReader(provider: { selector, request, onPage in
            request.submitted = true
            stopped.stop()
            return try response(selector, fields: ["name"], rows: [["late"]], onPage: onPage)
        }, isCurrent: { true }, cancel: { _ in cancellations += 1 })
        stopped = VisibleTableDiscoveryModel(profileID: profile, reader: stoppedReader)
        await stopped.discover()
        #expect(stopped.tables.isEmpty && cancellations == 1 && !stopped.complete)
    }

    @Test func referringTableLimitRetainsBoundedSourcesAndReportsPartial() async {
        let reader = CatalogDiscoveryReader(provider: { selector, _, onPage in
            if selector.kind == "referencingTables" {
                return try response(selector, fields: listFields, rows: (0...1_000).map { ["public", "c\($0)", "table"] }, onPage: onPage)
            }
            return try response(selector, fields: fkFields, rows: [])
        }, isCurrent: { true }, cancel: { _ in })
        let model = IncomingRelationshipDiscoveryModel(target: .init(profileID: profile, schema: "public", name: "p"), reader: reader)
        await model.discover()
        #expect(model.sourceCount == 1_000 && model.sourcesChecked == 1_000 && !model.complete && !model.issues.isEmpty)
    }

    @Test func deadlineCancelsOwnedReadAndReportsPartialInsteadOfCompleting() async {
        var cancellations = 0
        let reader = CatalogDiscoveryReader(provider: { selector, request, onPage in
            request.submitted = true
            try await Task.sleep(for: .milliseconds(20))
            return try response(selector, fields: ["name"], rows: [["late"]], onPage: onPage)
        }, isCurrent: { true }, cancel: { _ in cancellations += 1 }, seconds: 0.001)
        let model = VisibleTableDiscoveryModel(profileID: profile, reader: reader)
        await model.discover()
        #expect(cancellations == 1 && !model.complete && !model.isBusy && model.tables.isEmpty)
        #expect(model.notice?.contains("deadline") == true)
    }

    @Test func canonicalDescriptorResolvesManualCaseEvenWithNoIncomingSourcesAndRetainsDraftPresentation() async throws {
        let original = ERTableID(profileID: profile, schema: "main", name: "PARENT")
        let canonical = ERTableID(profileID: profile, schema: "main", name: "Parent")
        let reader = CatalogDiscoveryReader(provider: { selector, _, onPage in
            if selector.kind == "referencingTables" {
                return try response(selector, fields: listFields, rows: [], onPage: onPage, target: .init(schema: "main", name: "Parent"))
            }
            return try response(selector, fields: fkFields, rows: [])
        }, isCurrent: { true }, cancel: { _ in })
        let discovery = IncomingRelationshipDiscoveryModel(target: original, reader: reader)
        await discovery.discover(includeOutgoing: true)
        #expect(discovery.complete && discovery.resolvedTarget == canonical && discovery.sourceCount == 0)
        let placement = ERPlacement(table: original, point: .init(x: 40, y: 90), manual: true)
        let diagram = ERDiagramModel(stored: .init(profileID: profile, engine: .sqlite, database: "", tables: [original], placements: [placement], collapsed: [original], selected: original))
        diagram.adoptCanonicalIdentity(original, resolved: canonical)
        #expect(diagram.stored.tables == [canonical] && diagram.stored.selected == canonical && diagram.stored.collapsed == [canonical])
        #expect(diagram.stored.placements == [.init(table: canonical, point: placement.point, manual: true)] && diagram.metadata.isEmpty)
    }

    @Test func restoreContainsNoDiscoveryAndDoesNotStartMetadataWork() throws {
        let stored = StoredERDiagram(profileID: profile, engine: .sqlite, database: "", tables: [.init(profileID: profile, schema: "main", name: "t")])
        let bytes = try JSONEncoder().encode(stored)
        let model = ERDiagramModel(stored: try JSONDecoder().decode(StoredERDiagram.self, from: bytes))
        #expect(model.visibleTableDiscovery == nil && model.neighbourDiscovery == nil && model.context == nil)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("Discovery"))
        let document = SQLDocument(title: "Restored", text: "", profileID: profile)
        #expect(document.incomingRelationships == nil && document.runtime == nil)
    }
}

@MainActor
struct CatalogMetadataDiscoveryCallbackTests {
    @Test func accumulatorRejectsChangedCanonicalTargetAndTargetOnLegacyKinds() throws {
        let selector = CatalogRequest(kind: "referencingTables", schema: "main", object: "PARENT", objectKind: "table")
        var page = CatalogMetadataCollection(selector: selector, captureId: "capture", observedAt: "2026-11-05T12:00:00Z", consistency: "schemaVersion", state: "complete", columns: [], rows: [], nextCursor: "next", target: .init(schema: "main", name: "Parent"))
        var accumulator = CatalogMetadataAccumulator()
        try accumulator.append(page, selector: selector)
        page.target = .init(schema: "main", name: "parent")
        page.nextCursor = nil
        #expect(throws: BackendTransportError.self) { try accumulator.append(page, selector: selector) }
        page.selector = .init(kind: "objects", schema: "main", objectKind: "table")
        #expect(!page.valid)
    }

    @Test func callbackLimitAndCancellationReleaseOriginalCaptureWithoutFetchingMorePages() async throws {
        for cancel in [false, true] {
            let selector = CatalogRequest(kind: "referencingTables", schema: "public", object: "p", objectKind: "table")
            let pending = CatalogMetadataRequest()
            var commands: [BackendCommand] = []
            do {
                _ = try await CatalogMetadataLoader.load(selector, sessionID: "s", request: pending,
                    isCurrent: { true }, onPage: { _ in
                        if cancel { pending.cancelled = true }
                        else { throw CatalogDiscoveryLimit(message: "Retained candidates limited") }
                    }, send: { command in
                        commands.append(command)
                        var result = BackendMessage(type: command.type + ".result", requestId: command.requestId, sessionId: "s", queryId: command.queryId)
                        if command.type == "catalog.close" { result.catalogMetadata = .init(collections: [], closed: true) }
                        else {
                            result.catalogMetadata = .init(collections: [.init(selector: selector, captureId: "original", observedAt: "2026-11-05T12:00:00Z", consistency: "bestEffort", state: "complete", columns: [], rows: [], nextCursor: "next", target: .init(schema: "public", name: "p"))])
                        }
                        return result
                    })
                Issue.record("The callback stop signal was ignored")
            } catch is CatalogDiscoveryLimit {} catch is CatalogMetadataFailure {}
            #expect(commands.map(\.type) == ["catalog.page", "catalog.close"])
            #expect(commands.last?.catalogMetadata?.captureIds == ["original"])
        }
    }
}
