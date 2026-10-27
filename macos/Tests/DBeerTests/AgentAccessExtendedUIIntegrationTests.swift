import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import DBeer

private enum R04ExtendedMCPJSON: Codable, Sendable {
    case object([String: R04ExtendedMCPJSON]), array([R04ExtendedMCPJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if try value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode([R04ExtendedMCPJSON].self) { self = .array(item) }
        else { self = .object(try value.decode([String: R04ExtendedMCPJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }
    subscript(_ key: String) -> Self? { if case .object(let value) = self { value[key] } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var array: [Self]? { if case .array(let value) = self { value } else { nil } }
    var flag: Bool { if case .bool(let value) = self { value } else { false } }
}

private enum R04ExtendedMCPFailure: Error { case transport, timeout, invalid, database, configuration }

/// Foundation's counted pipe read may wait for the entire count. A single POSIX
/// read returns the available bytes needed for interactive JSON-RPC replies.
private func r04ExtendedMCPReadChunk(_ handle: FileHandle) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 8_192)
    while true {
        let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else { throw R04ExtendedMCPFailure.transport }
        return Data(bytes.prefix(count))
    }
}

private func r04ExtendedMCPTrace(_ stage: String) {
    FileHandle.standardError.write(Data("R04 MCP UI: \(stage)\n".utf8))
}

/// Deliberately permits a full subprocess stdout pipe without blocking test UI.
private final class R04ExtendedMCPReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    private var closed = false
    func pause() { condition.lock(); paused = true; condition.unlock() }
    func resume() { condition.lock(); paused = false; condition.broadcast(); condition.unlock() }
    func close() { condition.lock(); closed = true; condition.broadcast(); condition.unlock() }
    func wait() -> Bool {
        condition.lock(); defer { condition.unlock() }
        while paused && !closed { condition.wait() }
        return !closed
    }
}

/// A small JSON-RPC test client talks to the actual official-SDK subprocess.
/// It retains only bounded replies in memory and discards subprocess diagnostics.
private actor R04ExtendedMCPStdioClient {
    private let executable: URL
    private let name: String
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private let gate = R04ExtendedMCPReadGate()
    private var pending: [String: CheckedContinuation<R04ExtendedMCPJSON, Error>] = [:]
    private var failed = false

    init(executable: URL, name: String) { self.executable = executable; self.name = name }
    func start() async throws {
        let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.executableURL = executable; child.arguments = ["--mcp"]
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        try child.run()
        process = child; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try? stdin.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
        let source = stdout.fileHandleForReading, errors = stderr.fileHandleForReading, gate = self.gate
        DispatchQueue(label: "dbeer.r04.mcp.stderr").async {
            defer { try? errors.close() }
            while let data = try? r04ExtendedMCPReadChunk(errors), !data.isEmpty {}
        }
        DispatchQueue(label: "dbeer.r04.mcp.stdout").async { [weak self] in
            guard let self else { return }
            var buffer = Data()
            defer { Task { await self.fail() } }
            while gate.wait(), let data = try? r04ExtendedMCPReadChunk(source), !data.isEmpty {
                buffer.append(data)
                while let end = buffer.firstIndex(of: 10) {
                    guard end <= 4 * 1_024 * 1_024,
                          let reply = try? JSONDecoder().decode(R04ExtendedMCPJSON.self, from: Data(buffer[..<end])) else { return }
                    buffer.removeSubrange(...end)
                    Task { await self.receive(reply) }
                }
                if buffer.count > 4 * 1_024 * 1_024 { return }
            }
        }
        r04ExtendedMCPTrace("initialize sent")
        let initialized = try await request("initialize", params: .object([
            "protocolVersion": .string("2025-11-25"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string(name), "version": .string("1")])
        ]))
        guard initialized["result"] != nil else { throw R04ExtendedMCPFailure.invalid }
        try send(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))
        r04ExtendedMCPTrace("initialize complete")
    }
    func request(_ method: String, params: R04ExtendedMCPJSON = .object([:])) async throws -> R04ExtendedMCPJSON {
        guard !failed else { throw R04ExtendedMCPFailure.transport }
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try send(.object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": params])) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: R04ExtendedMCPFailure.transport); return }
            Task { [weak self] in
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                await self?.expire(id)
            }
        }
    }
    func tool(_ name: String, _ arguments: [String: R04ExtendedMCPJSON] = [:]) async throws -> R04ExtendedMCPJSON {
        try await request("tools/call", params: .object(["name": .string(name), "arguments": .object(arguments)]))
    }
    func pauseOutput() { gate.pause() }
    func resumeOutput() { gate.resume() }
    func stop() async {
        gate.close(); try? input?.close(); input = nil; try? output?.close(); output = nil
        fail()
        guard let process else { return }
        if process.isRunning { process.terminate() }
        for _ in 0..<20 {
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        self.process = nil
    }
    private func send(_ value: R04ExtendedMCPJSON) throws {
        guard let input else { throw R04ExtendedMCPFailure.transport }
        var data = try JSONEncoder().encode(value); data.append(10)
        try input.write(contentsOf: data)
    }
    private func receive(_ reply: R04ExtendedMCPJSON) {
        if let id = reply["id"]?.string { pending.removeValue(forKey: id)?.resume(returning: reply) }
    }
    private func expire(_ id: String) { pending.removeValue(forKey: id)?.resume(throwing: R04ExtendedMCPFailure.timeout) }
    private func fail() {
        failed = true
        let waiters = pending; pending.removeAll()
        waiters.values.forEach { $0.resume(throwing: R04ExtendedMCPFailure.transport) }
    }
}

/// Explicit opt-in acceptance of Cassandra/MongoDB MCP through the actual stdio
/// server, protected broker and production permission/confirmation/Settings UI.
@Suite(.serialized, .enabled(if:
    ProcessInfo.processInfo.environment["DBEER_R04_UI_QA"] == "1" &&
    ProcessInfo.processInfo.environment["DBEER_R04_UI_DISPOSABLE"] == "1" &&
    !(ProcessInfo.processInfo.environment["DBEER_TEST_CASSANDRA_PORT"] ?? "").isEmpty &&
    !(ProcessInfo.processInfo.environment["DBEER_TEST_MONGODB_PORT"] ?? "").isEmpty))
@MainActor
struct AgentAccessExtendedUIIntegrationTests {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    @MainActor private final class Fixture {
        let engine: DatabaseEngine
        let connection: ConnectionSettings
        let profile: SavedConnection
        let excluded: SavedConnection
        let readonly: SavedConnection
        let executable: URL
        let admin: BackendClient
        let table = "r04_ui_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let database: String
        var session: String?
        var coordinator: AgentAccessCoordinator!
        var broker: AgentSocketBroker?
        var window: NSWindow?
        var clients: [R04ExtendedMCPStdioClient] = []
        var schema: String { engine == .cassandra ? connection.database : database }
        var object: String { engine == .cassandra ? table : "items" }
        var qualified: String { schema + "." + table }

        init(engine: DatabaseEngine, executable: URL) throws {
            self.engine = engine; self.executable = executable
            let database = "r04_ui_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            self.database = database
            let environment = ProcessInfo.processInfo.environment
            let host: String
            if engine == .cassandra {
                host = environment["DBEER_TEST_CASSANDRA_HOST"] ?? "localhost"
                guard let port = Int(environment["DBEER_TEST_CASSANDRA_PORT"] ?? "") else { throw R04ExtendedMCPFailure.configuration }
                connection = ConnectionSettings(host: host, port: port,
                    database: environment["DBEER_TEST_CASSANDRA_DATABASE"] ?? "dbeer",
                    user: environment["DBEER_TEST_CASSANDRA_USER"] ?? "", password: environment["DBEER_TEST_CASSANDRA_PASSWORD"] ?? "",
                    sslMode: environment["DBEER_TEST_CASSANDRA_SSLMODE"] ?? "disable",
                    sslRootCert: environment["DBEER_TEST_CASSANDRA_CA_FILE"], engine: .cassandra,
                    policy: ExecutionPolicy(environment: .production), contactPoints: [host],
                    localDatacenter: environment["DBEER_TEST_CASSANDRA_DATACENTER"] ?? "datacenter1", consistency: "LOCAL_ONE")
            } else {
                host = environment["DBEER_TEST_MONGODB_HOST"] ?? "localhost"
                guard let port = Int(environment["DBEER_TEST_MONGODB_PORT"] ?? "") else { throw R04ExtendedMCPFailure.configuration }
                connection = ConnectionSettings(host: host, port: port, database: database,
                    user: environment["DBEER_TEST_MONGODB_USER"] ?? "", password: environment["DBEER_TEST_MONGODB_PASSWORD"] ?? "",
                    sslMode: environment["DBEER_TEST_MONGODB_SSLMODE"] ?? "disable",
                    sslRootCert: environment["DBEER_TEST_MONGODB_CA"], engine: .mongodb,
                    policy: ExecutionPolicy(environment: .production),
                    mongodb: MongoDBSettings(authSource: "admin", replicaSet: environment["DBEER_TEST_MONGODB_REPLICA_SET"] ?? "", directConnection: true))
            }
            guard ["localhost", "127.0.0.1", "::1"].contains(host) else { throw R04ExtendedMCPFailure.configuration }
            profile = SavedConnection(name: "MCP \(engine.displayName) allowed", settings: connection)
            excluded = SavedConnection(name: "MCP \(engine.displayName) excluded", settings: connection)
            var protected = connection; protected.policy.readOnly = true
            readonly = SavedConnection(name: "MCP \(engine.displayName) enforced readonly", settings: protected)
            admin = BackendClient(executableURL: executable)
            coordinator = AgentAccessCoordinator(profiles: { [unowned self] in [profile, excluded, readonly] },
                settings: { [unowned self] snapshot in snapshot.settings(password: connection.password) },
                backendFactory: { let client = BackendClient(executableURL: executable); try await client.start(); return client },
                approve: { await AgentAccessApproval.present(clientName: $0, profiles: $1) }, confirm: AgentAccessApproval.confirm)
        }
        func start() async throws {
            try await admin.start()
            session = try await admin.request(.connect(connection)).sessionId
            guard session != nil else { throw R04ExtendedMCPFailure.database }
            if engine == .cassandra {
                _ = try await execute("CREATE TABLE \(qualified) (id int PRIMARY KEY, note text)")
                _ = try await execute("INSERT INTO \(qualified) (id,note) VALUES (1,'seed')")
                _ = try await execute("INSERT INTO \(qualified) (id,note) VALUES (2,'" + String(repeating: "x", count: 300_000) + "')")
            } else {
                try await mongoScript("const fixture=db.getSiblingDB('" + database + "'); fixture.items.insertMany([{_id:1,note:'seed',exact:NumberLong('9007199254740993')},{_id:2,note:'x'.repeat(300000)}]);")
            }
            let coordinator = self.coordinator!
            let broker = AgentSocketBroker(onRequest: { [weak coordinator] id, request in
                guard let coordinator else { return AgentResponse(id: request.id, ok: false, error: "Fixture closed.") }
                return await coordinator.handle(clientID: id, request: request)
            }, onDisconnect: { [weak coordinator] id in await coordinator?.disconnect(clientID: id) })
            // Use the regular exclusive lease; never replace another application's socket.
            try broker.start(); self.broker = broker
        }
        func client() async throws -> R04ExtendedMCPStdioClient {
            let client = R04ExtendedMCPStdioClient(executable: executable, name: "R04 extended stdio UI \(engine.displayName)")
            clients.append(client); try await client.start(); return client
        }
        func execute(_ text: String) async throws -> BackendMessage {
            guard let session else { throw R04ExtendedMCPFailure.database }
            let assessed = try await admin.request(.assess(sessionId: session, operations: [OperationRequest(type: "execute", sql: text)]))
            guard let assessment = assessed.assessment, assessment.decision != "deny", let authorization = assessment.authorization else {
                throw R04ExtendedMCPFailure.database
            }
            var command = BackendCommand.execute(sessionId: session, sql: text); command.authorization = authorization
            let reply = try await admin.request(command)
            guard reply.type == "query.result" else { throw R04ExtendedMCPFailure.database }
            return reply
        }
        private func mongoScript(_ script: String) async throws {
            let environment = ProcessInfo.processInfo.environment
            guard environment["DBEER_REQUIRE_MONGODB"] == "1", let container = environment["DBEER_TEST_MONGODB_CONTAINER"],
                  (12...64).contains(container.count), container.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw R04ExtendedMCPFailure.configuration
            }
            let tls = environment["DBEER_TEST_MONGODB_SSLMODE"] == "verify-full"
            let shell = "if [ -n \"${MONGO_INITDB_ROOT_USERNAME:-}\" ]; then exec mongosh --quiet --host localhost --username \"$MONGO_INITDB_ROOT_USERNAME\" --password \"$MONGO_INITDB_ROOT_PASSWORD\" --authenticationDatabase admin \"$@\" --file /dev/stdin; else exec mongosh --quiet --host localhost \"$@\" --file /dev/stdin; fi"
            try await Task.detached {
                let child = Process(), input = Pipe()
                child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                child.arguments = ["docker", "exec", "-i", container, "sh", "-c", shell, "r04-ui"] +
                    (tls ? ["--tls", "--tlsCAFile", "/fixture/ca.crt"] : [])
                child.standardInput = input; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
                try child.run(); try? input.fileHandleForReading.close()
                try input.fileHandleForWriting.write(contentsOf: Data(script.utf8)); try input.fileHandleForWriting.close()
                child.waitUntilExit()
                guard child.terminationStatus == 0 else { throw R04ExtendedMCPFailure.database }
            }.value
        }
        func queryArguments(_ text: String, id: String = UUID().uuidString, rows: Int = 100,
                            profileID: UUID? = nil) -> [String: R04ExtendedMCPJSON] {
            ["profileId": .string((profileID ?? profile.id).uuidString), "queryId": .string(id), "sql": .string(text),
             "maxRows": .number(Double(rows)), "timeoutSeconds": .number(20)]
        }
        func readText(approved: Bool = false) -> String {
            engine == .cassandra ? "SELECT id,note FROM \(qualified) WHERE id=1" :
                "{\"collection\":\"" + (approved ? "approved_output" : "items") + "\",\"find\":{\"_id\":1}}"
        }
        func writeText() -> String {
            engine == .cassandra ? "UPDATE \(qualified) SET note='approved' WHERE id=1" :
                "{\"collection\":\"items\",\"aggregate\":[{\"$match\":{\"_id\":1}},{\"$set\":{\"note\":\"approved\"}},{\"$out\":\"approved_output\"}]}"
        }
        func largeText() -> String {
            engine == .cassandra ? "SELECT note FROM \(qualified) WHERE id=2" : "{\"collection\":\"items\",\"find\":{\"_id\":2}}"
        }
        func close() async {
            broker?.stop(); broker = nil
            await coordinator.shutdown()
            for client in clients { await client.resumeOutput(); await client.stop() }
            if let window { window.orderOut(nil); window.close() }
            if session != nil {
                if engine == .cassandra { _ = try? await execute("DROP TABLE IF EXISTS \(qualified)") }
                else { try? await mongoScript("db.getSiblingDB('" + database + "').dropDatabase();") }
            }
            _ = await admin.shutdown()
            session = nil
        }
    }
    private struct Element {
        let object: NSObject
        func legacy<T>(_ attribute: String) -> T? {
            let names = NSSelectorFromString("accessibilityAttributeNames")
            let getter = NSSelectorFromString("accessibilityAttributeValue:")
            guard object.responds(to: names), object.responds(to: getter),
                  let available = object.perform(names)?.takeUnretainedValue() as? [String], available.contains(attribute) else { return nil }
            return object.perform(getter, with: attribute)?.takeUnretainedValue() as? T
        }
        func value<T>(_ name: String) -> T? {
            let selector = NSSelectorFromString(name)
            let modern = object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() as? T : nil
            if let string = modern as? String, !string.isEmpty { return modern }
            if let children = modern as? [NSObject], !children.isEmpty { return modern }
            let attributes = ["accessibilityIdentifier": "AXIdentifier", "accessibilityChildren": "AXChildren", "accessibilityRole": "AXRole"]
            if let attribute = attributes[name], let fallback: T = legacy(attribute) { return fallback }
            return modern
        }
        var id: String? { value("accessibilityIdentifier") }
        var role: String? { value("accessibilityRole") }
        var button: NSButton? { (object as? NSButton) ?? ((object as? NSCell)?.controlView as? NSButton) }
        var enabled: Bool {
            let legacyEnabled: NSNumber? = legacy("AXEnabled")
            return legacyEnabled?.boolValue ?? button?.isEnabled ?? true
        }
        func press() -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            if object.responds(to: selector) {
                typealias ModernAction = @convention(c) (AnyObject, Selector) -> Bool
                if unsafeBitCast(object.method(for: selector), to: ModernAction.self)(object, selector) { return true }
            }
            let names = NSSelectorFromString("accessibilityActionNames"), perform = NSSelectorFromString("accessibilityPerformAction:")
            guard object.responds(to: names), object.responds(to: perform),
                  let available = object.perform(names)?.takeUnretainedValue() as? [String], available.contains("AXPress") else { return false }
            typealias LegacyAction = @convention(c) (AnyObject, Selector, AnyObject) -> Void
            unsafeBitCast(object.method(for: perform), to: LegacyAction.self)(object, perform, "AXPress" as NSString)
            return true
        }
    }
    private func elements(_ window: NSWindow) -> [Element] {
        var seen = Set<ObjectIdentifier>(), result: [Element] = []
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            let element = Element(object: object); result.append(element)
            let children: [NSObject] = element.value("accessibilityChildren") ?? []
            children.forEach(visit); (object as? NSView)?.subviews.forEach(visit)
        }
        visit(window); if let content = window.contentView { visit(content) }
        if let sheet = window.attachedSheet { result += elements(sheet) }
        return result
    }
    private func wait(_ message: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        repeat { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) } while ContinuousClock.now < deadline
        try #require(condition(), Comment(rawValue: message))
    }
    private func press(_ id: String, _ window: NSWindow) async throws {
        do { try await wait("Missing R04 MCP native control: \(id)") { elements(window).contains { $0.id == id } } }
        catch {
            let snapshot = elements(window).map { "\(String(describing: type(of: $0.object)))|\($0.role ?? "")|\($0.id ?? "")" }.joined(separator: ";")
            r04ExtendedMCPTrace("missing control tree: " + snapshot)
            throw error
        }
        let element = try #require(elements(window).first { $0.id == id })
        try #require(element.enabled)
        if let button = element.button {
            button.scrollToVisible(button.bounds)
            window.contentView?.layoutSubtreeIfNeeded()
            try #require(!button.visibleRect.isEmpty)
            button.performClick(nil)
        }
        else { try #require(element.press(), "R04 MCP native Press failed.") }
        try await Task.sleep(for: .milliseconds(160))
    }
    private func host(_ fixture: Fixture, dark: Bool) async throws -> NSWindow {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        application.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let window = NSWindow(contentRect: NSRect(x: 120, y: 100, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "DBeer R04 stdio MCP verification"; window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: AgentAccessSettingsView(coordinator: fixture.coordinator,
            brokerError: nil, revoke: { id in fixture.broker?.disconnect(clientID: id); await fixture.coordinator.revoke(clientID: id) })
            .preferredColorScheme(dark ? .dark : .light))
        fixture.window = window; window.makeKeyAndOrderFront(nil); application.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(180)); return window
    }
    private func capture(_ window: NSWindow, name: String) async throws {
        try await Task.sleep(for: .milliseconds(160))
        let output = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"].map { URL(fileURLWithPath: $0) } ?? repository.appendingPathComponent("build/r04-ui")
        try await NativeOwnedWindowCapture.write(window, to: output.appendingPathComponent(name + ".png"))
    }
    private func grant(_ client: R04ExtendedMCPStdioClient, fixture: Fixture, window: NSWindow,
                       name: String, writes: Bool) async throws -> UUID {
        window.makeKeyAndOrderFront(nil)
        let call = Task { try await client.tool("dbeer_connections") }
        try await wait("Extended stdio MCP did not request native permission.") { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        let chosen = "agentProfile-\(fixture.profile.id.uuidString)", write = "agentWrite-\(fixture.profile.id.uuidString)"
        let readonlyWrite = try #require(elements(sheet).first { $0.id == "agentWrite-\(fixture.readonly.id.uuidString)" }?.button)
        #expect(readonlyWrite.state == .off && !readonlyWrite.isEnabled)
        #expect(try #require(elements(sheet).first { $0.id == chosen }?.button).state == .off)
        try await capture(sheet, name: name + (writes ? "-write-approval" : "-readonly-approval"))
        try await press(chosen, sheet)
        try await press("agentProfile-\(fixture.readonly.id.uuidString)", sheet)
        if writes { try await press(write, sheet) }
        try await press("agentApprove", sheet)
        let reply = try await call.value
        let entries = reply["result"]?["structuredContent"]?["connections"]?.array ?? []
        let expectedLanguage = fixture.engine == .cassandra ? "cql" : "mongodb-json"
        let allowed = entries.first { $0["id"]?.string == fixture.profile.id.uuidString }
        let protected = entries.first { $0["id"]?.string == fixture.readonly.id.uuidString }
        let correct = entries.count == 2 && allowed?["readOnly"]?.flag == !writes &&
            allowed?["queryLanguage"]?.string == expectedLanguage && protected?["readOnly"]?.flag == true &&
            protected?["readOnlyEnforcement"]?.string == "local"
        try #require(correct, "Extended MCP lost profile-specific permissions or engine policy metadata.")
        try await wait("The native permission sheet did not finish.") { window.attachedSheet == nil }
        return try #require(fixture.coordinator.clients.first?.id)
    }
    private func isError(_ reply: R04ExtendedMCPJSON) -> Bool { reply["result"]?["isError"]?.flag == true }
    private func note(_ reply: R04ExtendedMCPJSON, engine: DatabaseEngine) -> String? {
        let cells = reply["result"]?["structuredContent"]?["results"]?.array?.first?["rows"]?.array?.first?.array
        if engine == .cassandra { return cells?.last?.string }
        guard let string = cells?.first?.string, let data = string.data(using: .utf8),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return document["note"] as? String
    }

    @Test(arguments: ["cassandra-light", "cassandra-dark", "mongodb-light", "mongodb-dark"])
    func extendedStdioPermissionsReadonlyWritesCancellationAndBlockedOutputRevoke(_ scenario: String) async throws {
        let engine: DatabaseEngine = scenario.hasPrefix("cassandra") ? .cassandra : .mongodb
        let fixture = try Fixture(engine: engine, executable: repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core"))
        do {
            r04ExtendedMCPTrace("fixture start")
            try await fixture.start()
            let window = try await host(fixture, dark: scenario.hasSuffix("dark"))
            let client = try await fixture.client()
            let discovered = try await client.request("tools/list")
            #expect(discovered["result"]?["tools"]?.array?.count == 4 && fixture.coordinator.clients.isEmpty)
            let owner = try await grant(client, fixture: fixture, window: window, name: scenario, writes: false)
            let excluded = try await client.tool("dbeer_query", fixture.queryArguments(fixture.readText(), profileID: fixture.excluded.id))
            #expect(isError(excluded))
            let read = try await client.tool("dbeer_query", fixture.queryArguments(fixture.readText()))
            #expect(!isError(read) && note(read, engine: engine) == "seed")
            let rejected = try await client.tool("dbeer_query", fixture.queryArguments(fixture.writeText()))
            #expect(isError(rejected) && window.attachedSheet == nil)
            let forcedReadonly = try await client.tool("dbeer_query", fixture.queryArguments(fixture.writeText(), profileID: fixture.readonly.id))
            #expect(isError(forcedReadonly) && window.attachedSheet == nil)
            let kinds = engine == .cassandra ? ["keyspaces", "tables", "columns"] : ["databases", "collections", "fields"]
            for (index, kind) in kinds.enumerated() {
                var arguments: [String: R04ExtendedMCPJSON] = ["profileId": .string(fixture.profile.id.uuidString), "kind": .string(kind)]
                if index > 0 { arguments["schema"] = .string(fixture.schema) }
                if index > 1 { arguments["object"] = .string(fixture.object) }
                let catalog = try await client.tool("dbeer_catalog", arguments)
                #expect(!isError(catalog))
                let rows = catalog["result"]?["structuredContent"]?["results"]?.array?.first?["rows"]?.array ?? []
                let names = rows.compactMap { $0.array?.first?.string }
                #expect(names.contains(index == 0 ? fixture.schema : index == 1 ? fixture.object : "note"))
                if engine == .mongodb && index == 2 {
                    let result = catalog["result"]?["structuredContent"]?["results"]?.array?.first
                    #expect(result?["displayNotice"]?.string?.contains("not a schema") == true)
                    #expect(result?["affectedRowCountKnown"] != nil && result?["affectedRowCountKnown"]?.flag == false)
                }
            }
            // Both engines can receive cancellation before a permitted read
            // reaches admission. Its ID stays retired instead of running later.
            let retiredID = UUID().uuidString
            let cancellation = try await client.tool("dbeer_cancel", ["queryId": .string(retiredID)])
            let retired = try await client.tool("dbeer_query", fixture.queryArguments(fixture.readText(), id: retiredID))
            #expect(!isError(cancellation) && isError(retired) && window.attachedSheet == nil)
            let stillSeed = try await client.tool("dbeer_query", fixture.queryArguments(fixture.readText()))
            #expect(note(stillSeed, engine: engine) == "seed")

            // A bounded real database result is larger than the real stdout
            // pipe. Native revoke must remain live without consuming that pipe.
            await client.pauseOutput()
            let prior = fixture.coordinator.audit.filter { $0.method == "query" && $0.outcome == "success" }.count
            let large = Task { try await client.tool("dbeer_query", fixture.queryArguments(fixture.largeText())) }
            try await wait("Extended MCP large response did not reach blocked stdout.") {
                fixture.coordinator.audit.filter { $0.method == "query" && $0.outcome == "success" }.count > prior
            }
            try await capture(window, name: scenario + "-blocked-output")
            try await press("agentRevoke-\(owner.uuidString)", window)
            try await wait("Native revoke left an extended MCP grant active.") { fixture.coordinator.clients.isEmpty }
            await client.resumeOutput()
            let completeLarge = try await large.value
            #expect(!isError(completeLarge))
            let afterRevoke = try await client.tool("dbeer_query", fixture.queryArguments(fixture.readText()))
            #expect(isError(afterRevoke))
            try await capture(window, name: scenario + "-revoked")
            await client.stop()

            let writer = try await fixture.client()
            let writerID = try await grant(writer, fixture: fixture, window: window, name: scenario, writes: true)
            let deniedProtected = try await writer.tool("dbeer_query", fixture.queryArguments(fixture.writeText(), profileID: fixture.readonly.id))
            #expect(isError(deniedProtected) && window.attachedSheet == nil)
            let declined = Task { try await writer.tool("dbeer_query", fixture.queryArguments(fixture.writeText())) }
            try await wait("Extended write did not request exact native confirmation.") { window.attachedSheet != nil }
            let review = try #require(window.attachedSheet)
            try await capture(review, name: scenario + "-write-confirmation")
            try await press("agentCancelOperation", review)
            let declinedReply = try await declined.value
            #expect(isError(declinedReply))
            try await wait("Cancelled native confirmation remained visible.") { window.attachedSheet == nil }

            // Cancellation while the real operation review is open must dismiss
            // that review and prevent a write, including MongoDB output stages.
            let reviewID = UUID().uuidString
            let reviewCall = Task { try await writer.tool("dbeer_query", fixture.queryArguments(fixture.writeText(), id: reviewID)) }
            try await wait("The cancellable extended operation sheet did not appear.") { window.attachedSheet != nil }
            let stopped = try await writer.tool("dbeer_cancel", ["queryId": .string(reviewID)])
            let stoppedReply = try await reviewCall.value
            #expect(!isError(stopped) && isError(stoppedReply))
            try await wait("MCP cancellation did not dismiss native review.") { window.attachedSheet == nil }
            let notWritten = try await writer.tool("dbeer_query", fixture.queryArguments(fixture.readText(approved: engine == .mongodb)))
            if engine == .mongodb {
                let rows = notWritten["result"]?["structuredContent"]?["results"]?.array?.first?["rows"]?.array
                #expect(!isError(notWritten) && rows?.isEmpty == true)
            } else { #expect(!isError(notWritten) && note(notWritten, engine: engine) == "seed") }

            let accepted = Task { try await writer.tool("dbeer_query", fixture.queryArguments(fixture.writeText())) }
            try await wait("The reviewed extended write did not appear.") { window.attachedSheet != nil }
            try await press("agentExecute", try #require(window.attachedSheet))
            let acceptedReply = try await accepted.value
            #expect(!isError(acceptedReply))
            let written = try await writer.tool("dbeer_query", fixture.queryArguments(fixture.readText(approved: true)))
            #expect(!isError(written) && note(written, engine: engine) == "approved")
            try await press("agentRevoke-\(writerID.uuidString)", window)
            try await wait("Writer grant remained after native revocation.") { fixture.coordinator.clients.isEmpty }
            await writer.stop()
            let fresh = try await fixture.client()
            let pending = Task { try await fresh.tool("dbeer_connections") }
            try await wait("A new extended MCP process inherited access without approval.") { window.attachedSheet != nil }
            try await press("agentDeny", try #require(window.attachedSheet))
            let denied = try await pending.value
            #expect(isError(denied) && fixture.coordinator.clients.isEmpty)
            await fixture.close()
            r04ExtendedMCPTrace("complete")
        } catch {
            await fixture.close()
            throw error
        }
    }
}
