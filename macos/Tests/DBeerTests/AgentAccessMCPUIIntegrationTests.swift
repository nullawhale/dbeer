import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import DBeer

private enum R04MCPJSON: Codable, Sendable {
    case object([String: R04MCPJSON]), array([R04MCPJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if try value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode([R04MCPJSON].self) { self = .array(item) }
        else { self = .object(try value.decode([String: R04MCPJSON].self)) }
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

private enum R04MCPFailure: Error { case transport, timeout, invalid, database, configuration }

/// Foundation's counted pipe read may wait for the entire count. A single POSIX
/// read returns the available bytes needed for interactive JSON-RPC replies.
private func r04MCPReadChunk(_ handle: FileHandle) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: 8_192)
    while true {
        let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
        if count < 0 && errno == EINTR { continue }
        guard count >= 0 else { throw R04MCPFailure.transport }
        return Data(bytes.prefix(count))
    }
}

private func r04MCPTrace(_ stage: String) {
    FileHandle.standardError.write(Data("R04 MCP UI: \(stage)\n".utf8))
}

/// Deliberately permits a full subprocess stdout pipe without blocking test UI.
private final class R04MCPReadGate: @unchecked Sendable {
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
private actor R04MCPStdioClient {
    private let executable: URL
    private let name: String
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private let gate = R04MCPReadGate()
    private var pending: [String: CheckedContinuation<R04MCPJSON, Error>] = [:]
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
            while let data = try? r04MCPReadChunk(errors), !data.isEmpty {}
        }
        DispatchQueue(label: "dbeer.r04.mcp.stdout").async { [weak self] in
            guard let self else { return }
            var buffer = Data()
            defer { Task { await self.fail() } }
            while gate.wait(), let data = try? r04MCPReadChunk(source), !data.isEmpty {
                buffer.append(data)
                while let end = buffer.firstIndex(of: 10) {
                    guard end <= 4 * 1_024 * 1_024,
                          let reply = try? JSONDecoder().decode(R04MCPJSON.self, from: Data(buffer[..<end])) else { return }
                    buffer.removeSubrange(...end)
                    Task { await self.receive(reply) }
                }
                if buffer.count > 4 * 1_024 * 1_024 { return }
            }
        }
        r04MCPTrace("initialize sent")
        let initialized = try await request("initialize", params: .object([
            "protocolVersion": .string("2025-11-25"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string(name), "version": .string("1")])
        ]))
        guard initialized["result"] != nil else { throw R04MCPFailure.invalid }
        try send(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]))
        r04MCPTrace("initialize complete")
    }
    func request(_ method: String, params: R04MCPJSON = .object([:])) async throws -> R04MCPJSON {
        guard !failed else { throw R04MCPFailure.transport }
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try send(.object(["jsonrpc": .string("2.0"), "id": .string(id), "method": .string(method), "params": params])) }
            catch { pending.removeValue(forKey: id)?.resume(throwing: R04MCPFailure.transport); return }
            Task { [weak self] in
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                await self?.expire(id)
            }
        }
    }
    func tool(_ name: String, _ arguments: [String: R04MCPJSON] = [:]) async throws -> R04MCPJSON {
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
    private func send(_ value: R04MCPJSON) throws {
        guard let input else { throw R04MCPFailure.transport }
        var data = try JSONEncoder().encode(value); data.append(10)
        try input.write(contentsOf: data)
    }
    private func receive(_ reply: R04MCPJSON) {
        if let id = reply["id"]?.string { pending.removeValue(forKey: id)?.resume(returning: reply) }
    }
    private func expire(_ id: String) { pending.removeValue(forKey: id)?.resume(throwing: R04MCPFailure.timeout) }
    private func fail() {
        failed = true
        let waiters = pending; pending.removeAll()
        waiters.values.forEach { $0.resume(throwing: R04MCPFailure.transport) }
    }
}

/// Explicit opt-in UI acceptance through real stdio MCP, the protected socket,
/// native permissions/Settings and disposable PostgreSQL/MySQL servers.
@Suite(.serialized, .enabled(if:
    ProcessInfo.processInfo.environment["DBEER_R04_UI_QA"] == "1" &&
    ProcessInfo.processInfo.environment["DBEER_R04_UI_DISPOSABLE"] == "1" &&
    !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty &&
    !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
@MainActor
struct AgentAccessMCPUIIntegrationTests {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    @MainActor private final class Fixture {
        let engine: DatabaseEngine
        let connection: ConnectionSettings
        let profile: SavedConnection
        let excluded: SavedConnection
        let executable: URL
        let admin: BackendClient
        var session: String?
        var coordinator: AgentAccessCoordinator!
        var broker: AgentSocketBroker?
        var window: NSWindow?
        var clients: [R04MCPStdioClient] = []

        init(engine: DatabaseEngine, executable: URL) throws {
            self.engine = engine; self.executable = executable
            let environment = ProcessInfo.processInfo.environment
            if engine == .mysql {
                guard let port = Int(environment["DBEER_TEST_MYSQL_PORT"] ?? "") else { throw R04MCPFailure.configuration }
                connection = ConnectionSettings(host: environment["DBEER_TEST_MYSQL_HOST"] ?? "localhost", port: port,
                    database: environment["DBEER_TEST_MYSQL_DATABASE"] ?? "dbeer", user: environment["DBEER_TEST_MYSQL_USER"] ?? "dbeer",
                    password: environment["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: environment["DBEER_TEST_MYSQL_SSLMODE"] ?? "disable",
                    sslRootCert: environment["DBEER_TEST_MYSQL_CA_FILE"], engine: .mysql)
            } else {
                guard let url = URLComponents(string: environment["DBEER_TEST_DSN"] ?? ""), let host = url.host, let user = url.user else {
                    throw R04MCPFailure.configuration
                }
                connection = ConnectionSettings(host: host, port: url.port ?? 5432, database: String(url.path.dropFirst()),
                    user: user, password: url.password ?? "", sslMode: url.queryItems?.first(where: { $0.name == "sslmode" })?.value ?? "disable")
            }
            guard ["localhost", "127.0.0.1", "::1"].contains(connection.host) else { throw R04MCPFailure.configuration }
            profile = SavedConnection(name: "MCP \(engine.displayName) allowed", settings: connection)
            excluded = SavedConnection(name: "MCP \(engine.displayName) excluded", settings: connection)
            admin = BackendClient(executableURL: executable)
            coordinator = AgentAccessCoordinator(profiles: { [unowned self] in [profile, excluded] },
                settings: { [unowned self] snapshot in snapshot.settings(password: connection.password) },
                backendFactory: { let client = BackendClient(executableURL: executable); try await client.start(); return client },
                approve: { await AgentAccessApproval.present(clientName: $0, profiles: $1) }, confirm: AgentAccessApproval.confirm)
        }
        func start() async throws {
            try await admin.start()
            session = try await admin.request(.connect(connection)).sessionId
            guard session != nil else { throw R04MCPFailure.database }
            let coordinator = self.coordinator!
            let broker = AgentSocketBroker(onRequest: { [weak coordinator] id, request in
                guard let coordinator else { return AgentResponse(id: request.id, ok: false, error: "Fixture closed.") }
                return await coordinator.handle(clientID: id, request: request)
            }, onDisconnect: { [weak coordinator] id in await coordinator?.disconnect(clientID: id) })
            // Normal exclusive acquisition protects any concurrently running DBeer.
            try broker.start(); self.broker = broker
        }
        func client() async throws -> R04MCPStdioClient {
            let client = R04MCPStdioClient(executable: executable, name: "R04 stdio UI \(engine.displayName)")
            clients.append(client); try await client.start(); return client
        }
        func execute(_ sql: String) async throws -> BackendMessage {
            guard let session else { throw R04MCPFailure.database }
            let assessed = try await admin.request(.assess(sessionId: session, operations: [OperationRequest(type: "execute", sql: sql)]))
            guard let assessment = assessed.assessment, assessment.decision != "deny", let authorization = assessment.authorization else {
                throw R04MCPFailure.database
            }
            var command = BackendCommand.execute(sessionId: session, sql: sql); command.authorization = authorization
            let reply = try await admin.request(command)
            guard reply.type == "query.result" else { throw R04MCPFailure.database }
            return reply
        }
        func waitForSleep(_ marker: String, running: Bool) async throws {
            let sql = engine == .postgresql
                ? "SELECT COUNT(*) FROM pg_catalog.pg_stat_activity WHERE pid <> pg_backend_pid() AND wait_event='PgSleep' AND query LIKE '%\(marker)%'"
                : "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE ID <> CONNECTION_ID() AND COMMAND='Query' AND INFO LIKE '%\(marker)%'"
            let deadline = ContinuousClock.now.advanced(by: .seconds(6))
            repeat {
                let result = try await execute(sql)
                guard let value = result.rows?.first?.first ?? nil, let count = Int(value) else { throw R04MCPFailure.database }
                if (count > 0) == running { return }
                try await Task.sleep(for: .milliseconds(20))
            } while ContinuousClock.now < deadline
            throw R04MCPFailure.timeout
        }
        func queryArguments(_ sql: String, id: String = UUID().uuidString, rows: Int = 100) -> [String: R04MCPJSON] {
            ["profileId": .string(profile.id.uuidString), "queryId": .string(id), "sql": .string(sql),
             "maxRows": .number(Double(rows)), "timeoutSeconds": .number(20)]
        }
        func slowSQL(_ marker: String) -> String {
            engine == .postgresql ? "/*\(marker)*/ SELECT pg_sleep(20)" : "/*\(marker)*/ SELECT SLEEP(20)"
        }
        func close() async {
            broker?.stop(); broker = nil
            await coordinator.shutdown()
            for client in clients { await client.resumeOutput(); await client.stop() }
            if let window { window.orderOut(nil); window.close() }
            _ = await admin.shutdown()
            // As in the application, stop removes our socket and releases the
            // lease. Keep the harmless private directory/lock inode: deleting a
            // released lease could race another DBeer instance starting there.
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
            r04MCPTrace("missing control tree: " + snapshot)
            throw error
        }
        let element = try #require(elements(window).first { $0.id == id })
        try #require(element.enabled)
        if let button = element.button { button.performClick(nil) }
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
    private func grant(_ client: R04MCPStdioClient, fixture: Fixture, window: NSWindow, name: String) async throws {
        let call = Task { try await client.tool("dbeer_connections") }
        try await wait("Actual stdio MCP did not request native permission.") { window.attachedSheet != nil }
        let sheet = try #require(window.attachedSheet)
        let profileID = "agentProfile-\(fixture.profile.id.uuidString)", writeID = "agentWrite-\(fixture.profile.id.uuidString)"
        let selected = try #require(elements(sheet).first { $0.id == profileID }?.button)
        let write = try #require(elements(sheet).first { $0.id == writeID }?.button)
        #expect(selected.state == .off && write.state == .off)
        try await capture(sheet, name: name + "-approval")
        try await press(profileID, sheet); try await press("agentApprove", sheet)
        let reply = try await call.value
        let entries = reply["result"]?["structuredContent"]?["connections"]?.array ?? []
        let granted = entries.count == 1 && entries.first?["id"]?.string == fixture.profile.id.uuidString && entries.first?["readOnly"]?.flag == true
        try #require(granted, "The real MCP connection did not preserve profile-specific readonly approval.")
        try await capture(window, name: name + "-granted")
    }
    @Test func postgresStdioPermissionsReadonlyCancelAndRevokeInLightAppearance() async throws { try await exercise(.postgresql, dark: false) }
    @Test func mysqlStdioPermissionsReadonlyCancelAndRevokeInDarkAppearance() async throws { try await exercise(.mysql, dark: true) }

    private func exercise(_ engine: DatabaseEngine, dark: Bool) async throws {
        let executable = repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        let fixture = try Fixture(engine: engine, executable: executable)
        let name = "mcp-\(engine.rawValue)-\(dark ? "dark" : "light")"
        do {
            r04MCPTrace("fixture start")
            try await fixture.start(); let window = try await host(fixture, dark: dark)
            let client = try await fixture.client()
            r04MCPTrace("discovery")
            let tools = try await client.request("tools/list")
            let discovered = tools["result"]?["tools"]?.array?.count == 4
            #expect(discovered && fixture.coordinator.clients.isEmpty && window.attachedSheet == nil)
            r04MCPTrace("approval")
            try await grant(client, fixture: fixture, window: window, name: name)
            r04MCPTrace("readonly")
            let excluded = try await client.tool("dbeer_query", ["profileId": .string(fixture.excluded.id.uuidString),
                "queryId": .string(UUID().uuidString), "sql": .string("SELECT 1")])
            #expect(excluded["result"]?["isError"]?.flag == true)
            let denied = try await client.tool("dbeer_query", fixture.queryArguments("CREATE TABLE dbeer_mcp_forbidden (id INTEGER)"))
            #expect(denied["result"]?["isError"]?.flag == true)
            let read = try await client.tool("dbeer_query", fixture.queryArguments("SELECT 1"))
            let successfulRead = read["result"]?["isError"]?.flag != true && read["result"]?["structuredContent"]?["results"]?.array?.first?["rows"]?.array?.first?.array?.first?.string == "1"
            #expect(successfulRead)
            let queryID = UUID().uuidString, marker = "r04_mcp_cancel_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            r04MCPTrace("cancel")
            let slow = Task { try await client.tool("dbeer_query", fixture.queryArguments(fixture.slowSQL(marker), id: queryID)) }
            try await fixture.waitForSleep(marker, running: true)
            let cancelled = try await client.tool("dbeer_cancel", ["queryId": .string(queryID)])
            let slowReply = try await slow.value
            #expect(cancelled["result"]?["isError"]?.flag != true && slowReply["result"]?["isError"]?.flag == true)
            try await fixture.waitForSleep(marker, running: false)

            // Fill real MCP stdout, then prove native revocation still closes a
            // second real database operation while that output remains unread.
            await client.pauseOutput()
            r04MCPTrace("backpressure")
            let priorCompletions = fixture.coordinator.audit.filter { $0.method == "query" && $0.outcome == "success" }.count
            let largeSQL = engine == .postgresql
                ? "SELECT repeat('x',8192) FROM generate_series(1,1000)"
                : "WITH RECURSIVE r04_rows(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r04_rows WHERE n<1000) SELECT REPEAT('x',8192) FROM r04_rows"
            let large = Task { try await client.tool("dbeer_query", fixture.queryArguments(largeSQL, rows: 1000)) }
            try await wait("The bounded large MCP reply did not reach stdout backpressure.") {
                fixture.coordinator.audit.filter { $0.method == "query" && $0.outcome == "success" }.count > priorCompletions
            }
            let revokeMarker = "r04_mcp_revoke_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let revokedQuery = Task { try await client.tool("dbeer_query", fixture.queryArguments(fixture.slowSQL(revokeMarker))) }
            try await fixture.waitForSleep(revokeMarker, running: true)
            let owner = try #require(fixture.coordinator.clients.first?.id)
            r04MCPTrace("revoke")
            try await capture(window, name: name + "-before-revoke-blocked-output")
            try await press("agentRevoke-\(owner.uuidString)", window)
            try await fixture.waitForSleep(revokeMarker, running: false)
            try await wait("Revoked MCP client remained in native Settings.") { fixture.coordinator.clients.isEmpty }
            await client.resumeOutput()
            _ = try await large.value
            let revoked = try await revokedQuery.value
            #expect(revoked["result"]?["isError"]?.flag == true)
            let after = try await client.tool("dbeer_query", fixture.queryArguments("SELECT 1"))
            #expect(after["result"]?["isError"]?.flag == true)
            try await capture(window, name: name + "-revoked")
            await client.stop()

            r04MCPTrace("fresh approval")
            let fresh = try await fixture.client()
            let request = Task { try await fresh.tool("dbeer_connections") }
            try await wait("A new MCP process did not require fresh native permission.") { window.attachedSheet != nil }
            let sheet = try #require(window.attachedSheet)
            try await press("agentDeny", sheet)
            let refused = try await request.value
            #expect(refused["result"]?["isError"]?.flag == true && fixture.coordinator.clients.isEmpty)
            let ownerReply = try await fixture.execute("SELECT 1")
            #expect(ownerReply.rows == [["1"]])
            await fixture.close()
            r04MCPTrace("complete")
        } catch {
            await fixture.close(); throw error
        }
    }
}
