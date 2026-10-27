import Foundation
import Testing
@testable import DBeer

enum DataComparisonTestFixtures {
    struct Fixture: Decodable { var version: Int; var capability: String; var commands: [BackendCommand]; var responses: [BackendMessage] }
    static func wire() throws -> Fixture {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/data-comparison-v1.json")))
    }
    static func profiles() -> [SavedConnection] { SchemaComparisonTestFixtures.profiles() }
    @MainActor static func configure(_ model: DataComparisonModel, _ profiles: [SavedConnection]) {
        model.sourceID = profiles[0].id; model.targetID = profiles[1].id
        model.sourceTable = .init(schema: "public", name: "source_orders"); model.targetTable = .init(schema: "public", name: "target_orders")
    }
    @MainActor static func wait(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition(), "Data comparison did not reach expected state")
    }
}
actor DataComparisonTestBackend: DataComparisonBackend {
    let fixture: DataComparisonTestFixtures.Fixture
    var operations: [String] = []
    var requests: [DataComparisonRequest] = []
    var describing = false
    var running = false
    var customData: Data?
    var delayAdmission = false
    private var admission: CheckedContinuation<Void, Never>?
    init(running: Bool = false) throws { fixture = try DataComparisonTestFixtures.wire(); self.running = running }
    func setRunning(_ value: Bool) { running = value }
    func setLargeValue(_ value: Data) { customData = value }
    func delayNextAdmission() { delayAdmission = true }
    func releaseAdmission() { admission?.resume(); admission = nil }
    func begin(_ operation: String, _ request: DataComparisonRequest) async throws -> DataComparisonResponse {
        operations.append(operation); requests.append(request); describing = operation == "describe"
        if delayAdmission { await withCheckedContinuation { admission = $0 }; delayAdmission = false }
        return .init(jobId: describing ? "describe-job" : "data-job", state: .pending)
    }
    func request(_ operation: String, _ request: DataComparisonRequest) async throws -> DataComparisonResponse {
        operations.append(operation)
        if operation == "diff" {
            return .init(jobId: request.jobId!, state: .completed, diff: try ComparisonTextDiffTestFixtures.diff(), offset: request.offset, cellOffset: request.cellOffset)
        }
        if operation == "status" {
            if running && !describing { return .init(jobId: "data-job", state: .running, phase: "capturing") }
            if describing { return fixture.responses.last!.dataComparison! }
            return fixture.responses[2].dataComparison!
        }
        if operation == "page" {
            var response = fixture.responses[3].dataComparison!
            if request.cellOffset == 2 {
                response.page?.rows[0].cellOffset = 2; response.page?.rows[0].nextCellOffset = 3; response.page?.rows[0].cellsTruncated = false
                response.page?.rows[0].cells = [.init(mapping: 2, left: .init(isNull: false, preview: "AP8=", totalBytes: 4, truncated: false, valueRef: "source-binary"), right: nil, different: true, uncertain: false)]
            } else if let customData {
                let preview = String(decoding: customData.prefix(256), as: UTF8.self)
                response.page?.rows[0].cells[1].left = .init(isNull: false, preview: preview, totalBytes: Int64(customData.count), truncated: true, valueRef: "source-value")
            }
            return response
        }
        if operation == "value" {
            if request.valueRef == "source-binary" { return .init(jobId: "data-job", state: .completed, value: .init(valueRef: "source-binary", isNull: false, totalBytes: 4, offset: 0, nextOffset: 4, dataBase64: Data("AP8=".utf8).base64EncodedString(), hasMore: false)) }
            if let customData {
                let offset = Int(request.offset ?? 0), end = min(customData.count, Int(request.offset ?? 0) + (request.maxBytes ?? 65_536))
                return .init(jobId: "data-job", state: .completed, value: .init(valueRef: request.valueRef!, isNull: false,
                    totalBytes: Int64(customData.count), offset: Int64(offset), nextOffset: Int64(end), dataBase64: customData[offset..<end].base64EncodedString(), hasMore: end < customData.count))
            }
            return fixture.responses[4].dataComparison!
        }
        return .init(jobId: request.jobId!, state: operation == "cancel" ? .cancelled : .closed)
    }
    func shutdown() async { operations.append("shutdown") }
}

struct DataComparisonProtocolTests {
    @Test func forcedHelperExitRemovesOwnedPrivateCaptures() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let parent = repository.appendingPathComponent("build/r26/cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let backend = DataComparisonHelperBackend(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json,os,sys,time
        def read(): return json.loads(sys.stdin.readline())
        def send(x): print(json.dumps(x),flush=True)
        c=read();send({'type':'hello.ack','requestId':c['requestId'],'protocolVersion':5,'capabilities':['dataComparisonV1']})
        c=read();root=os.environ['DBEER_DATA_COMPARISON_ROOT']
        os.mkdir(root+'/capture',0o700)
        with open(root+'/capture/rows.jsonl','w') as f: f.write('["synthetic"]\\n')
        send({'type':c['type']+'.result','requestId':c['requestId'],'dataComparison':{'jobId':'cleanup-job','state':'pending'}})
        while True: time.sleep(1)
        """], scratchParentURL: parent)
        let request = try #require(DataComparisonTestFixtures.wire().commands[0].dataComparison)
        let reply = try await backend.begin("describe", request)
        #expect(reply.state == .pending)
        let children = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
        let scratch = try #require(children.first)
        #expect(children.count == 1)
        #expect((try FileManager.default.attributesOfItem(atPath: scratch.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("capture/rows.jsonl").path))
        await backend.shutdown()
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
        await #expect(throws: CancellationError.self) { _ = try await backend.begin("describe", request) }
    }
    @Test func sharedWireAndStrictPartialSemantics() throws {
        let fixture = try DataComparisonTestFixtures.wire()
        #expect(fixture.version == BackendProtocol.version && fixture.capability == "dataComparisonV1")
        for command in fixture.commands {
            #expect(command.dataComparison?.valid(for: command.type) == true)
            #expect(command.terminalType == command.type + ".result")
            #expect(try JSONDecoder().decode(BackendCommand.self, from: JSONEncoder().encode(command)) == command)
        }
        for response in fixture.responses { try response.validate() }
        var falseEquality = fixture.responses[2]; falseEquality.dataComparison?.summary?.comparison.fullEquality = true
        #expect(throws: BackendTransportError.self) { try falseEquality.validate() }
        var start = try #require(fixture.commands[1].dataComparison)
        start.columns?[0].key = false; #expect(!start.valid(for: "data.start"))
        start.columns?[0].key = true; start.source?.readLimit = 100_001; #expect(!start.valid(for: "data.start"))
        #expect(!DataComparisonRequest(jobId: "job", limit: 0).valid(for: "data.page"))
        #expect(!DataComparisonFilter(column: "note", operator: "isNull", value: "NULL").valid)
        #expect(DataComparisonFilter(column: "note", operator: "eq", value: "NULL").valid)
    }
    @Test(arguments: ["job", "pageOffset", "cellOffset", "valueRef"])
    func transportBindsEachBoundedRead(_ mismatch: String) async throws {
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json,sys
        def read(): return json.loads(sys.stdin.readline())
        def send(x): print(json.dumps(x),flush=True)
        c=read();send({'type':'hello.ack','requestId':c['requestId'],'protocolVersion':5,'capabilities':['dataComparisonV1']})
        c=read();r=c['dataComparison'];out={'jobId':'wrong' if '\(mismatch)'=='job' else r['jobId'],'state':'completed'}
        if '\(mismatch)'=='valueRef': out['value']={'valueRef':'wrong','isNull':False,'totalBytes':0,'offset':0,'nextOffset':0,'dataBase64':'','hasMore':False}
        else:
          offset=1 if '\(mismatch)'=='pageOffset' else 0
          cells=1 if '\(mismatch)'=='cellOffset' else 0
          row={'index':offset,'kind':'deleted','leftIndex':0,'cells':[{'mapping':cells,'left':{'isNull':True,'preview':'','totalBytes':0,'truncated':False,'valueRef':'v'},'different':False,'uncertain':False}],'cellOffset':cells,'nextCellOffset':cells+1,'totalCells':cells+1,'cellsTruncated':False}
          out['page']={'offset':offset,'nextOffset':offset+1,'hasMore':False,'rows':[row]}
        send({'type':c['type']+'.result','requestId':c['requestId'],'dataComparison':out});sys.stdin.readline()
        """])
        try await client.start()
        await #expect(throws: BackendTransportError.self) {
            _ = try await client.request(.compareData(mismatch == "valueRef" ? "value" : "page", .init(jobId: "data-job", valueRef: mismatch == "valueRef" ? "v" : nil)))
        }
        _ = await client.shutdown()
    }
}

@MainActor
struct DataComparisonModelTests {
    @Test func explicitMetadataAndKeysFreezeScopeAndPreserveExactBoundedValues() async throws {
        let profiles = DataComparisonTestFixtures.profiles(), backend = try DataComparisonTestBackend()
        var resolutions: [UUID] = [], created = 0
        let model = DataComparisonModel(profiles: profiles, resolve: { profile, _ in resolutions.append(profile.id); return profile.settings(password: "") }, factory: { created += 1; return backend })
        DataComparisonTestFixtures.configure(model, profiles)
        #expect(model.sourceLimit == 10_000 && model.targetLimit == 10_000 && model.canDescribe && !model.canCompare && resolutions.isEmpty && created == 0)
        await model.readMetadata(); try await DataComparisonTestFixtures.wait { model.descriptors != nil && !model.isWorking }
        #expect(created == 1 && !model.canCompare && model.mappings.allSatisfy { !$0.key })
        model.mappings[0].key = true; model.sourceLimit = 3; model.targetLimit = 3
        model.sourceTable.name = "other"; #expect(!model.canCompare); model.sourceTable.name = "source_orders"
        #expect(model.canCompare)
        await model.compare(); try await DataComparisonTestFixtures.wait { model.page != nil }
        #expect(created == 2 && model.summary?.comparison.complete == false && model.summary?.source.observedAtLeast == 4)
        #expect(model.sourceProfile?.host == "source.example" && model.targetProfile?.host == "target.example")
        let preview = try #require(model.page?.rows[0].cells[1].left)
        await model.inspect(preview, title: "Source"); #expect(model.valueChunk?.text == "9007199254740993.123456789")
        await model.cells(next: true); #expect(model.selectedRow?.cells.first?.mapping == 2)
        await model.cells(next: false); #expect(model.selectedRow?.cellOffset == 0)
        await model.close(); #expect(model.phase == .closed && model.page == nil)
        let operations = await backend.operations; #expect(operations.contains("close") && operations.contains("shutdown"))
    }
    @Test func stopRejectsLateAdmissionWithoutReconnecting() async throws {
        let profiles = DataComparisonTestFixtures.profiles(), backend = try DataComparisonTestBackend()
        await backend.delayNextAdmission()
        let model = DataComparisonModel(profiles: profiles, resolve: { profile, _ in profile.settings(password: "") }, factory: { backend })
        DataComparisonTestFixtures.configure(model, profiles)
        let task = Task { await model.readMetadata() }
        for _ in 0..<100 { if await backend.requests.count == 1 { break }; try await Task.sleep(for: .milliseconds(5)) }
        await model.stop(); await backend.releaseAdmission(); await task.value
        #expect(model.phase == .cancelled && model.descriptors == nil)
        await model.close()
    }
}
