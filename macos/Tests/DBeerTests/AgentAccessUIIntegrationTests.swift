import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

/// Explicit opt-in acceptance of production agent controls against disposable databases.
/// Only windows belonging to this test process are inspected, controlled or captured.
@Suite(.serialized, .enabled(if:
    ProcessInfo.processInfo.environment["DBEER_R04_UI_QA"] == "1" &&
    ProcessInfo.processInfo.environment["DBEER_R04_UI_DISPOSABLE"] == "1" &&
    !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty &&
    !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
@MainActor
struct AgentAccessUIIntegrationTests {
    private enum FixtureError: Error { case configuration, database, waitExpired }
    private struct Element {
        let object: NSObject
        func legacy<T>(_ attribute: String) -> T? {
            let names = NSSelectorFromString("accessibilityAttributeNames")
            let value = NSSelectorFromString("accessibilityAttributeValue:")
            guard object.responds(to: names), object.responds(to: value),
                  let attributes = object.perform(names)?.takeUnretainedValue() as? [String],
                  attributes.contains(attribute) else { return nil }
            return object.perform(value, with: attribute)?.takeUnretainedValue() as? T
        }
        func value<T>(_ name: String) -> T? {
            let selector = NSSelectorFromString(name)
            let modern = object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() as? T : nil
            if let string = modern as? String, !string.isEmpty { return modern }
            if let children = modern as? [NSObject], !children.isEmpty { return modern }
            let attributes = ["accessibilityIdentifier": "AXIdentifier", "accessibilityChildren": "AXChildren",
                "accessibilityRole": "AXRole", "accessibilityValue": "AXValue"]
            if let attribute = attributes[name], let fallback: T = legacy(attribute) { return fallback }
            return modern
        }
        func flag(_ name: String, fallback: Bool = false) -> Bool {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return fallback }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
        }
        var id: String? { value("accessibilityIdentifier") }
        var role: String? { value("accessibilityRole") }
        var button: NSButton? { (object as? NSButton) ?? ((object as? NSCell)?.controlView as? NSButton) }
        var enabled: Bool {
            let state: NSNumber? = legacy("AXEnabled")
            return state?.boolValue ?? button?.isEnabled ?? flag("isAccessibilityEnabled", fallback: true)
        }
        func press() -> Bool {
            if flag("accessibilityPerformPress") { return true }
            let names = NSSelectorFromString("accessibilityActionNames")
            let press = NSSelectorFromString("accessibilityPerformAction:")
            guard object.responds(to: names), object.responds(to: press),
                  let actions = object.perform(names)?.takeUnretainedValue() as? [String], actions.contains("AXPress") else { return false }
            typealias Action = @convention(c) (AnyObject, Selector, AnyObject) -> Void
            unsafeBitCast(object.method(for: press), to: Action.self)(object, press, "AXPress" as NSString)
            return true
        }
    }

    private static var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private static var executable: URL {
        ProcessInfo.processInfo.environment["DBEER_R04_UI_HELPER"].map { URL(fileURLWithPath: $0) } ??
            repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
    }
    private static var output: URL {
        ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"].map { URL(fileURLWithPath: $0) } ??
            repository.appendingPathComponent("build/r04-ui")
    }

    @MainActor private final class Fixture {
        let engine: DatabaseEngine
        let connection: ConnectionSettings
        let profiles: [SavedConnection]
        let admin: BackendClient
        let table = "r04_ui_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var session: String?
        var coordinator: AgentAccessCoordinator!
        var window: NSWindow?
        var tasks: [Task<AgentResponse, Never>] = []
        var backendStarts = 0
        var profile: SavedConnection { profiles[0] }
        var deniedProfile: SavedConnection { profiles[1] }
        var readonlyProfile: SavedConnection { profiles[2] }

        init(_ engine: DatabaseEngine) throws {
            self.engine = engine
            let env = ProcessInfo.processInfo.environment
            if engine == .mysql {
                guard let port = Int(env["DBEER_TEST_MYSQL_PORT"] ?? ""),
                      let database = env["DBEER_TEST_MYSQL_DATABASE"], let user = env["DBEER_TEST_MYSQL_USER"] else {
                    throw FixtureError.configuration
                }
                let host = env["DBEER_TEST_MYSQL_HOST"] ?? "localhost"
                guard ["localhost", "127.0.0.1", "::1"].contains(host) else { throw FixtureError.configuration }
                connection = ConnectionSettings(host: host, port: port, database: database, user: user,
                    password: env["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: env["DBEER_TEST_MYSQL_SSLMODE"] ?? "disable",
                    sslRootCert: env["DBEER_TEST_MYSQL_CA_FILE"], engine: engine)
            } else {
                guard let url = URLComponents(string: env["DBEER_TEST_DSN"] ?? ""),
                      let host = url.host, let user = url.user, ["localhost", "127.0.0.1", "::1"].contains(host) else {
                    throw FixtureError.configuration
                }
                connection = ConnectionSettings(host: host, port: url.port ?? 5432, database: String(url.path.dropFirst()),
                    user: user, password: url.password ?? "",
                    sslMode: url.queryItems?.first { $0.name == "sslmode" }?.value ?? "disable")
            }
            var settings = connection
            settings.policy = ExecutionPolicy(environment: .production, readOnly: false)
            var readonly = settings; readonly.policy.readOnly = true
            profiles = [
                SavedConnection(name: engine.displayName + " sandbox", settings: settings),
                SavedConnection(name: engine.displayName + " unapproved", settings: settings),
                SavedConnection(name: engine.displayName + " enforced readonly", settings: readonly),
            ]
            admin = BackendClient(executableURL: AgentAccessUIIntegrationTests.executable)
            coordinator = AgentAccessCoordinator(profiles: { [unowned self] in profiles },
                settings: { [unowned self] snapshot in snapshot.settings(password: connection.password) },
                backendFactory: { [unowned self] in
                    backendStarts += 1
                    let client = BackendClient(executableURL: AgentAccessUIIntegrationTests.executable)
                    try await client.start(); return client
                }, approve: AgentAccessApproval.present, confirm: AgentAccessApproval.confirm)
        }

        func start() async throws {
            try await admin.start()
            session = try await admin.request(.connect(connection)).sessionId
            guard session != nil else { throw FixtureError.database }
            _ = try await execute("CREATE TABLE \(table) (id INTEGER PRIMARY KEY, note VARCHAR(128) NOT NULL)")
            _ = try await execute("INSERT INTO \(table) VALUES (1,'seed')")
        }
        func execute(_ sql: String) async throws -> BackendMessage {
            guard let session else { throw FixtureError.database }
            let reply = try await admin.request(.assess(sessionId: session,
                operations: [OperationRequest(type: "execute", sql: sql)]))
            guard let assessment = reply.assessment, assessment.decision != "deny",
                  let authorization = assessment.authorization else { throw FixtureError.database }
            var command = BackendCommand.execute(sessionId: session, sql: sql)
            command.authorization = authorization
            let result = try await admin.request(command)
            guard result.type == "query.result" else { throw FixtureError.database }
            return result
        }
        func startHello(_ clientID: UUID) -> Task<AgentResponse, Never> {
            let task = Task { await coordinator.handle(clientID: clientID,
                request: AgentRequest(id: UUID().uuidString, method: "hello", clientName: "R04 UI acceptance client")) }
            tasks.append(task); return task
        }
        func query(_ clientID: UUID, _ sql: String, profile: UUID? = nil,
                   queryID: String = UUID().uuidString, timeout: Int = 15) async -> AgentResponse {
            await coordinator.handle(clientID: clientID,
                request: AgentRequest(id: UUID().uuidString, method: "query", profileId: (profile ?? self.profile.id).uuidString,
                    sql: sql, queryId: queryID, maxRows: 100, timeoutSeconds: timeout))
        }
        func startQuery(_ clientID: UUID, _ sql: String, queryID: String = UUID().uuidString,
                        timeout: Int = 15) -> Task<AgentResponse, Never> {
            let task = Task { await query(clientID, sql, queryID: queryID, timeout: timeout) }
            tasks.append(task); return task
        }
        func cancel(_ clientID: UUID, queryID: String) async -> AgentResponse {
            await coordinator.handle(clientID: clientID,
                request: AgentRequest(id: UUID().uuidString, method: "cancel", queryId: queryID))
        }
        func slowSQL(_ marker: String) -> String {
            engine == .postgresql ? "/*\(marker)*/ SELECT pg_sleep(20)" : "/*\(marker)*/ SELECT SLEEP(20)"
        }
        func waitForSleep(_ marker: String, running: Bool) async throws {
            let sql = engine == .postgresql
                ? "SELECT COUNT(*) FROM pg_catalog.pg_stat_activity WHERE pid <> pg_backend_pid() AND wait_event='PgSleep' AND query LIKE '%\(marker)%'"
                : "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE ID <> CONNECTION_ID() AND COMMAND='Query' AND INFO LIKE '%\(marker)%'"
            let deadline = ContinuousClock.now.advanced(by: .seconds(6))
            repeat {
                if engine == .postgresql { _ = try await execute("SELECT pg_stat_clear_snapshot()") }
                let reply = try await execute(sql)
                guard let value = reply.rows?.first?.first ?? nil, let count = Int(value) else { throw FixtureError.database }
                if (count > 0) == running { return }
                try await Task.sleep(for: .milliseconds(20))
            } while ContinuousClock.now < deadline
            throw FixtureError.waitExpired
        }
        func close() async {
            await coordinator.shutdown()
            for task in tasks { _ = await task.value }
            if let window {
                if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
                window.orderOut(nil); window.close()
            }
            if session != nil {
                _ = try? await execute("ROLLBACK")
                _ = try? await execute("DROP TABLE IF EXISTS \(table)")
            }
            _ = await admin.shutdown()
            session = nil
        }
    }

    private func elements(_ window: NSWindow) -> [Element] {
        var seen = Set<ObjectIdentifier>(), result: [Element] = []
        func visit(_ object: NSObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            let item = Element(object: object); result.append(item)
            let children: [NSObject] = item.value("accessibilityChildren") ?? []
            children.forEach(visit)
            (object as? NSView)?.subviews.forEach(visit)
        }
        visit(window)
        if let content = window.contentView { visit(content) }
        if let sheet = window.attachedSheet { result += elements(sheet) }
        return result
    }
    private func item(_ id: String, _ window: NSWindow) throws -> Element {
        try #require(elements(window).first { $0.id == id }, "Missing R04 native control: \(id)")
    }
    private func button(_ id: String, _ window: NSWindow) throws -> NSButton {
        try #require(item(id, window).button, "Expected a native R04 button: \(id)")
    }
    private func wait(_ message: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        repeat {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        try #require(condition(), Comment(rawValue: message))
    }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(160)) }
    private func diagnose(_ window: NSWindow, missing id: String) {
        // Never inspect values, labels, SQL previews, credentials or query results.
        let snapshot = elements(window).map {
            ["class": String(describing: type(of: $0.object)), "id": $0.id ?? "",
             "role": $0.role ?? "", "enabled": String($0.enabled)]
        }
        let name = id.replacingOccurrences(of: "/", with: "_")
        if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) {
            try? FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
            try? data.write(to: Self.output.appendingPathComponent("missing-control-" + name + ".json"))
        }
    }
    private func press(_ id: String, _ window: NSWindow) async throws {
        do {
            try await wait("R04 native control did not mount: \(id)") { elements(window).contains { $0.id == id } }
        } catch {
            diagnose(window, missing: id)
            throw error
        }
        let element = try item(id, window)
        try #require(element.enabled)
        if let control = element.button {
            control.scrollToVisible(control.bounds)
            window.contentView?.layoutSubtreeIfNeeded()
            try #require(control.isEnabled && !control.visibleRect.isEmpty)
            control.performClick(nil)
        }
        else { try #require(element.press(), "R04 native Press failed: \(id)") }
        try await settle()
    }
    private func key(_ code: UInt16, characters: String, sheet: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        NSApplication.shared.postEvent(event, atStart: true)
    }
    private func host(_ fixture: Fixture, dark: Bool) async throws -> NSWindow {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let window = NSWindow(contentRect: NSRect(x: 90, y: 90, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "DBeer R04 agent access verification"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: AgentAccessSettingsView(coordinator: fixture.coordinator,
            brokerError: nil, revoke: { await fixture.coordinator.revoke(clientID: $0) })
            .preferredColorScheme(dark ? .dark : .light))
        fixture.window = window
        window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        try await settle()
        return window
    }
    private func sheet(_ window: NSWindow, identifier: String = "agentApprove") async throws -> NSWindow {
        try await wait("The R04 approval sheet did not appear.") {
            window.attachedSheet != nil && elements(window).contains { $0.id == identifier }
        }
        return try #require(window.attachedSheet)
    }
    private func capture(_ window: NSWindow, _ name: String) async throws {
        try await settle()
        try await NativeOwnedWindowCapture.write(window, to: Self.output.appendingPathComponent(name + ".png"))
    }
    private func approve(_ fixture: Fixture, clientID: UUID, window: NSWindow, writes: Bool,
                         includeReadonly: Bool = false) async throws -> AgentResponse {
        window.makeKeyAndOrderFront(nil)
        let task = fixture.startHello(clientID)
        let permission = try await sheet(window)
        let selected = try button("agentProfile-" + fixture.profile.id.uuidString, permission)
        let write = try button("agentWrite-" + fixture.profile.id.uuidString, permission)
        #expect(selected.state == .off && write.state == .off)
        try await press("agentProfile-" + fixture.profile.id.uuidString, permission)
        if writes { try await press("agentWrite-" + fixture.profile.id.uuidString, permission) }
        if includeReadonly {
            let readonlyWrite = try button("agentWrite-" + fixture.readonlyProfile.id.uuidString, permission)
            #expect(!readonlyWrite.isEnabled && readonlyWrite.state == .off)
            try await press("agentProfile-" + fixture.readonlyProfile.id.uuidString, permission)
        }
        try await press("agentApprove", permission)
        let response = await task.value
        try await wait("The agent permission sheet did not close.") { window.attachedSheet == nil }
        return response
    }

    @Test(arguments: ["postgresql-light", "postgresql-dark", "mysql-light", "mysql-dark"])
    func realPermissionsReadonlyAndSeparateWriteConfirmation(_ scenario: String) async throws {
        let fixture = try Fixture(scenario.hasPrefix("mysql") ? .mysql : .postgresql)
        do {
            try await fixture.start()
            let window = try await host(fixture, dark: scenario.hasSuffix("dark"))

            // Return and Escape both deny the exact pending client, without a backend launch.
            for (code, characters) in [(UInt16(36), "\r"), (UInt16(53), "\u{1b}")] {
                let pending = fixture.startHello(UUID())
                let permission = try await sheet(window)
                #expect(try button("agentProfile-" + fixture.profile.id.uuidString, permission).state == .off)
                #expect(try button("agentWrite-" + fixture.profile.id.uuidString, permission).state == .off)
                #expect(try button("agentApprove", permission).keyEquivalent.isEmpty)
                #expect(try button("agentDeny", permission).keyEquivalent == "\r")
                if code == 36 { try await capture(permission, "approval-" + scenario) }
                try key(code, characters: characters, sheet: permission)
                try await wait("Return/Escape did not deny agent access.") { window.attachedSheet == nil }
                let denied = await pending.value
                #expect(!denied.ok && fixture.coordinator.clients.isEmpty && fixture.backendStarts == 0)
            }

            let client = UUID()
            let grant = try await approve(fixture, clientID: client, window: window, writes: false, includeReadonly: true)
            let grantsCorrect = grant.ok && Set(grant.connections?.map(\.id) ?? []) ==
                Set([fixture.profile.id.uuidString, fixture.readonlyProfile.id.uuidString]) &&
                grant.connections?.allSatisfy(\.readOnly) == true
            #expect(grantsCorrect)
            let priorStarts = fixture.backendStarts
            let unapproved = await fixture.query(client, "SELECT 1", profile: fixture.deniedProfile.id)
            #expect(!unapproved.ok && fixture.backendStarts == priorStarts)
            let insert = await fixture.query(client, "INSERT INTO \(fixture.table) VALUES (2,'readonly-blocked')")
            let readonlyReset = fixture.engine == .postgresql ? "SET default_transaction_read_only=off" : "SET SESSION TRANSACTION READ WRITE"
            let reset = await fixture.query(client, readonlyReset)
            #expect(!insert.ok && !reset.ok && window.attachedSheet == nil)
            let read = await fixture.query(client, "SELECT id,note FROM \(fixture.table)")
            let rowsPreserved = read.ok && read.results?.first?.rows == [["1", "seed"]]
            #expect(rowsPreserved)
            try await capture(window, "readonly-settings-" + scenario)
            try await press("agentRevoke-" + client.uuidString, window)
            try await wait("The native revoke button left the client granted.") { fixture.coordinator.clients.isEmpty }
            let afterRevoke = await fixture.query(client, "SELECT 1")
            #expect(!afterRevoke.ok)

            let writer = UUID()
            let writeGrant = try await approve(fixture, clientID: writer, window: window, writes: true, includeReadonly: true)
            let separateWritePermission = writeGrant.connections?.first { $0.id == fixture.profile.id.uuidString }?.readOnly == false &&
                writeGrant.connections?.first { $0.id == fixture.readonlyProfile.id.uuidString }?.readOnly == true
            #expect(writeGrant.ok && separateWritePermission)
            let protected = await fixture.query(writer, "DELETE FROM \(fixture.table)", profile: fixture.readonlyProfile.id)
            #expect(!protected.ok && window.attachedSheet == nil)

            let destructive = fixture.startQuery(writer, "DELETE FROM \(fixture.table) WHERE id=1")
            let review = try await sheet(window, identifier: "agentExecute")
            let preview = elements(review).compactMap {
                ($0.object as? NSTextView)?.string ?? ($0.value("accessibilityValue") as String?)
            }.joined(separator: "\n")
            let exactPreview = preview.contains("DELETE FROM " + fixture.table) && preview.contains("WHERE id=1")
            #expect(exactPreview)
            try await capture(review, "dangerous-confirmation-" + scenario)
            try await press("agentCancelOperation", review)
            let refused = await destructive.value
            #expect(!refused.ok)
            let unchanged = try await fixture.execute("SELECT COUNT(*) FROM \(fixture.table)")
            #expect(unchanged.rows == [["1"]])

            let accepted = fixture.startQuery(writer, "INSERT INTO \(fixture.table) VALUES (2,'ui-approved')")
            let writeReview = try await sheet(window, identifier: "agentExecute")
            try await press("agentExecute", writeReview)
            let written = await accepted.value
            #expect(written.ok)
            let finalRows = try await fixture.execute("SELECT id,note FROM \(fixture.table) ORDER BY id")
            let approvedWriteOnly = finalRows.rows == [["1", "seed"], ["2", "ui-approved"]]
            #expect(approvedWriteOnly)
            try await press("agentRevoke-" + writer.uuidString, window)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    @Test(arguments: ["postgresql-light", "postgresql-dark", "mysql-light", "mysql-dark"])
    func realCancellationRevocationAndUnrelatedTransaction(_ scenario: String) async throws {
        let fixture = try Fixture(scenario.hasPrefix("mysql") ? .mysql : .postgresql)
        do {
            try await fixture.start()
            let window = try await host(fixture, dark: scenario.hasSuffix("dark"))
            let client = UUID()
            let grant = try await approve(fixture, clientID: client, window: window, writes: false)
            try #require(grant.ok)
            _ = try await fixture.execute("BEGIN")
            let marker = "r04_ui_cancel_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let queryID = UUID().uuidString
            let active = fixture.startQuery(client, fixture.slowSQL(marker), queryID: queryID)
            try await fixture.waitForSleep(marker, running: true)
            try await capture(window, "active-client-" + scenario)
            let cancel = await fixture.cancel(client, queryID: queryID)
            let cancelled = await active.value
            #expect(cancel.ok && !cancelled.ok)
            try await fixture.waitForSleep(marker, running: false)
            let afterCancel = await fixture.query(client, "SELECT 1")
            #expect(afterCancel.ok)

            let revokeMarker = "r04_ui_revoke_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let revoking = fixture.startQuery(client, fixture.slowSQL(revokeMarker))
            try await fixture.waitForSleep(revokeMarker, running: true)
            try await press("agentRevoke-" + client.uuidString, window)
            let revoked = await revoking.value
            #expect(!revoked.ok && fixture.coordinator.clients.isEmpty)
            try await fixture.waitForSleep(revokeMarker, running: false)
            let rejected = await fixture.query(client, "SELECT 1")
            #expect(!rejected.ok)
            let owner = try await fixture.execute("SELECT 1")
            #expect(owner.transactionStatus == .transaction)
            _ = try await fixture.execute("ROLLBACK")
            try await press("agentActivity", window)
            try await capture(window, "revoked-journal-" + scenario)

            // A new connection needs a new sheet and does not inherit the former grant.
            let fresh = fixture.startHello(UUID())
            let newPermission = try await sheet(window)
            #expect(try button("agentProfile-" + fixture.profile.id.uuidString, newPermission).state == .off)
            try await press("agentDeny", newPermission)
            let freshDenied = await fresh.value
            #expect(!freshDenied.ok)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }
}
