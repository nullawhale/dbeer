import Foundation
import Testing
@testable import DBeer

/// Process and filesystem tests only; CSV inference never opens a database.
struct StandaloneOperationHelperTests {
    private struct Fixture: Sendable {
        let directory: URL
        let helper: StandaloneOperationHelper

        func release(_ name: String) throws { try Data().write(to: directory.appendingPathComponent(name)) }
        func finish() async {
            try? release("release-hello")
            try? release("release-shutdown")
            await helper.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
        func ownedDirectories() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
                .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
        }
    }
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func fixture(_ feature: StandaloneOperationHelper.Feature, gated: Bool = false,
                         missing: Bool = false) throws -> Fixture {
        let directory = repository.appendingPathComponent("build/standalone-helper-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = missing ? directory.appendingPathComponent("missing-helper") : gated
            ? URL(fileURLWithPath: "/usr/bin/python3") : repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let arguments = gated ? ["-u", "-c", """
        import json, pathlib, sys, time
        root = pathlib.Path(sys.argv[1])
        def wait(name):
            while not (root / name).exists():
                time.sleep(0.001)
        def send(message):
            print(json.dumps(message), flush=True)
        command = json.loads(sys.stdin.readline())
        (root / 'hello-received').touch()
        wait('release-hello')
        send({'type':'hello.ack', 'requestId':command['requestId'], 'protocolVersion':6,
              'capabilities':['dataTransferV1', 'databaseToolsV1']})
        command = json.loads(sys.stdin.readline())
        if command['type'] != 'shutdown':
            (root / 'unexpected-command').touch()
            sys.exit(2)
        (root / 'shutdown-received').touch()
        wait('release-shutdown')
        send({'type':'shutdown.ack', 'requestId':command['requestId']})
        """, directory.path] : []
        return Fixture(directory: directory, helper: StandaloneOperationHelper(feature: feature,
            executableURL: executable, arguments: arguments, scratchParentURL: directory))
    }
    private func waitFor(_ file: URL) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: file.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(FileManager.default.fileExists(atPath: file.path), "The synthetic helper did not reach its lifecycle gate.")
    }
    private func closeChecks(_ fixture: Fixture, owned: URL) -> [Task<Bool, Never>] {
        (0..<3).map { _ in Task {
            await fixture.helper.shutdown()
            return !FileManager.default.fileExists(atPath: owned.path)
        } }
    }

    @Test(arguments: StandaloneOperationHelper.Feature.allCases)
    func coalescedStartupAndConcurrentShutdownAwaitChildCleanup(_ feature: StandaloneOperationHelper.Feature) async throws {
        let fixture = try fixture(feature, gated: true)
        do {
            #expect(try fixture.ownedDirectories().isEmpty)
            try fixture.release("release-hello")
            async let first: Void = fixture.helper.prepare(connections: [])
            async let second: Void = fixture.helper.prepare(connections: [])
            async let third: Void = fixture.helper.prepare(connections: [])
            _ = try await (first, second, third)
            let owned = try #require(try fixture.ownedDirectories().only)
            let permissions = try FileManager.default.attributesOfItem(atPath: owned.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o700)
            let closing = closeChecks(fixture, owned: owned)
            try await waitFor(fixture.directory.appendingPathComponent("shutdown-received"))
            #expect(FileManager.default.fileExists(atPath: owned.path))
            try fixture.release("release-shutdown")
            for task in closing { #expect(await task.value) }
            #expect(try fixture.ownedDirectories().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("unexpected-command").path))
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    @Test(arguments: StandaloneOperationHelper.Feature.allCases)
    func shutdownDuringHandshakePreventsRequestsAndWaitsForStartup(_ feature: StandaloneOperationHelper.Feature) async throws {
        let fixture = try fixture(feature, gated: true)
        do {
            let preparing = Task { try await fixture.helper.prepare(connections: []) }
            try await waitFor(fixture.directory.appendingPathComponent("hello-received"))
            let owned = try #require(try fixture.ownedDirectories().only)
            let closing = closeChecks(fixture, owned: owned)
            var closed = false
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !closed && ContinuousClock.now < deadline {
                do {
                    _ = try await fixture.helper.request(.dataTransfer("status", .init(jobId: "unused-job")))
                } catch is CancellationError { closed = true }
                catch { try await Task.sleep(for: .milliseconds(2)) }
            }
            try #require(closed)
            try fixture.release("release-hello")
            do {
                try await preparing.value
                Issue.record("A closing helper must not finish preparation successfully.")
            } catch is CancellationError { }
            try await waitFor(fixture.directory.appendingPathComponent("shutdown-received"))
            try fixture.release("release-shutdown")
            for task in closing { #expect(await task.value) }
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("unexpected-command").path))
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    @Test(arguments: StandaloneOperationHelper.Feature.allCases)
    func shutdownBeforePreparationDoesNotCreateScratchOrStartProcess(_ feature: StandaloneOperationHelper.Feature) async throws {
        let fixture = try fixture(feature, missing: true)
        do {
            async let first: Void = fixture.helper.shutdown()
            async let second: Void = fixture.helper.shutdown()
            _ = await (first, second)
            do {
                try await fixture.helper.prepare(connections: [])
                Issue.record("A closed helper must reject preparation.")
            } catch is CancellationError { }
            #expect(try fixture.ownedDirectories().isEmpty)
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    @Test(arguments: StandaloneOperationHelper.Feature.allCases)
    func failedStartupIsNotRetriedAndConcurrentCloseRemovesScratch(_ feature: StandaloneOperationHelper.Feature) async throws {
        let fixture = try fixture(feature, missing: true)
        do {
            for _ in 0..<2 {
                await #expect(throws: BackendTransportError(.missingExecutable)) {
                    try await fixture.helper.prepare(connections: [])
                }
                #expect(try fixture.ownedDirectories().count == 1)
            }
            let owned = try #require(try fixture.ownedDirectories().only)
            for task in closeChecks(fixture, owned: owned) { #expect(await task.value) }
            #expect(try fixture.ownedDirectories().isEmpty)
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }

    @Test func realHelperDescribesConcurrentCSVInputsWithoutConnectingToDatabase() async throws {
        let fixture = try fixture(.dataTransfer)
        do {
            let endpoint = DataTransferEndpoint(connection: .init(host: "fixture.invalid", port: 1,
                database: "fixture", user: "reader", password: "", sslMode: "disable"), schema: "public", table: "inferred")
            let request = DataTransferRequest(mode: "csv", target: endpoint, headers: ["id", "name"],
                rows: [[.init(kind: "text", value: "1"), .init(kind: "text", value: "alpha")]])
            func describe() async throws -> DataTransferReply {
                try await fixture.helper.prepare(connections: request.transportConnections)
                var reply = try #require(try await fixture.helper.request(.dataTransfer("describe", request)).transfer)
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while ["pending", "running"].contains(reply.state), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(2))
                    reply = try #require(try await fixture.helper.request(.dataTransfer("status", .init(jobId: reply.jobId))).transfer)
                }
                return reply
            }
            async let first = describe()
            async let second = describe()
            let replies = try await [first, second]
            #expect(Set(replies.map(\.jobId)).count == 2)
            for reply in replies {
                #expect(reply.valid && reply.state == "described")
                #expect(reply.columns?.map(\.name) == ["id", "name"])
                #expect(reply.columns?.map(\.type) == ["integer", "text"])
                #expect(reply.sql == nil && !reply.tableCreated && !reply.outcomeUnknown)
            }
            let owned = try #require(try fixture.ownedDirectories().only)
            let roots = try FileManager.default.contentsOfDirectory(atPath: owned.path)
            #expect(roots.contains { $0.hasPrefix("dbeer-transfer-") })
            #expect(roots.contains { $0.hasPrefix("dbeer-dbtools-") })
            for task in closeChecks(fixture, owned: owned) { #expect(await task.value) }
            #expect(try fixture.ownedDirectories().isEmpty)
        } catch { await fixture.finish(); throw error }
        await fixture.finish()
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
