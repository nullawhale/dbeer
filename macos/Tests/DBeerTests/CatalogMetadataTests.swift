import Foundation
import Testing
@testable import DBeer

struct CatalogMetadataProtocolTests {
    private struct Fixture: Decodable {
        var valid: [BackendCommand]
        var invalid: [String]
        var responses: [BackendMessage]
    }
    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/catalog-metadata-v1.json")))
    }
    @Test func sharedContractAndStrictSelectors() throws {
        let fixture = try fixture()
        for command in fixture.valid {
            #expect(command.catalogMetadata?.valid(for: command.type) == true)
            #expect(command.terminalType == command.type + ".result")
            #expect(try JSONDecoder().decode(BackendCommand.self, from: JSONEncoder().encode(command)) == command)
        }
        for raw in fixture.invalid {
            var accepted = false
            do {
                let command = try JSONDecoder().decode(BackendCommand.self, from: Data(raw.utf8))
                accepted = command.catalogMetadata?.valid(for: command.type) == true
            } catch {}
            #expect(!accepted)
        }
        for reply in fixture.responses { try reply.validate() }
    }
    @Test func accumulatorPreservesRowsAndRejectsChangedObservationAndCursorCycles() throws {
        var page = try #require(fixture().responses[0].catalogMetadata?.collections.first)
        page.observedAt = "2026-11-05T12:00:00.123456789Z"
        var accumulator = CatalogMetadataAccumulator()
        try accumulator.append(page, selector: page.selector)
        var changed = page
        changed.captureId = "other"
        #expect(throws: BackendTransportError.self) { try accumulator.append(changed, selector: page.selector) }
        #expect(throws: BackendTransportError.self) { try accumulator.append(page, selector: page.selector) }
        page.nextCursor = nil
        page.rows[0][0] = "second_key"
        try accumulator.append(page, selector: page.selector)
        let result = try accumulator.result(requestId: "r", sessionId: "s", queryId: "q")
        #expect(result.rowCount == 2)
        #expect(result.truncated == false)
        #expect(result.catalogRecords.map { $0["name"] } == ["orders_customer_fkey", "second_key"])
        #expect(try TableForeignKey.parse(result).count == 2)
    }
    @Test func incompleteAndStaleCollectionsRemainExplicit() throws {
        var page = try #require(fixture().responses[0].catalogMetadata?.collections.first)
        page.nextCursor = nil
        page.state = "partial"
        page.issue = "Capture limit reached"
        var partial = CatalogMetadataAccumulator()
        try partial.append(page, selector: page.selector)
        #expect(try partial.result(requestId: "r", sessionId: "s", queryId: "q").truncated == true)
        page.state = "stale"
        var stale = CatalogMetadataAccumulator()
        try stale.append(page, selector: page.selector)
        #expect(throws: CatalogMetadataFailure.self) { try stale.result(requestId: "r", sessionId: "s", queryId: "q") }
    }
    @MainActor @Test func loaderClosesImmutableCaptureAfterAggregatingPages() async throws {
        var page = try #require(fixture().responses[0].catalogMetadata?.collections.first)
        let selector = page.selector
        let metadataRequest = CatalogMetadataRequest()
        var commands: [BackendCommand] = []
        let result = try await CatalogMetadataLoader.load(selector, sessionID: "s", request: metadataRequest,
            isCurrent: { true }, send: { command in
                commands.append(command)
                var reply = BackendMessage(type: command.type + ".result", requestId: command.requestId,
                    sessionId: "s", queryId: command.queryId, transactionStatus: .idle, connected: true)
                if command.type == "catalog.close" {
                    reply.catalogMetadata = .init(collections: [], closed: true)
                } else {
                    if command.catalogMetadata?.cursor != nil { page.nextCursor = nil }
                    reply.catalogMetadata = .init(collections: [page])
                }
                return reply
            })
        #expect(commands.map(\.type) == ["catalog.page", "catalog.page", "catalog.close"])
        #expect(Set(commands.compactMap(\.queryId)).count == 3)
        #expect(result.rowCount == 2)
        #expect(metadataRequest.queryID == commands[1].queryId)
    }

    @MainActor @Test func loaderReleasesFirstPageAfterContextInvalidation() async throws {
        let page = try #require(fixture().responses[0].catalogMetadata?.collections.first)
        var current = true
        var commands: [String] = []
        do {
            _ = try await CatalogMetadataLoader.load(page.selector, sessionID: "s", isCurrent: { current }, send: { command in
                commands.append(command.type)
                var reply = BackendMessage(type: command.type + ".result", requestId: command.requestId,
                    sessionId: "s", queryId: command.queryId, transactionStatus: .idle, connected: true)
                if command.type == "catalog.page" {
                    current = false
                    reply.catalogMetadata = .init(collections: [page])
                } else { reply.catalogMetadata = .init(collections: [], closed: true) }
                return reply
            })
            Issue.record("Invalidated metadata context was accepted")
        } catch is CatalogMetadataFailure {}
        #expect(commands == ["catalog.page", "catalog.close"])
    }

    @MainActor @Test func loaderKeepsOriginalReleaseTargetWhenLaterPageChangesCapture() async throws {
        let original = try #require(fixture().responses[0].catalogMetadata?.collections.first)
        var pageCount = 0
        var released: [[String]] = []
        do {
            _ = try await CatalogMetadataLoader.load(original.selector, sessionID: "s", isCurrent: { true }, send: { command in
                var reply = BackendMessage(type: command.type + ".result", requestId: command.requestId,
                    sessionId: "s", queryId: command.queryId, transactionStatus: .idle, connected: true)
                if command.type == "catalog.page" {
                    pageCount += 1
                    var page = original
                    if pageCount == 2 {
                        page.captureId = "replacement_capture"
                        page.nextCursor = nil
                    }
                    reply.catalogMetadata = .init(collections: [page])
                } else {
                    released.append(command.catalogMetadata?.captureIds ?? [])
                    reply.catalogMetadata = .init(collections: [], closed: true)
                }
                return reply
            })
            Issue.record("Changed metadata capture identity was accepted")
        } catch is BackendTransportError {}
        #expect(pageCount == 2)
        #expect(released == [[original.captureId]])
    }
}
