import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import DBeer

/// Opt-in integration coverage: the real SwiftUI workspace, native table,
/// BackendClient, bundled Go executable, and an explicitly supplied PostgreSQL.
@Suite(.serialized)
@MainActor
struct WorkspaceWindowIntegrationTests {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private var executable: URL {
        repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
    }

    private func settings() throws -> ConnectionSettings {
        // Only URL DSNs are supported here; Go integration tests also accept pgx's
        // keyword syntax. Never interpolate a DSN or driver error into a failure.
        let dsn = ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? ""
        guard let url = URLComponents(string: dsn), ["postgres", "postgresql"].contains(url.scheme),
              let host = url.host, let user = url.user else {
            throw TestFailure("Swift live tests require a PostgreSQL URL in DBEER_TEST_DSN.")
        }
        let parameters = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                                    uniquingKeysWith: { _, last in last })
        return ConnectionSettings(host: host, port: url.port ?? 5432,
            database: String(url.path.dropFirst()), user: user, password: url.password ?? "",
            sslMode: parameters["sslmode"] ?? "verify-full", sslRootCert: parameters["sslrootcert"])
    }

    private struct TestFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private func configure(_ model: WorkspaceModel, with settings: ConnectionSettings) {
        model.host = settings.host
        model.port = String(settings.port)
        model.database = settings.database
        model.user = settings.user
        model.password = settings.password
        model.sslMode = settings.sslMode
        model.sslRootCert = settings.sslRootCert ?? ""
    }

    private func settle() async throws {
        // Yield the main actor so SwiftUI can reconcile published model changes.
        try await Task.sleep(for: .milliseconds(100))
    }

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    private func table(in view: NSView) throws -> NSTableView {
        try #require(descendants(view, of: NSTableView.self).first {
            $0.accessibilityLabel() == "Query results"
        })
    }

    private func cell(_ table: NSTableView, column: Int, row: Int = 0) throws -> NSTextField {
        let cell = try #require(table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)
        return try #require(cell.textField)
    }

    private func capture(_ view: NSView, named name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"], !directory.isEmpty else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try png.write(to: destination.appendingPathComponent(name + ".png"))
    }

    private func execute(_ sql: String, on model: WorkspaceModel) async throws {
        model.sql = sql
        await model.run()
        guard model.result != nil, model.queryFailure == nil else {
            throw TestFailure("A live SQL command did not complete successfully.")
        }
        try await settle()
    }

    private func query(_ sql: String, using client: BackendClient, session: String) async throws -> BackendMessage {
        try await client.request(.execute(sessionId: session, queryId: UUID().uuidString, sql: sql))
    }

    private func backendExists(_ pid: Int, observer: BackendClient, session: String) async throws -> Bool {
        let reply = try await query("SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid=\(pid))::text", using: observer, session: session)
        return reply.rows?.first?.first == "true"
    }

    private func assertBackendClosed(_ pid: Int, observer: BackendClient, session: String, timeout: Duration = .seconds(3)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while try await backendExists(pid, observer: observer, session: session), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await !backendExists(pid, observer: observer, session: session))
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty,
                   "Set DBEER_TEST_DSN to run PostgreSQL and native-window integration."))
    func realWorkspaceConnectRunRefreshStopAndShutdown() async throws {
        let connection = try settings()
        let client = BackendClient(executableURL: executable)
        let observer = BackendClient(executableURL: executable)
        let model = WorkspaceModel(helperFactory: { client })
        configure(model, with: connection)
        _ = NSApplication.shared
        let content = NSHostingView(rootView: WorkspaceView(model: model).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "DBeer integration verification"
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.orderFront(nil)
        defer { window.close() }
        var checkpoint = "observer handshake"
        do {
            try await observer.start()
            checkpoint = "observer PostgreSQL connection"
            let observedConnection = try await observer.request(.connect(connection))
            let observerSession = try #require(observedConnection.sessionId)
            checkpoint = "workspace startup"
            await model.start()
            checkpoint = "native editor layout"
            try await settle()
            let editor = try #require(descendants(content, of: NSTextView.self).first)
            #expect(!editor.isAutomaticQuoteSubstitutionEnabled)
            #expect(!editor.isAutomaticDashSubstitutionEnabled)
            #expect(!editor.isAutomaticTextReplacementEnabled)
            #expect(!editor.isAutomaticSpellingCorrectionEnabled)
            try capture(content, named: "01-connection")
            checkpoint = "workspace connection"
            await model.connect()
            guard model.connectionState == .connected else { throw TestFailure("Native workspace did not connect.") }
            #expect(model.canRun)

            checkpoint = "SQL/native table scenario"
            try await execute("SELECT pg_backend_pid() AS pid", on: model)
            let pidText = try #require(model.result?.rows?.first?.first ?? nil)
            let pid = try #require(Int(pidText))
            model.sql = "SELECT 1 AS id, 'hello'::text AS name"
            try await settle()
            #expect(window.makeFirstResponder(editor))
            let commandReturn = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            // Dispatch only within this real test window; no global input or AX permission.
            var handled = window.performKeyEquivalent(with: commandReturn)
            if !handled { handled = content.performKeyEquivalent(with: commandReturn) }
            #expect(handled)
            guard handled else { throw TestFailure("The native Command Return action was not handled.") }
            let shortcutDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while model.result?.rows != [["1", "hello"]], model.queryFailure == nil,
                  ContinuousClock.now < shortcutDeadline { try await Task.sleep(for: .milliseconds(5)) }
            #expect(model.result?.rows == [["1", "hello"]])
            try await settle()
            var nativeTable = try table(in: content)
            #expect(nativeTable.tableColumns.map(\.title) == ["id", "name"])
            #expect(nativeTable.numberOfRows == 1)
            #expect(try cell(nativeTable, column: 0).stringValue == "1")
            #expect(try cell(nativeTable, column: 1).stringValue == "hello")
            try capture(content, named: "02-query-results")

            try await execute("""
                SELECT
                  NULL::text AS x, ''::text AS x, 'NULL'::text AS x,
                  9007199254740993::bigint AS batch_id,
                  123456789.123456789::numeric AS amount
                """, on: model)
            nativeTable = try table(in: content)
            #expect(nativeTable.tableColumns.map(\.title) == ["x", "x", "x", "batch_id", "amount"])
            #expect(Set(nativeTable.tableColumns.map(\.identifier)).count == 5)
            #expect(try cell(nativeTable, column: 0).accessibilityValue() == "SQL NULL")
            #expect(try cell(nativeTable, column: 1).accessibilityValue() == "Empty string")
            #expect(try cell(nativeTable, column: 2).accessibilityValue() == "NULL")
            #expect(try cell(nativeTable, column: 3).stringValue == "9007199254740993")
            #expect(try cell(nativeTable, column: 4).stringValue == "123456789.123456789")
            // Exercise the same native resizing a user performs, keeping all digits visible.
            nativeTable.tableColumns[3].width = 200
            nativeTable.tableColumns[4].width = 220
            try capture(content, named: "03-values")

            try await execute("SELECT E'κόσμος\\n🌍'::text AS unicode, '{\"name\":\"beer\"}'::jsonb AS payload", on: model)
            #expect(try cell(try table(in: content), column: 0).stringValue == "κόσμος\n🌍")
            try await execute("SELECT 1 AS no_rows WHERE false", on: model)
            nativeTable = try table(in: content)
            #expect(nativeTable.tableColumns.map(\.title) == ["no_rows"])
            #expect(nativeTable.numberOfRows == 0)
            try await execute("SELECT generate_series(1, 1001) AS n", on: model)
            #expect(model.result?.truncated == true)
            #expect(try table(in: content).numberOfRows == 1000)
            try await execute("CREATE TEMP TABLE dbeer_window_test (value text)", on: model)
            #expect(model.result?.commandTag == "CREATE TABLE")
            try await execute("INSERT INTO dbeer_window_test VALUES ('same session')", on: model)
            #expect(model.result?.commandTag == "INSERT 0 1")
            try await execute("SELECT value FROM dbeer_window_test", on: model)
            #expect(model.result?.rows == [["same session"]])
            try await execute("BEGIN", on: model)
            #expect(model.transactionStatus == .transaction)
            model.sql = "SELECT missing_column FROM dbeer_window_test"
            await model.run()
            #expect(model.result == nil)
            #expect(model.queryFailure?.sqlState == "42703")
            #expect(model.transactionStatus == .failedTransaction)
            try await settle()
            try capture(content, named: "05-sql-error")
            try await execute("ROLLBACK", on: model)
            #expect(model.transactionStatus == .idle)

            model.sql = "SELECT pg_sleep(10)"
            let running = Task { await model.run() }
            let startDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !model.canStop, ContinuousClock.now < startDeadline { try await Task.sleep(for: .milliseconds(5)) }
            #expect(model.canStop)
            #expect(!model.canRun)
            #expect(!model.canDisconnect)
            #expect(model.result == nil)
            // A main-actor task and SwiftUI update run while PostgreSQL is busy.
            try await settle()
            #expect(model.elapsedMilliseconds() > 0)
            try capture(content, named: "04-running-query")
            await model.stop()
            await running.value
            #expect(model.queryFailure?.category == "cancelled")
            #expect(model.transactionStatus == .idle)
            #expect(model.canRun)
            try await execute("SELECT pg_backend_pid() AS pid", on: model)
            #expect(model.result?.rows?.first?.first == pidText)
            await model.disconnect()
            #expect(model.connectionState == .disconnected)
            try await assertBackendClosed(pid, observer: observer, session: observerSession)
            await model.connect()
            try await execute("SELECT pg_backend_pid() AS pid", on: model)
            let shutdownPIDText = try #require(model.result?.rows?.first?.first ?? nil)
            let shutdownPID = try #require(Int(shutdownPIDText))
            model.sql = "SELECT pg_sleep(10)"
            let closingQuery = Task { await model.run() }
            let closeStartDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !model.canStop, ContinuousClock.now < closeStartDeadline { try await Task.sleep(for: .milliseconds(5)) }
            #expect(model.canStop)
            let shutdownStarted = ContinuousClock.now
            await model.shutdown()
            await closingQuery.value
            #expect(shutdownStarted.duration(to: .now) < .seconds(3))
            #expect(await client.waitForExit().status == 0)
            #expect(model.password.isEmpty)
            try await assertBackendClosed(shutdownPID, observer: observer, session: observerSession)
            _ = await observer.shutdown()
        } catch {
            await model.shutdown()
            _ = await observer.shutdown()
            throw TestFailure("Native workspace integration failed at \(checkpoint) (\(type(of: error))).")
        }
    }

    @Test func lastWindowClosesTheApplication() {
        #expect(AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty &&
                   ProcessInfo.processInfo.environment["DBEER_TEST_KEYCHAIN"] == "1",
                   "Set DBEER_TEST_DSN and DBEER_TEST_KEYCHAIN=1 to test saved-profile relaunch with PostgreSQL and Keychain."))
    func savedProfileReconnectsAfterWorkspaceRelaunchUsingOriginalKeychainAccount() async throws {
        let connection = try settings()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-relaunch-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let libraryURL = directory.appendingPathComponent("connections.json")
        let service = "dev.dbeer.tests.relaunch.\(UUID().uuidString)"
        let keychainURL = ProcessInfo.processInfo.environment["DBEER_TEST_KEYCHAIN_PATH"].map { URL(fileURLWithPath: $0) }
        let credentials = KeychainConnectionCredentialStore(service: service, keychainURL: keychainURL)
        let observer = BackendClient(executableURL: executable)
        let first = WorkspaceModel(helperFactory: { BackendClient(executableURL: executable) },
            connectionStore: FileConnectionLibraryStore(fileURL: libraryURL), credentialStore: credentials)
        // All objects in the relaunched workspace are new. Only the metadata
        // file, Keychain service and account UUID survive, as in production.
        let second = WorkspaceModel(helperFactory: { BackendClient(executableURL: executable) },
            connectionStore: FileConnectionLibraryStore(fileURL: libraryURL),
            credentialStore: KeychainConnectionCredentialStore(service: service, keychainURL: keychainURL))
        var profileID: UUID?
        do {
            try await observer.start()
            let observedConnection = try await observer.request(.connect(connection))
            let observerSession = try #require(observedConnection.sessionId)
            await first.start()
            #expect(await first.saveConnection(name: "Relaunch fixture", settings: connection))
            let id = try #require(first.selectedConnectionId)
            profileID = id
            await first.connectSavedConnection(id)
            #expect(first.activeConnectionId == id)
            try await execute("SELECT pg_backend_pid() AS pid", on: first)
            let firstPIDText = try #require(first.result?.rows?.first?.first ?? nil)
            let firstPID = try #require(Int(firstPIDText))
            await first.shutdown()
            #expect(first.password.isEmpty)
            try await assertBackendClosed(firstPID, observer: observer, session: observerSession)

            await second.start()
            #expect(second.savedConnections.count == 1)
            #expect(second.selectedConnectionId == id)
            #expect(second.connectionState == .disconnected)
            #expect(second.sessionId == nil && second.activeConnectionId == nil)
            #expect(second.password.isEmpty)
            #expect(second.result == nil)
            await second.connectSavedConnection(id)
            #expect(second.activeConnectionId == id)
            #expect(second.connectionsError == nil)
            try await execute("SELECT pg_backend_pid() AS pid", on: second)
            let secondPIDText = try #require(second.result?.rows?.first?.first ?? nil)
            let secondPID = try #require(Int(secondPIDText))
            #expect(secondPID != firstPID)
            #expect(try await credentials.password(for: id) == connection.password)
            let metadata = try String(contentsOf: libraryURL, encoding: .utf8)
            #expect(!metadata.contains("password"))
            await second.shutdown()
            try await assertBackendClosed(secondPID, observer: observer, session: observerSession)
            try await credentials.deletePassword(for: id)
            _ = await observer.shutdown()
        } catch {
            await first.shutdown()
            await second.shutdown()
            if let profileID { try? await credentials.deletePassword(for: profileID) }
            _ = await observer.shutdown()
            throw TestFailure("Saved-profile relaunch verification did not complete (\(type(of: error))).")
        }
    }

    @Test(.enabled(if: !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty,
                   "Set DBEER_TEST_DSN to run real helper-failure integration."))
    func realHelperDeathInvalidatesSessionWithoutReplayingSQL() async throws {
        let connection = try settings()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dbeer-helper-failure-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pid")
        let wrapper = directory.appendingPathComponent("launch-helper")
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        // exec preserves this child PID; no credentials occur in script or argv.
        let script = "#!/bin/sh\nprintf '%s' \"$$\" > \(quoted(pidFile.path))\nexec \(quoted(executable.path))\n"
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        var launches = 0
        let model = WorkspaceModel(helperFactory: {
            launches += 1
            return BackendClient(executableURL: wrapper)
        })
        configure(model, with: connection)
        let observer = BackendClient(executableURL: executable)
        do {
            try await observer.start()
            let observedConnection = try await observer.request(.connect(connection))
            let observerSession = try #require(observedConnection.sessionId)
            await model.start()
            await model.connect()
            guard model.connectionState == .connected else { throw TestFailure("Failure-test workspace did not connect.") }
            try await execute("SELECT pg_backend_pid() AS pid", on: model)
            let pidText = try #require(model.result?.rows?.first?.first ?? nil)
            let backendPID = try #require(Int(pidText))
            let helperPIDText = try String(contentsOf: pidFile, encoding: .utf8)
            let helperPID = try #require(Int32(helperPIDText))
            model.sql = "SELECT pg_sleep(10)"
            let running = Task { await model.run() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !model.canStop, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            #expect(model.canStop)
            #expect(kill(helperPID, SIGKILL) == 0)
            await running.value
            #expect(model.connectionState == .disconnected)
            #expect(model.sessionId == nil)
            #expect(model.queryFailure?.outcomeUnknown == true)
            #expect(!model.canRun)
            #expect(launches == 1)
            // PostgreSQL may discover a killed client only when pg_sleep finishes;
            // the unknown-outcome UI must not promise that server work was cancelled.
            try await assertBackendClosed(backendPID, observer: observer, session: observerSession, timeout: .seconds(12))
            // No automatic helper restart or SQL replay; an explicit Connect recovers.
            await model.connect()
            #expect(launches == 2)
            #expect(model.connectionState == .connected)
            try await execute("SELECT 1 AS recovered", on: model)
            #expect(model.result?.rows == [["1"]])
            await model.shutdown()
            _ = await observer.shutdown()
        } catch {
            await model.shutdown()
            _ = await observer.shutdown()
            throw TestFailure("Real helper-failure integration did not complete (\(type(of: error))).")
        }
    }

}
