import Foundation
import Testing
@testable import DBeer

enum SchemaComparisonTestFixtures {
    struct Fixture: Decodable { var version: Int; var capability: String; var commands: [BackendCommand]; var responses: [BackendMessage] }
    static func wire() throws -> Fixture {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/schema-comparison-v1.json")))
    }
    static func profiles() -> [SavedConnection] {
        [SavedConnection(name: "Source fixture", settings: .init(host: "source.example", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable")),
         SavedConnection(name: "Target fixture", settings: .init(host: "target.example", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable"))]
    }
}
actor SchemaComparisonTestBackend: SchemaComparisonBackend {
    var operations: [String] = []
    var starts: [SchemaComparisonRequest] = []
    var running = false
    var customValue: Data?
    let fixture: SchemaComparisonTestFixtures.Fixture
    init(running: Bool = false) throws { self.running = running; fixture = try SchemaComparisonTestFixtures.wire() }
    func setValue(_ data: Data) { customValue = data }
    func start(_ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse { starts.append(request); return fixture.responses[0].schemaComparison! }
    func request(_ operation: String, _ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse {
        operations.append(operation)
        if operation == "status", running { return .init(jobId: "schema-job", state: .running) }
        let index = try #require(["start", "status", "page", "value", "export", "cancel", "close"].firstIndex(of: operation))
        var response = fixture.responses[index].schemaComparison!
        if operation == "value", let data = customValue {
            let offset = Int(request.offset ?? 0); let end = min(data.count, offset + (request.maxBytes ?? 65_536))
            response.value = .init(valueRef: request.valueRef, totalBytes: Int64(data.count), offset: Int64(offset), nextOffset: Int64(end),
                dataBase64: data[offset..<end].base64EncodedString(), hasMore: end < data.count)
        }
        if operation == "status", let start = starts.first { response.summary?.mappings = start.mappings! }
        if operation == "page", request.collection == "issues" {
            response.page = try JSONDecoder().decode(SchemaComparisonPage.self, from: Data(#"{"collection":"issues","offset":0,"nextOffset":0,"hasMore":false,"items":[]}"#.utf8))
        }
        return response
    }
    func shutdown() async { operations.append("shutdown") }
}
struct SchemaComparisonProtocolTests {
    @Test func sharedWireRoundTripsAndRejectsFalseEquality() throws {
        let fixture = try SchemaComparisonTestFixtures.wire()
        #expect(fixture.version == BackendProtocol.version && fixture.capability == "schemaComparisonV1")
        #expect(fixture.commands.count == 7 && fixture.responses.count == 7)
        for command in fixture.commands {
            #expect(command.schemaComparison?.valid(for: command.type) == true)
            #expect(command.terminalType == command.type + ".result")
            #expect(try JSONDecoder().decode(BackendCommand.self, from: JSONEncoder().encode(command)) == command)
        }
        for response in fixture.responses { try response.validate() }
        var falseEquality = fixture.responses[1]; falseEquality.schemaComparison?.summary?.fullEquality = true
        #expect(throws: BackendTransportError.self) { try falseEquality.validate() }
        #expect(!SchemaComparisonRequest(jobId: "job", collection: "issues", limit: 0).valid(for: "schema.page"))
        #expect(!SchemaComparisonRequest(jobId: "job", maxBytes: 0).valid(for: "schema.export"))
        var mappings = SchemaMappings(); mappings.schemas.append(mappings.schemas[0]); #expect(!mappings.valid)
    }
    @Test(arguments: ["job", "collection", "offset", "valueRef"])
    func transportBindsRepliesToExactRequests(_ mismatch: String) async throws {
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json,sys
        def read(): return json.loads(sys.stdin.readline())
        def send(x): print(json.dumps(x),flush=True)
        c=read(); send({'type':'hello.ack','requestId':c['requestId'],'protocolVersion':5,'capabilities':['schemaComparisonV1']})
        c=read(); op=c['type']; r=c['schemaComparison']; value={'jobId':r['jobId'],'state':'completed'}
        if op=='schema.value': value['value']={'valueRef':'wrong-ref','totalBytes':0,'offset':0,'nextOffset':0,'dataBase64':'','hasMore':False}
        else:
          offset=1 if '\(mismatch)'=='offset' else 0
          value['page']={'collection':'issues' if '\(mismatch)'=='collection' else 'differences','offset':offset,'nextOffset':offset,'hasMore':False,'items':[]}
        if '\(mismatch)'=='job': value['jobId']='other-job'
        send({'type':op+'.result','requestId':c['requestId'],'schemaComparison':value})
        sys.stdin.readline()
        """])
        try await client.start()
        let request = mismatch == "valueRef" ? SchemaComparisonRequest(jobId: "schema-job", valueRef: "v0") : SchemaComparisonRequest(jobId: "schema-job", collection: "differences")
        await #expect(throws: BackendTransportError.self) { _ = try await client.request(.compareSchema(mismatch == "valueRef" ? "value" : "page", request)) }
        _ = await client.shutdown()
    }
}
@MainActor
struct SchemaComparisonModelTests {
    @Test func configurationNeverConnectsThenFreezesBothProfilesAndExportsAtomically() async throws {
        let profiles = SchemaComparisonTestFixtures.profiles(); let backend = try SchemaComparisonTestBackend()
        var resolutions: [UUID] = []
        let model = SchemaComparisonModel(profiles: profiles, resolve: { profile in resolutions.append(profile.id); return profile.settings(password: "") }, factory: { backend })
        model.sourceID = profiles[0].id; model.targetID = profiles[1].id
        let initialStarts = await backend.starts
        #expect(model.canStart && resolutions.isEmpty && initialStarts.isEmpty)
        await model.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while model.page == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.phase == .completed && model.summary?.changedObjects == 1)
        #expect(resolutions == profiles.map(\.id))
        #expect(model.sourceProfile?.host == "source.example" && model.targetProfile?.host == "target.example")
        let preview = try #require(model.page?.differences.first?.sourcePreview)
        await model.inspect(preview); #expect(model.valueText?.contains("9007199254740993.123456789") == true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-schema-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("report.json")
        try Data("previous".utf8).write(to: destination)
        await model.export(to: destination)
        let exported = try Data(contentsOf: destination)
        #expect(model.exportComplete && exported.count == preview.totalBytes)
        await model.close(); #expect(await backend.operations.contains("close"))
    }
    @Test func stopCancelsBothSidesAndClosingAnUnusedComparisonNeverCreatesAHelper() async throws {
        let profiles = SchemaComparisonTestFixtures.profiles(); let backend = try SchemaComparisonTestBackend(running: true)
        var created = 0
        let model = SchemaComparisonModel(profiles: profiles, resolve: { $0.settings(password: "") }, factory: { created += 1; return backend })
        await model.close(); #expect(created == 0)
        model.sourceID = profiles[0].id; model.targetID = profiles[0].id
        await model.start(); #expect(created == 1)
        await model.stop(); #expect(model.phase == .cancelled)
        let operations = await backend.operations
        #expect(operations.contains("cancel") && operations.contains("shutdown"))
    }
    @Test func largePropertyChunksPreserveUTF8AcrossBoundaries() async throws {
        let profiles = SchemaComparisonTestFixtures.profiles(); let backend = try SchemaComparisonTestBackend()
        let source = String(repeating: "x", count: 65_535) + "🌍" + String(repeating: "y", count: 100)
        let data = Data(source.utf8); await backend.setValue(data)
        let model = SchemaComparisonModel(profiles: profiles, resolve: { $0.settings(password: "") }, factory: { backend })
        model.sourceID = profiles[0].id; model.targetID = profiles[1].id; await model.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while model.page == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        await model.inspect(.init(text: String(source.prefix(256)), totalBytes: Int64(data.count), truncated: true, valueRef: "v0"))
        #expect(model.valueBoundaryBytes == 1 && model.valueText?.contains("�") == false)
        await model.nextValue(); #expect(model.valueText?.contains("🌍") == true && !model.valueHasMore)
        await model.previousValue(); #expect(model.valueOffset == 0)
        await model.close()
    }
}
