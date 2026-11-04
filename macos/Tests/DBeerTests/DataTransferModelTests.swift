import Foundation
import Testing
@testable import DBeer

private actor TransferFixtureBackend: DataTransferBackend {
    var operations: [String] = []
    var closed = false
    func begin(_ operation: String, _ request: DataTransferRequest) async throws -> DataTransferReply {
        try await self.request(operation, request)
    }
    func request(_ operation: String, _ request: DataTransferRequest) async throws -> DataTransferReply {
        guard !closed else { throw CancellationError() }
        guard request.valid(for: "transfer." + operation) else { throw BackendRequestError.invalidCommand }
        operations.append(operation)
        let columns = [DataTransferColumn(sourceIndex: 0, name: "id", type: "integer", nullable: false),
                       DataTransferColumn(sourceIndex: 1, name: "name", type: "text", nullable: false)]
        return DataTransferReply(jobId: "fixture-job", state: operation == "describe" ? "described" : operation == "preview" ? "ready" : operation == "apply" ? "completed" : "closed",
            phase: "fixture", columns: columns, sql: operation == "preview" ? "CREATE TABLE fixture (id BIGINT, name TEXT)" : nil,
            planDigest: operation == "preview" ? String(repeating: "a", count: 64) : nil,
            rowsRead: 2, rowsWritten: operation == "apply" ? 2 : 0, notices: [], tableCreated: operation == "apply", outcomeUnknown: false)
    }
    func shutdown() async { closed = true }
    func count(_ operation: String) -> Int { operations.filter { $0 == operation }.count }
}

@MainActor
struct DataTransferModelTests {
    private func profile() -> SavedConnection {
        .init(name: "Fixture", settings: .init(host: "fixture.invalid", port: 5432, database: "fixture", user: "reader", password: "", sslMode: "disable"))
    }
    @Test func sharedTransferContractSupportsReviewedTypesAndEmptyCreation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bytes = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/data-transfer-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for item in try #require(fixture["validRequests"] as? [[String: Any]]) {
            let kind = try #require(item["kind"] as? String)
            let request = try #require(item["request"])
            let data = try JSONSerialization.data(withJSONObject: request)
            #expect(try JSONDecoder().decode(DataTransferRequest.self, from: data).valid(for: kind))
        }
        for item in try #require(fixture["validReplies"] as? [[String: Any]]) {
            #expect(try JSONDecoder().decode(DataTransferReply.self, from: JSONSerialization.data(withJSONObject: item)).valid)
        }
    }
    @Test func csvCreationRequiresReviewedTypesAndExplicitApply() async throws {
        let profile = profile(), backend = TransferFixtureBackend()
        let model = DataTransferModel(profiles: [profile], resolve: { profile, _ in profile.settings(password: "") },
            current: { _ in true }, authorize: { _, _ in true }, factory: { backend })
        model.targetID = profile.id; model.targetTable = "new_table"
        await model.loadCSV(Data("id,name\n1,alpha\n2,beta\n".utf8), name: "fixture.csv")
        #expect(!model.canApply)
        await model.describe()
        #expect(model.columns.count == 2 && model.canPreview && !model.canApply)
        await model.preview()
        #expect(model.canApply)
        #expect(await backend.count("apply") == 0)
        model.columns[0].name = "changed"
        #expect(!model.canApply)
        await model.preview()
        await model.apply()
        #expect(model.reply?.state == "completed" && model.reply?.rowsWritten == 2)
        #expect(await backend.count("apply") == 1)
        await model.apply()
        #expect(await backend.count("apply") == 1)
        await model.close()
    }
    @Test func declinedReviewSendsNoApply() async {
        let profile = profile(), backend = TransferFixtureBackend()
        let model = DataTransferModel(profiles: [profile], resolve: { profile, _ in profile.settings(password: "") },
            current: { _ in true }, authorize: { _, _ in false }, factory: { backend })
        model.targetID = profile.id; model.targetTable = "new_table"
        await model.loadCSV(Data("id,name\n1,alpha\n2,beta\n".utf8), name: "fixture.csv")
        await model.describe(); await model.preview(); await model.apply()
        #expect(await backend.count("apply") == 0)
        #expect(model.reply?.state == "ready" && !model.hasUnknownOutcome)
        await model.close()
    }
    @Test func closedInputShapesRejectMixedModesAndDuplicateColumns() {
        let endpoint = DataTransferEndpoint(connection: profile().settings(password: ""), schema: "public", table: "destination")
        var request = DataTransferRequest(mode: "csv", target: endpoint, headers: ["id"], rows: [[.null]])
        #expect(request.valid(for: "transfer.describe"))
        request.source = endpoint
        #expect(!request.valid(for: "transfer.describe"))
        request.source = nil
        request.columns = [.init(sourceIndex: 0, name: "id", type: "integer", nullable: true), .init(sourceIndex: 0, name: "id2", type: "integer", nullable: true)]
        #expect(!request.valid(for: "transfer.preview"))
        request = .init(jobId: "job", planDigest: String(repeating: "a", count: 64), confirmed: true)
        #expect(request.valid(for: "transfer.apply"))
        request.rows = [[.null]]
        #expect(!request.valid(for: "transfer.apply"))
    }
}
