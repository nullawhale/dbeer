import Darwin
import Foundation
import Testing
@testable import DBeer

enum SchemaBundleFixtures {
    struct Payload: Decodable { var file: SchemaBundleFile; var dataBase64: String; var data: Data { Data(base64Encoded: dataBase64)! } }
    struct Wire: Decodable { var version: Int; var capability: String; var commands: [BackendCommand]; var responses: [BackendMessage]; var files: [Payload] }
    static func wire() throws -> Wire {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Wire.self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/schema-bundle-v1.json")))
    }
    static func summary() throws -> SchemaBundleSummary { let fixture = try wire(); return try #require(fixture.responses[1].schemaComparison?.bundleSummary) }
    static func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("dbeer-bundle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    static func file(_ name: String, _ bytes: String = "fixture\n") -> (SchemaBundleFile, Data) {
        let data = Data(bytes.utf8)
        return (.init(id: name, path: name, bytes: Int64(data.count), sha256: SchemaBundleManifest.digest(data)), data)
    }
}
struct SchemaBundleProtocolTests {
    @Test func sharedCommandsResponsesAndPortableManifest() throws {
        let fixture = try SchemaBundleFixtures.wire()
        #expect(fixture.version == BackendProtocol.version && fixture.capability == "schemaBundleV1")
        #expect(fixture.commands.count == 5 && fixture.responses.count == 5)
        for command in fixture.commands { #expect(command.schemaComparison?.valid(for: command.type) == true); #expect(command.terminalType == command.type + ".result") }
        for response in fixture.responses {
            try response.validate()
            let bytes = try JSONEncoder().encode(response)
            let decoded = try NDJSONFramer.decode(bytes)
            let matches = decoded == response
            #expect(matches)
        }
        let summary = try SchemaBundleFixtures.summary(), manifestData = try #require(fixture.files.first { $0.file.id == "manifest" }?.data)
        let manifest = try SchemaBundleManifest.parse(manifestData, summary: summary)
        #expect(manifest.objects.count == 2 && summary.included == 1 && summary.omitted == 1)
        #expect(manifest.objects.contains { $0.ref.name.utf8.elementsEqual("Exact_é".utf8) })
        for payload in fixture.files { #expect(SchemaBundleManifest.digest(payload.data) == payload.file.sha256 && Int64(payload.data.count) == payload.file.bytes) }
        #expect(SchemaBundleManifest.schemasValid(["é", "e\u{301}"], engine: "postgresql"))
        let duplicateRequest = SchemaComparisonRequest(source: fixture.commands[0].schemaComparison?.source, schemas: ["public", "public"])
        #expect(!duplicateRequest.valid(for: "schema.bundle.start"))
        #expect(!SchemaComparisonRequest(jobId: "bundle-job", valueRef: "../capture").valid(for: "schema.bundle.export"))
        #expect(!SchemaComparisonRequest(jobId: "bundle-job", maxBytes: 0, valueRef: "manifest").valid(for: "schema.bundle.export"))
    }
    @Test func strictOriginalWireRejectsUnknownDuplicateNullFractionAndOverflow() throws {
        let fixture = try SchemaBundleFixtures.wire()
        let frame = String(decoding: try JSONEncoder().encode(fixture.responses[1]), as: UTF8.self)
        for bad in [
            frame.replacingOccurrences(of: "\"bundleSummary\":{", with: "\"bundleSummary\":{\"foreign\":1,"),
            frame.replacingOccurrences(of: "\"included\":1", with: "\"included\":1,\"included\":2"),
            frame.replacingOccurrences(of: "\"included\":1", with: "\"included\":null"),
            frame.replacingOccurrences(of: "\"included\":1", with: "\"included\":1.0"),
            frame.replacingOccurrences(of: "\"included\":1", with: "\"included\":9223372036854775808")
        ] { #expect(throws: (any Error).self) { _ = try NDJSONFramer.decode(Data(bad.utf8)) } }
    }
    @Test func manifestWhitelistRejectsTraversalCollisionsUnknownFieldsAndFalseCounts() throws {
        let wire = try SchemaBundleFixtures.wire(), original = try #require(wire.files.first { $0.file.id == "manifest" }?.data)
        for mutation in ["traversal", "collision", "unknown", "dependency", "count", "quota"] {
            var root = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
            var objects = try #require(root["objects"] as? [[String: Any]])
            var file = try #require(objects[0]["file"] as? [String: Any])
            if mutation == "traversal" { file["path"] = "../escape.sql" }
            if mutation == "collision" { file["id"] = (objects[1]["file"] as? [String: Any])?["id"]; file["path"] = (objects[1]["file"] as? [String: Any])?["path"] }
            if mutation == "unknown" { file["other"] = true }
            if mutation == "quota" { file["bytes"] = 134_217_729 }
            if mutation == "dependency" { objects[1]["dependencies"] = [["ref": ["kind": "type", "schema": "public", "name": "missing"], "state": "included"]] }
            objects[0]["file"] = file; root["objects"] = objects
            let bytes = try JSONSerialization.data(withJSONObject: root, options: .sortedKeys)
            var summary = try SchemaBundleFixtures.summary(); summary.totalBytes += Int64(bytes.count) - summary.manifest.bytes
            summary.manifest.bytes = Int64(bytes.count); summary.manifest.sha256 = SchemaBundleManifest.digest(bytes)
            if mutation == "count" { summary.included += 1 }
            #expect(throws: (any Error).self) { _ = try SchemaBundleManifest.parse(bytes, summary: summary) }
        }
    }
    @Test func transportCorrelatesBundleFileReference() async throws {
        let client = BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
        import json,sys
        def send(x): print(json.dumps(x),flush=True)
        c=json.loads(sys.stdin.readline());send({'type':'hello.ack','requestId':c['requestId'],'protocolVersion':6,'capabilities':['schemaBundleV1']})
        c=json.loads(sys.stdin.readline());send({'type':'schema.bundle.export.result','requestId':c['requestId'],'schemaComparison':{'jobId':'job','state':'completed','export':{'valueRef':'capture','sha256':'a'*64,'totalBytes':0,'offset':0,'nextOffset':0,'dataBase64':'','hasMore':False}}})
        sys.stdin.readline()
        """])
        try await client.start()
        await #expect(throws: BackendTransportError.self) { _ = try await client.request(.compareSchema("bundle.export", .init(jobId: "job", valueRef: "manifest"))) }
        _ = await client.shutdown()
    }
}

@MainActor
struct SchemaBundlePublicationTests {
    @Test func privateFilesPublishAtomicallyWithoutOverwrite() async throws {
        let root = try SchemaBundleFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("bundle"), (file, bytes) = SchemaBundleFixtures.file("capture.json")
        do {
            let publication = try SchemaBundleDirectory(destination: destination)
            try publication.begin(file); try publication.append(bytes.prefix(3), to: file)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            try publication.append(bytes.dropFirst(3), to: file); try publication.finish(file)
            try await publication.publish(expectedFiles: [file])
        }
        #expect(try Data(contentsOf: destination.appendingPathComponent(file.path)) == bytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path), fileAttributes = try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent(file.path).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 && (fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(throws: SchemaBundleFailure.self) { _ = try SchemaBundleDirectory(destination: destination) }
        #expect(try Data(contentsOf: destination.appendingPathComponent(file.path)) == bytes)
    }
    @Test func failedChecksumOrPublicationLeavesNoPartialDestination() async throws {
        let root = try SchemaBundleFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (file, bytes) = SchemaBundleFixtures.file("capture.json")
        for badChecksum in [false, true] {
            let destination = root.appendingPathComponent(UUID().uuidString)
            do {
                let publication = try SchemaBundleDirectory(destination: destination)
                try publication.begin(file); try publication.append(badChecksum ? Data(repeating: 120, count: bytes.count) : bytes, to: file)
                if badChecksum { #expect(throws: SchemaBundleFailure.self) { try publication.finish(file) } }
                else {
                    try publication.finish(file)
                    await #expect(throws: SchemaBundleFailure.self) { try await publication.publish(expectedFiles: [file], hook: { stage in if stage == .willPublish { throw SchemaBundleFailure.write } }) }
                }
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
    @Test func foreignDestinationAndParentReplacementArePreserved() async throws {
        let root = try SchemaBundleFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (file, bytes) = SchemaBundleFixtures.file("capture.json")
        let parent = root.appendingPathComponent("parent"), moved = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let destination = parent.appendingPathComponent("bundle")
        do {
            let publication = try SchemaBundleDirectory(destination: destination)
            try publication.begin(file); try publication.append(bytes, to: file); try publication.finish(file)
            await #expect(throws: SchemaBundleFailure.self) {
                try await publication.publish(expectedFiles: [file], hook: { stage in
                    guard stage == .willPublish else { return }
                    try FileManager.default.moveItem(at: parent, to: moved)
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
                    try Data("foreign".utf8).write(to: destination)
                })
            }
        }
        #expect(try Data(contentsOf: destination) == Data("foreign".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
    }
    @Test func sameInodeMutationAndLateStaleContextRollBack() async throws {
        let root = try SchemaBundleFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (file, bytes) = SchemaBundleFixtures.file("capture.json")
        for stale in [false, true] {
            let destination = root.appendingPathComponent(UUID().uuidString)
            var current = true
            do {
                let publication = try SchemaBundleDirectory(destination: destination)
                try publication.begin(file); try publication.append(bytes, to: file); try publication.finish(file)
                await #expect(throws: SchemaBundleFailure.self) {
                    try await publication.publish(expectedFiles: [file], isCurrent: { current }, hook: { stage in
                        if stale && stage == .didPublish { current = false }
                        else if !stale && stage == .willPublish {
                            let temporary = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".dbeer-schema-") })
                            try Data(repeating: 120, count: bytes.count).write(to: temporary.appendingPathComponent(file.path))
                        }
                    })
                }
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }
    @Test func unexpectedFileIsNotPublishedOrDeleted() async throws {
        let root = try SchemaBundleFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("bundle"), (file, bytes) = SchemaBundleFixtures.file("capture.json")
        let publication = try SchemaBundleDirectory(destination: destination)
        try publication.begin(file); try publication.append(bytes, to: file); try publication.finish(file)
        await #expect(throws: SchemaBundleFailure.self) {
            try await publication.publish(expectedFiles: [file], hook: { stage in
                if stage == .willPublish {
                    let temporary = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".dbeer-schema-") })
                    try Data("foreign".utf8).write(to: temporary.appendingPathComponent("foreign.sql"))
                }
            })
        }
        await publication.finishOwnership()
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let temporary = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        #expect(try Data(contentsOf: temporary.appendingPathComponent("foreign.sql")) == Data("foreign".utf8))
    }
    @Test func lateForeignReplacementIsPreserved() async throws {
        let root = try SchemaBundleFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("bundle"), (file, bytes) = SchemaBundleFixtures.file("capture.json")
        do {
            let publication = try SchemaBundleDirectory(destination: destination)
            try publication.begin(file); try publication.append(bytes, to: file); try publication.finish(file)
            await #expect(throws: SchemaBundleFailure.self) {
                try await publication.publish(expectedFiles: [file], hook: { stage in
                    if stage == .didPublish {
                        try FileManager.default.moveItem(at: destination, to: root.appendingPathComponent("retained-original"))
                        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                        try Data("foreign".utf8).write(to: destination.appendingPathComponent("foreign"))
                    }
                })
            }
        }
        #expect(try Data(contentsOf: destination.appendingPathComponent("foreign")) == Data("foreign".utf8))
    }
}

actor SchemaBundleTestBackend: SchemaComparisonBackend {
    let fixture: SchemaBundleFixtures.Wire
    private let chunkBytes: Int
    var starts: [SchemaComparisonRequest] = []
    var operations: [String] = []
    var running = false
    var corrupt = false
    var pause = false
    var paused = false
    private var gate: CheckedContinuation<Void, Never>?
    init(running: Bool = false, corrupt: Bool = false, pause: Bool = false, largeCapture: Bool = false) throws {
        fixture = try (largeCapture ? SchemaBundleFixtures.largeCapture() : SchemaBundleFixtures.wire())
        chunkBytes = largeCapture ? 65_536 : 17
        self.running = running; self.corrupt = corrupt; self.pause = pause
    }
    func start(_ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse { starts.append(request); return fixture.responses[0].schemaComparison! }
    func request(_ operation: String, _ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse {
        operations.append(operation)
        if operation == "status" { return running ? .init(jobId: "bundle-job", state: .running) : fixture.responses[1].schemaComparison! }
        if operation == "export" {
            if pause { pause = false; paused = true; await withCheckedContinuation { gate = $0 } }
            let payload = try #require(fixture.files.first { $0.file.id == request.valueRef })
            let offset = Int(request.offset ?? 0), end = min(payload.data.count, offset + min(request.maxBytes ?? 65_536, chunkBytes))
            var bytes = payload.data[offset..<end]
            if corrupt, !bytes.isEmpty { bytes[bytes.startIndex] ^= 1 }
            return .init(jobId: "bundle-job", state: .completed, export: .init(valueRef: payload.file.id, sha256: payload.file.sha256, totalBytes: payload.file.bytes,
                offset: Int64(offset), nextOffset: Int64(end), dataBase64: bytes.base64EncodedString(), hasMore: end < payload.data.count))
        }
        return fixture.responses[operation == "cancel" ? 3 : 4].schemaComparison!
    }
    func resume() { gate?.resume(); gate = nil }
    func shutdown() async { operations.append("shutdown") }
}
@MainActor
struct SchemaBundleModelTests {
    func waitReady(_ model: SchemaBundleModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while model.summary == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.phase == .completed && model.summary != nil)
    }
    @Test func explicitCaptureExportsExactVerifiedFilesAndClosesOwner() async throws {
        let profile = SchemaComparisonTestFixtures.profiles()[0], backend = try SchemaBundleTestBackend()
        var resolutions = 0, factories = 0, allowed = true
        let model = SchemaBundleModel(profile: profile, resolve: { profile, _ in resolutions += 1; return profile.settings(password: "") },
            startAllowed: { allowed }, factory: { _ in factories += 1; return backend })
        #expect(model.canStart && resolutions == 0 && factories == 0)
        await model.close(); #expect(factories == 0)
        await model.start(); try await waitReady(model)
        let starts = await backend.starts
        #expect(resolutions == 1 && factories == 1 && starts.count == 1 && starts[0].target == nil && starts[0].mappings == nil && starts[0].source?.connection?.policy.readOnly == true)
        // An unrelated close prompt disables new starts, but not the active owner.
        allowed = false; #expect(model.canExport)
        let root = try SchemaBundleFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("bundle")
        await model.export(to: destination)
        #expect(model.exported && !model.isExporting)
        for payload in try SchemaBundleFixtures.wire().files { #expect(try Data(contentsOf: destination.appendingPathComponent(payload.file.path)) == payload.data) }
        await model.close(); #expect(await backend.operations.contains("close"))
    }
    @Test func badChecksumNeverPublishesDirectory() async throws {
        let profile = SchemaComparisonTestFixtures.profiles()[0], backend = try SchemaBundleTestBackend(corrupt: true)
        let model = SchemaBundleModel(profile: profile, resolve: { profile, _ in profile.settings(password: "") }, factory: { _ in backend })
        await model.start(); try await waitReady(model)
        let root = try SchemaBundleFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("bundle")
        await model.export(to: destination)
        #expect(!model.exported && model.error != nil && !FileManager.default.fileExists(atPath: destination.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        await model.close()
    }
    @Test func changedSourceAndStopDiscardLateDownloads() async throws {
        for stop in [false, true] {
            let profile = SchemaComparisonTestFixtures.profiles()[0], backend = try SchemaBundleTestBackend(pause: true)
            var current = true
            let model = SchemaBundleModel(profile: profile, resolve: { profile, _ in profile.settings(password: "") }, current: { current }, factory: { _ in backend })
            await model.start(); try await waitReady(model)
            let root = try SchemaBundleFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let destination = root.appendingPathComponent("bundle")
            let export = Task { await model.export(to: destination) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !(await backend.paused), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            if stop { await model.stop() } else { current = false }
            await backend.resume(); await export.value
            #expect(!model.exported && !FileManager.default.fileExists(atPath: destination.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
            await model.close()
        }
    }
    @Test func captureStopRetiresDedicatedJobAndUnusedCloseNeverStartsHelper() async throws {
        let backend = try SchemaBundleTestBackend(running: true), profile = SchemaComparisonTestFixtures.profiles()[0]
        var factories = 0
        let model = SchemaBundleModel(profile: profile, resolve: { profile, _ in profile.settings(password: "") }, factory: { _ in factories += 1; return backend })
        await model.close(); #expect(factories == 0)
        await model.start(); await model.stop()
        #expect(factories == 1 && model.phase == .cancelled && !model.canExport)
        let operations = await backend.operations
        #expect(operations.contains("cancel") && operations.contains("shutdown"))
    }
}


extension SchemaBundleFixtures {
    static func largeCapture() throws -> Wire {
        var fixture = try wire()
        let captureIndex = try #require(fixture.files.firstIndex { $0.file.id == "capture" })
        let manifestIndex = try #require(fixture.files.firstIndex { $0.file.id == "manifest" })
        let oldBytes = fixture.files[captureIndex].file.bytes + fixture.files[manifestIndex].file.bytes
        let issue: [String: Any] = ["index": 0, "side": "source", "property": "fixture", "code": "verificationFixture", "message": String(repeating: "x", count: 160_000), "blocksEquality": false, "planning": "manual"]
        var capture = try #require(JSONSerialization.jsonObject(with: fixture.files[captureIndex].data) as? [String: Any])
        capture["issues"] = [issue]
        let captureData = try JSONSerialization.data(withJSONObject: capture, options: .sortedKeys)
        fixture.files[captureIndex].file.bytes = Int64(captureData.count)
        fixture.files[captureIndex].file.sha256 = SchemaBundleManifest.digest(captureData)
        fixture.files[captureIndex].dataBase64 = captureData.base64EncodedString()
        var manifest = try #require(JSONSerialization.jsonObject(with: fixture.files[manifestIndex].data) as? [String: Any])
        manifest["capture"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.files[captureIndex].file))
        manifest["issues"] = [issue]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: .sortedKeys)
        fixture.files[manifestIndex].file.bytes = Int64(manifestData.count)
        fixture.files[manifestIndex].file.sha256 = SchemaBundleManifest.digest(manifestData)
        fixture.files[manifestIndex].dataBase64 = manifestData.base64EncodedString()
        var summary = try #require(fixture.responses[1].schemaComparison?.bundleSummary)
        summary.manifest = fixture.files[manifestIndex].file
        summary.totalBytes += fixture.files[captureIndex].file.bytes + fixture.files[manifestIndex].file.bytes - oldBytes
        fixture.responses[1].schemaComparison?.bundleSummary = summary
        return fixture
    }
}
actor SchemaBundleVerificationGate {
    let phase: SchemaBundleVerificationPhase
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var paused = false
    private(set) var background = false
    init(phase: SchemaBundleVerificationPhase) { self.phase = phase }
    func observe(_ progress: SchemaBundleVerificationProgress) async {
        guard !paused, progress.phase == phase, progress.fileID == "capture", progress.offset == 65_536 else { return }
        paused = true; background = !progress.workerIsMainThread
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor
struct SchemaBundleVerificationCancellationTests {
    @Test func stopAfterAcknowledgedCommitKeepsConfirmedFiles() async throws {
        let profile = SchemaComparisonTestFixtures.profiles()[0], backend = try SchemaBundleTestBackend()
        let model = SchemaBundleModel(profile: profile, resolve: { profile, _ in profile.settings(password: "") }, factory: { _ in backend })
        await model.start(); try await SchemaBundleModelTests().waitReady(model)
        let root = try SchemaBundleFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("bundle")
        await model.export(to: destination)
        let acknowledged = model.exported
        try #require(acknowledged)
        await model.stop()
        #expect(model.exported && FileManager.default.fileExists(atPath: destination.appendingPathComponent("manifest.json").path))
        await model.close()
    }
    @Test func stopDuringPostVerificationPreservesForeignReplacement() async throws {
        let profile = SchemaComparisonTestFixtures.profiles()[0], backend = try SchemaBundleTestBackend(largeCapture: true)
        let model = SchemaBundleModel(profile: profile, resolve: { profile, _ in profile.settings(password: "") }, factory: { _ in backend })
        await model.start(); try await SchemaBundleModelTests().waitReady(model)
        let root = try SchemaBundleFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("bundle"), original = root.appendingPathComponent("owned-original")
        let gate = SchemaBundleVerificationGate(phase: .afterPublish)
        let export = Task { await model.export(to: destination, verificationHook: { await gate.observe($0) }) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await gate.paused), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let paused = await gate.paused; try #require(paused)
        try FileManager.default.moveItem(at: destination, to: original)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try Data("foreign".utf8).write(to: destination.appendingPathComponent("foreign"))
        await model.stop(); await gate.release(); await export.value
        #expect(!model.exported)
        #expect(try Data(contentsOf: destination.appendingPathComponent("foreign")) == Data("foreign".utf8))
        await model.close()
    }
    @Test func stopCloseAndChangedProfileRejectPausedFinalVerification() async throws {
        for phase in [SchemaBundleVerificationPhase.beforePublish, .afterPublish] {
            for reason in ["stop", "close", "profile"] {
                let profile = SchemaComparisonTestFixtures.profiles()[0], backend = try SchemaBundleTestBackend(largeCapture: true)
                var current = true
                let model = SchemaBundleModel(profile: profile, resolve: { profile, _ in profile.settings(password: "") }, current: { current }, factory: { _ in backend })
                await model.start(); try await SchemaBundleModelTests().waitReady(model)
                let root = try SchemaBundleFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
                let destination = root.appendingPathComponent("bundle")
                let gate = SchemaBundleVerificationGate(phase: phase)
                let export = Task { await model.export(to: destination, verificationHook: { await gate.observe($0) }) }
                let deadline = ContinuousClock.now.advanced(by: .seconds(4))
                while !(await gate.paused), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
                let paused = await gate.paused, background = await gate.background
                try #require(paused); #expect(background)
                #expect(FileManager.default.fileExists(atPath: destination.path) == (phase == .afterPublish))
                if reason == "stop" { await model.stop(); #expect(!model.isExporting) }
                else if reason == "close" { await model.close(); #expect(!model.isExporting) }
                else { current = false }
                #expect(!model.exported)
                await gate.release(); await export.value
                #expect(!model.exported && !FileManager.default.fileExists(atPath: destination.path))
                #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
                await model.close()
            }
        }
    }
}
