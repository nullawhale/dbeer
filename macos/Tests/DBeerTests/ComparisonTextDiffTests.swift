import Foundation
import Testing
@testable import DBeer

enum ComparisonTextDiffTestFixtures {
    struct Fixture: Decodable {
        struct Case: Decodable { var name: String; var expected: ComparisonTextDiff }
        var formatVersion: Int
        var commands: [BackendCommand]
        var responses: [BackendMessage]
        var cases: [Case]
    }
    static func wire() throws -> Fixture {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: repository.appendingPathComponent("protocol/fixtures/text-diff-v1.json")))
    }
    static func diff() throws -> ComparisonTextDiff { try wire().cases[0].expected }
}

struct ComparisonTextDiffTests {
    @Test func sharedFixtureValidatesBothOperationsAndUTF8Ranges() throws {
        let fixture = try ComparisonTextDiffTestFixtures.wire()
        #expect(fixture.formatVersion == 1)
        for command in fixture.commands {
            #expect(command.terminalType == command.type + ".result")
            #expect((command.schemaComparison?.valid(for: command.type) ?? command.dataComparison?.valid(for: command.type)) == true)
            #expect(try JSONDecoder().decode(BackendCommand.self, from: JSONEncoder().encode(command)) == command)
        }
        for response in fixture.responses { try response.validate() }
        for value in fixture.cases {
            #expect(value.expected.valid)
            #expect(try JSONDecoder().decode(ComparisonTextDiff.self, from: JSONEncoder().encode(value.expected)) == value.expected)
        }
        let diff = try ComparisonTextDiffTestFixtures.diff()
        let source = try #require(diff.lines[0].source)
        let range = try #require(source.highlights.first?.cocoaRange(in: source.text))
        #expect((source.text as NSString).substring(with: range) == "name")
        #expect(range.location == 13) // The preceding é is two UTF-8 bytes, one UTF-16 unit.
        let combined = "e\u{301}🌍"
        #expect(ComparisonTextDiff.Highlight(start: 1, end: 3).cocoaRange(in: combined) == NSRange(location: 1, length: 1))
        #expect(ComparisonTextDiff.Highlight(start: 3, end: 7).cocoaRange(in: combined) == NSRange(location: 2, length: 2))
        #expect(ComparisonTextDiff.Highlight(start: 4, end: 7).cocoaRange(in: combined) == nil)
    }
    @Test func rejectsMalformedRangesLinesAndUnrelatedPayloads() throws {
        var diff = try ComparisonTextDiffTestFixtures.diff()
        diff.lines[0].source?.highlights = [.init(start: 11, end: 12)] // Inside é.
        #expect(!diff.valid)
        diff = try ComparisonTextDiffTestFixtures.diff(); diff.lines[0].source?.highlights = [.init(start: 1, end: 4), .init(start: 3, end: 5)]
        #expect(!diff.valid)
        diff = try ComparisonTextDiffTestFixtures.diff(); diff.lines[0].source?.number = 2
        #expect(!diff.valid)
        diff = try ComparisonTextDiffTestFixtures.diff(); diff.lines[0].source?.text = "unexpected\nline"
        #expect(!diff.valid)
        diff = try ComparisonTextDiffTestFixtures.diff(); diff.source.kind = .null; diff.source.totalBytes = 0
        #expect(!diff.valid)
        var response = try #require(ComparisonTextDiffTestFixtures.wire().responses[0].schemaComparison)
        response.offset = nil; #expect(!response.valid(for: "schema.diff.result"))
        response.offset = 0; #expect(!response.valid(for: "schema.status.result"))
        #expect(!SchemaComparisonRequest(jobId: "job", offset: 0, valueRef: "v").valid(for: "schema.diff"))
        #expect(!DataComparisonRequest(jobId: "job", offset: 0, cellOffset: -1).valid(for: "data.diff"))
    }
    @Test func semanticValuesRemainDistinctFromTextAndLimitedResults() {
        let empty = ComparisonTextDiff.Value(kind: .text, totalBytes: 0)
        let null = ComparisonTextDiff.Value(kind: .null, totalBytes: 0)
        let absent = ComparisonTextDiff.Value(kind: .absent, totalBytes: 0)
        #expect(empty.label != null.label && null.label != absent.label)
        let diff = ComparisonTextDiff(formatVersion: 1, status: .complete, source: null, target: empty,
            lines: [.init(kind: .targetOnly, target: .init(number: 1, text: "", highlights: []))])
        #expect(diff.valid)
        let binary = ComparisonTextDiff(formatVersion: 1, status: .binary, source: .init(kind: .binary, totalBytes: 400), target: absent, lines: [])
        #expect(binary.valid)
        var limited = diff; limited.status = .limited
        #expect(limited.valid && limited.status != .complete)
    }
    @Test(arguments: ["schemaOffset", "dataOffset", "dataCellOffset"])
    func transportRejectsWrongDiffSelection(_ mismatch: String) async throws {
        let isSchema = mismatch == "schemaOffset"
        let payload = try JSONEncoder().encode(ComparisonTextDiffTestFixtures.diff()).base64EncodedString()
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json,sys,base64
        def read(): return json.loads(sys.stdin.readline())
        def send(x): print(json.dumps(x),flush=True)
        c=read();send({'type':'hello.ack','requestId':c['requestId'],'protocolVersion':5,'capabilities':['schemaComparisonV1','dataComparisonV1']})
        c=read();key='schemaComparison' if c['type']=='schema.diff' else 'dataComparison';r=c[key]
        out={'jobId':r['jobId'],'state':'completed','offset':0 if '\(mismatch)'=='dataCellOffset' else 1,'diff':json.loads(base64.b64decode('\(payload)'))}
        if key=='dataComparison': out['cellOffset']=2 if '\(mismatch)'=='dataCellOffset' else 1
        send({'type':c['type']+'.result','requestId':c['requestId'],key:out});sys.stdin.readline()
        """])
        try await client.start()
        await #expect(throws: BackendTransportError.self) {
            if isSchema { _ = try await client.request(.compareSchema("diff", .init(jobId: "schema-job", offset: 0))) }
            else { _ = try await client.request(.compareData("diff", .init(jobId: "data-job", offset: 0, cellOffset: 1))) }
        }
        _ = await client.shutdown()
    }
}

private actor SchemaDiffTestBackend: SchemaComparisonBackend {
    let base: SchemaComparisonTestBackend
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var requested = false
    init() throws { base = try SchemaComparisonTestBackend() }
    func start(_ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse { try await base.start(request) }
    func request(_ operation: String, _ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse {
        if operation != "diff" { return try await base.request(operation, request) }
        requested = true
        await withCheckedContinuation { waiting = $0 }
        return .init(jobId: request.jobId!, state: .completed, diff: try ComparisonTextDiffTestFixtures.diff(), offset: request.offset)
    }
    func release() { waiting?.resume(); waiting = nil }
    func shutdown() async { await base.shutdown() }
}

private actor DataDiffTestBackend: DataComparisonBackend {
    let base: DataComparisonTestBackend
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var requested = false
    init() throws { base = try DataComparisonTestBackend() }
    func begin(_ operation: String, _ request: DataComparisonRequest) async throws -> DataComparisonResponse { try await base.begin(operation, request) }
    func request(_ operation: String, _ request: DataComparisonRequest) async throws -> DataComparisonResponse {
        if operation != "diff" { return try await base.request(operation, request) }
        if request.cellOffset == 0 {
            requested = true
            await withCheckedContinuation { waiting = $0 }
        }
        var diff = try ComparisonTextDiffTestFixtures.diff()
        diff.source.totalBytes = 100 + Int64(request.cellOffset!)
        return .init(jobId: request.jobId!, state: .completed, diff: diff, offset: request.offset, cellOffset: request.cellOffset)
    }
    func release() { waiting?.resume(); waiting = nil }
    func shutdown() async { await base.shutdown() }
}

@MainActor
struct ComparisonTextDiffModelTests {
    @Test func closingSchemaComparisonDiscardsPendingDiff() async throws {
        let profiles = SchemaComparisonTestFixtures.profiles(), backend = try SchemaDiffTestBackend()
        let model = SchemaComparisonModel(profiles: profiles, resolve: { $0.settings(password: "") }, factory: { backend })
        model.sourceID = profiles[0].id; model.targetID = profiles[1].id
        await model.start(); try await DataComparisonTestFixtures.wait { model.page != nil }
        let difference = try #require(model.page?.differences.first)
        let request = Task { await model.inspectDifference(difference) }
        for _ in 0..<100 { if await backend.requested { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.isLoadingDiff && model.selectedDifference == difference)
        await model.close(); await backend.release(); await request.value
        #expect(model.diff == nil && model.selectedDifference == nil && !model.isLoadingDiff && model.diffError == nil)
    }
    @Test func latestDataCellWinsAndRowSelectionInvalidatesDiff() async throws {
        let profiles = DataComparisonTestFixtures.profiles(), backend = try DataDiffTestBackend()
        let model = DataComparisonModel(profiles: profiles, resolve: { profile, _ in profile.settings(password: "") }, factory: { backend })
        DataComparisonTestFixtures.configure(model, profiles)
        await model.readMetadata(); try await DataComparisonTestFixtures.wait { model.descriptors != nil && !model.isWorking }
        model.mappings[0].key = true; model.sourceLimit = 3; model.targetLimit = 3
        await model.compare(); try await DataComparisonTestFixtures.wait { model.page != nil }
        let row = try #require(model.selectedRow)
        let request = Task { await model.inspectCell(row.cells[0]) }
        for _ in 0..<100 { if await backend.requested { break }; try await Task.sleep(for: .milliseconds(5)) }
        await model.inspect(try #require(row.cells[1].left), title: "Previous exact value")
        #expect(model.selectedValue != nil && model.valueChunk != nil)
        await model.inspectCell(row.cells[1])
        #expect(model.selectedValue == nil && model.valueChunk == nil && !model.isLoadingValue)
        #expect(model.selectedCell?.mapping == 1 && model.diff?.source.totalBytes == 101)
        await backend.release(); await request.value
        #expect(model.selectedCell?.mapping == 1 && model.diff?.source.totalBytes == 101 && !model.isLoadingDiff)
        model.selectRow(row)
        #expect(model.diff == nil && model.selectedCell == nil)
        await model.close()
    }
}
