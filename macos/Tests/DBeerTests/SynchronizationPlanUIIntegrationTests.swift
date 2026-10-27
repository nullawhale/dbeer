import AppKit
import Foundation
import ScreenCaptureKit
import SwiftUI
import Testing
@testable import DBeer

private actor R27UIOperations {
    private var values: [String] = []
    func append(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}

private actor R27UISchemaBackend: SchemaComparisonBackend {
    let backend: SchemaComparisonHelperBackend
    let operations: R27UIOperations
    init(executable: URL, operations: R27UIOperations) {
        backend = SchemaComparisonHelperBackend(client: BackendClient(executableURL: executable))
        self.operations = operations
    }
    func start(_ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse {
        await operations.append("schema.start")
        return try await backend.start(request)
    }
    func request(_ operation: String, _ request: SchemaComparisonRequest) async throws -> SchemaComparisonResponse {
        await operations.append("schema." + operation)
        return try await backend.request(operation, request)
    }
    func shutdown() async { await backend.shutdown() }
}

private actor R27UIDataBackend: DataComparisonBackend {
    let backend: DataComparisonHelperBackend
    let operations: R27UIOperations
    init(executable: URL, scratch: URL, operations: R27UIOperations) {
        backend = DataComparisonHelperBackend(executableURL: executable, scratchParentURL: scratch)
        self.operations = operations
    }
    func begin(_ operation: String, _ request: DataComparisonRequest) async throws -> DataComparisonResponse {
        await operations.append("data." + operation)
        return try await backend.begin(operation, request)
    }
    func request(_ operation: String, _ request: DataComparisonRequest) async throws -> DataComparisonResponse {
        await operations.append("data." + operation)
        return try await backend.request(operation, request)
    }
    func shutdown() async { await backend.shutdown() }
}

/// Opt-in acceptance against the runner's disposable databases. Profiles,
/// credentials, documents and application preferences remain private fixtures.
@Suite(.serialized, .enabled(if:
    ProcessInfo.processInfo.environment["DBEER_R27_UI_QA"] == "1" &&
    ProcessInfo.processInfo.environment["DBEER_R27_UI_DISPOSABLE"] == "1" &&
    !(ProcessInfo.processInfo.environment["DBEER_TEST_DSN"] ?? "").isEmpty &&
    !(ProcessInfo.processInfo.environment["DBEER_TEST_MYSQL_PORT"] ?? "").isEmpty))
@MainActor
struct SynchronizationPlanUIIntegrationTests {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private var executable: URL {
        ProcessInfo.processInfo.environment["DBEER_R27_UI_HELPER"].map { URL(fileURLWithPath: $0) } ??
            repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
    }

    private func settings(_ engine: DatabaseEngine) throws -> ConnectionSettings {
        let env = ProcessInfo.processInfo.environment
        if engine == .mysql {
            let host = env["DBEER_TEST_MYSQL_HOST"] ?? "localhost"
            try #require(["localhost", "127.0.0.1", "::1"].contains(host), "R27 UI accepts only the disposable local fixture.")
            return ConnectionSettings(host: host, port: try #require(Int(env["DBEER_TEST_MYSQL_PORT"] ?? "")),
                database: try #require(env["DBEER_TEST_MYSQL_DATABASE"]), user: try #require(env["DBEER_TEST_MYSQL_USER"]),
                password: env["DBEER_TEST_MYSQL_PASSWORD"] ?? "", sslMode: env["DBEER_TEST_MYSQL_SSLMODE"] ?? "disable",
                sslRootCert: env["DBEER_TEST_MYSQL_CA_FILE"], engine: .mysql)
        }
        guard let url = URLComponents(string: env["DBEER_TEST_DSN"] ?? ""), let host = url.host, let user = url.user else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try #require(["localhost", "127.0.0.1", "::1"].contains(host), "R27 UI accepts only the disposable local fixture.")
        return ConnectionSettings(host: host, port: url.port ?? 5432, database: String(url.path.dropFirst()),
            user: user, password: url.password ?? "",
            sslMode: url.queryItems?.first { $0.name == "sslmode" }?.value ?? "disable")
    }

    private func execute(_ sql: String, client: BackendClient, session: String) async throws -> BackendMessage {
        let assessment = try #require(try await client.request(.assess(sessionId: session,
            operations: [OperationRequest(type: "execute", sql: sql)])).assessment)
        try #require(assessment.decision != "deny", "Disposable fixture command was denied.")
        var command = BackendCommand.execute(sessionId: session, sql: sql)
        command.authorization = assessment.authorization
        return try await client.request(command)
    }

    private struct Element {
        let object: NSObject
        func value<T>(_ name: String) -> T? {
            let selector = NSSelectorFromString(name)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() as? T : nil
        }
        func flag(_ name: String, fallback: Bool = false) -> Bool {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return fallback }
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: selector), to: Getter.self)(object, selector)
        }
        var identifier: String? { value("accessibilityIdentifier") }
        var text: String {
            let label: String? = value("accessibilityLabel")
            let content: String? = value("accessibilityValue")
            return [label, content].compactMap { $0 }.joined(separator: " ")
        }
        var button: NSButton? { (object as? NSButton) ?? ((object as? NSCell)?.controlView as? NSButton) }
        var enabled: Bool { button?.isEnabled ?? flag("isAccessibilityEnabled", fallback: true) }
    }

    private func elements(_ window: NSWindow) -> [Element] {
        var result: [Element] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            let element = Element(object: object)
            result.append(element)
            let children: [NSObject] = element.value("accessibilityChildren") ?? []
            children.forEach(visit)
            (object as? NSView)?.subviews.forEach(visit)
        }
        visit(window)
        if let content = window.contentView { visit(content) }
        if let sheet = window.attachedSheet { result += elements(sheet) }
        return result
    }
    private func element(_ identifier: String, in window: NSWindow) throws -> Element {
        try #require(elements(window).first { $0.identifier == identifier }, "Missing R27 native control: \(identifier)")
    }
    private func waitFor(_ message: String, _ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(condition(), Comment(rawValue: message))
    }
    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(180))
        window.contentView?.layoutSubtreeIfNeeded()
    }
    private func press(_ identifier: String, in window: NSWindow) async throws {
        try await settle(window)
        try await waitFor("R27 native control did not become enabled: \(identifier)") {
            elements(window).first { $0.identifier == identifier }?.enabled == true
        }
        let control = try element(identifier, in: window)
        if let button = control.button { button.performClick(nil) }
        else { try #require(control.flag("accessibilityPerformPress"), "Cannot press R27 native control: \(identifier)") }
        try await settle(window)
    }
    private func host(_ workspace: ApplicationWorkspace, dark: Bool) async throws -> NSWindow {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        app.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1420, height: 920),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "DBeer synchronization plan verification"
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: ApplicationWorkspaceView(workspace: workspace)
            .preferredColorScheme(dark ? .dark : .light))
        workspace.presentationWindow = window
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        try await settle(window)
        return window
    }
    private func deepestSheet(_ window: NSWindow) -> NSWindow {
        window.attachedSheet.map(deepestSheet) ?? window
    }
    private func capture(_ window: NSWindow, name: String, directory: URL) async throws {
        try await settle(window)
        if #available(macOS 14.4, *) {
            let windows = try await SCShareableContent.currentProcess
            let own = try #require(windows.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width * 2)
            configuration.height = Int(window.frame.height * 2)
            configuration.scalesToFit = true
            configuration.captureResolution = .best
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: configuration)
            let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent(name + ".png"))
        } else {
            let content = try #require(window.contentView)
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        }
    }

    private func verifyPreview(_ draft: SynchronizationPlanDraft, kind: String, window: NSWindow) async throws -> String {
        try await waitFor("The native SQL plan sheet did not mount.") {
            elements(window).contains { $0.identifier == "syncPlanPreview" }
        }
        try #require(draft.plan.kind == kind && draft.plan.valid && draft.isValid)
        try #require(draft.plan.steps.contains { !$0.manual && !$0.destructive }, "The live plan has no supported additive operation.")
        #expect(draft.plan.steps.filter(\.destructive).allSatisfy { !draft.selected.contains($0.id) })
        #expect(draft.plan.steps.filter(\.manual).allSatisfy { !draft.selected.contains($0.id) })
        #expect(try element("syncPlanDirection", in: window).text.contains(draft.source.name))
        #expect(try element("syncPlanDirection", in: window).text.contains(draft.target.name))
        let initialSQL = try #require(draft.sql)
        #expect(try element("syncPlanPreview", in: window).text.contains(kind == "schema" ? "ALTER TABLE" : "INSERT INTO"))
        let destructive = try #require(draft.plan.steps.first { $0.destructive && !$0.manual }, "The live fixture must expose a destructive operation.")
        try await press("syncPlanStep-\(destructive.id)", in: window)
        try await waitFor("The destructive native toggle did not select its operation.") { draft.selected.contains(destructive.id) }
        #expect(draft.sql?.contains(destructive.sql) == true)
        try await press("syncPlanStep-\(destructive.id)", in: window)
        try await waitFor("The destructive native toggle did not clear its operation.") { !draft.selected.contains(destructive.id) }
        #expect(draft.sql == initialSQL)
        return initialSQL
    }

    @Test(arguments: ["postgresql-light", "postgresql-dark", "mysql-light", "mysql-dark"])
    func realComparisonPlanPreviewAndTargetEditor(_ scenario: String) async throws {
        let engine: DatabaseEngine = scenario.hasPrefix("mysql") ? .mysql : .postgresql
        let connection = try settings(engine)
        let env = ProcessInfo.processInfo.environment
        let output = URL(fileURLWithPath: try #require(env["DBEER_QA_OUTPUT_DIR"]), isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let scratch = output.appendingPathComponent("artifacts-r27-" + token, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let sourceSchema: String
        let targetSchema: String
        if engine == .postgresql {
            sourceSchema = "r27_source_" + token; targetSchema = "r27_target_" + token
        } else {
            sourceSchema = try #require(env["DBEER_R27_MYSQL_SOURCE_SCHEMA"])
            targetSchema = try #require(env["DBEER_R27_MYSQL_TARGET_SCHEMA"])
        }
        let name = "r27_items_" + String(token.prefix(12))
        func quote(_ value: String) -> String {
            let q = engine == .postgresql ? "\"" : "`"
            return q + value.replacingOccurrences(of: q, with: q + q) + q
        }
        let sourceTable = quote(sourceSchema) + "." + quote(name)
        let targetTable = quote(targetSchema) + "." + quote(name)
        let control = BackendClient(executableURL: executable)
        try await control.start()
        let connected = try await control.request(.connect(connection))
        let controlSession = try #require(connected.sessionId, "The disposable control connection did not open.")
        let defaultsName = "dbeer-r27-ui-" + token
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let snapshots = ResultSnapshotStore(rootURL: scratch.appendingPathComponent("snapshots"))
        let themes = EditorThemeStore(defaults: defaults, directory: scratch.appendingPathComponent("themes"))
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(), credentialStore: MemoryConnectionCredentialStore(),
            documentStore: MemorySQLDocumentStore(), commandShortcuts: AppShortcutStore(defaults: defaults),
            copySettings: ResultCopySettings(defaults: defaults), editorThemes: themes,
            appearance: AppAppearance(defaults: defaults, editorThemes: themes), sqlFolders: SQLFolderLibrary(automaticallyRefresh: false),
            sqlLibrary: SQLLibrary(), resultSnapshots: ResultSnapshotsModel(store: snapshots),
            investigations: InvestigationLibraryModel(store: MemoryInvestigationStore(), snapshotStore: snapshots, autosaveDelay: nil),
            automaticallyWatchFiles: false, closeDecision: { _ in .discard }, executionDecision: { _ in true },
            helperFactory: { BackendClient(executableURL: executable) })
        await workspace.start()
        let window = try await host(workspace, dark: scenario.hasSuffix("dark"))
        defer { window.attachedSheet?.orderOut(nil); window.close() }
        func cleanupFixture() async {
            if engine == .postgresql {
                _ = try? await execute("DROP SCHEMA IF EXISTS \(quote(sourceSchema)) CASCADE", client: control, session: controlSession)
                _ = try? await execute("DROP SCHEMA IF EXISTS \(quote(targetSchema)) CASCADE", client: control, session: controlSession)
            } else {
                _ = try? await execute("DROP TABLE IF EXISTS \(sourceTable)", client: control, session: controlSession)
                _ = try? await execute("DROP TABLE IF EXISTS \(targetTable)", client: control, session: controlSession)
            }
        }
        do {
            if engine == .postgresql {
                _ = try await execute("CREATE SCHEMA \(quote(sourceSchema))", client: control, session: controlSession)
                _ = try await execute("CREATE SCHEMA \(quote(targetSchema))", client: control, session: controlSession)
            }
            let bytes = engine == .postgresql ? "bytea" : "blob"
            _ = try await execute("CREATE TABLE \(sourceTable)(id bigint PRIMARY KEY,note varchar(64),amount decimal(30,9),payload \(bytes),revision integer)", client: control, session: controlSession)
            _ = try await execute("CREATE TABLE \(targetTable)(id bigint PRIMARY KEY,note varchar(64) NOT NULL,amount decimal(30,9),payload \(bytes))", client: control, session: controlSession)
            let binary = engine == .postgresql ? "decode('00ff80','hex')" : "X'00ff80'"
            let empty = engine == .postgresql ? "decode('','hex')" : "X''"
            _ = try await execute("INSERT INTO \(sourceTable) VALUES(1,'',12345678901234567890.123456789,\(binary),7),(2,'NULL',NULL,\(empty),NULL)", client: control, session: controlSession)
            _ = try await execute("INSERT INTO \(targetTable) VALUES(1,'original',1.000000000,NULL),(3,'target-only',NULL,NULL)", client: control, session: controlSession)
            let targetRead = "SELECT id,note,amount,payload FROM \(targetTable) ORDER BY id"
            let originals = try await execute(targetRead, client: control, session: controlSession).rows
            let schemaRead = "SELECT column_name,is_nullable FROM information_schema.columns WHERE table_schema='\(targetSchema)' AND table_name='\(name)' ORDER BY ordinal_position"
            let originalSchema = try await execute(schemaRead, client: control, session: controlSession).rows

            let savedSource = await workspace.library.saveConnection(name: "R27 source · \(engine.displayName)", settings: connection)
            try #require(savedSource, "The synthetic source profile could not be saved.")
            let sourceID = try #require(workspace.library.selectedConnectionId)
            let savedTarget = await workspace.library.saveConnection(name: "R27 target · \(engine.displayName)", settings: connection)
            try #require(savedTarget, "The synthetic target profile could not be saved.")
            let targetID = try #require(workspace.library.selectedConnectionId)
            let source = workspace.newDocument(profileID: sourceID, text: "SELECT id,note,amount,payload FROM \(sourceTable) ORDER BY id;")
            source.title = "Source session stays independent"
            await workspace.run(source)
            try #require(source.runtime?.connectionState == .connected && source.executions.first?.failure == nil && source.executions.first?.result != nil)
            let sourceText = source.text
            let sourceRuntime = try #require(source.runtime)
            let sourceSession = try #require(sourceRuntime.sessionId)
            let sourceExecution = try #require(source.executions.first?.id)
            func sourceUnchanged() -> Bool {
                source.text == sourceText && source.runtime === sourceRuntime && sourceRuntime.sessionId == sourceSession &&
                    sourceRuntime.connectionState == .connected && source.executions.count == 1 && source.executions.first?.id == sourceExecution
            }

            let schemaOperations = R27UIOperations()
            let schemaBackend = R27UISchemaBackend(executable: executable, operations: schemaOperations)
            let schema = SchemaComparisonModel(profiles: workspace.library.savedConnections, resolve: { _ in connection }, factory: { schemaBackend },
                openPlan: { sql, target in
                    guard workspace.openSynchronizationPlan(sql, target: target) else { return false }
                    workspace.dismissSchemaComparison(); return true
                }, validatePlanTarget: { workspace.synchronizationTargetMatches($0) })
            schema.sourceID = sourceID; schema.targetID = targetID
            schema.mappings.schemas = [.init(source: sourceSchema, target: targetSchema)]
            workspace.schemaComparison = schema
            try await waitFor("The real schema comparison did not mount.") { window.attachedSheet != nil }
            try await press("schemaCompareStart", in: window)
            try await waitFor("The real schema comparison did not complete.") { schema.summary != nil || schema.error != nil }
            try #require(schema.error == nil && schema.phase == .completed)
            try await waitFor("The schema report was still loading.") { !schema.isLoading && !schema.isLoadingDiff }
            let schemaCaptures = await schemaOperations.snapshot().filter { $0 == "schema.start" }
            try await press("schemaComparePlan", in: window)
            try await waitFor("The real schema SQL plan did not open.") { schema.planDraft != nil || schema.error != nil }
            let schemaDraft = try #require(schema.planDraft)
            let schemaSQL = try await verifyPreview(schemaDraft, kind: "schema", window: window)
            #expect(await schemaOperations.snapshot().filter { $0 == "schema.start" } == schemaCaptures)
            #expect(await schemaOperations.snapshot().filter { $0 == "schema.plan" }.count == 1)
            #expect(sourceUnchanged())
            try await capture(deepestSheet(window), name: "r27-\(scenario)-schema-plan", directory: output)
            let schemaCount = workspace.documents.count
            try await press("syncPlanOpen", in: window)
            try await waitFor("Open did not create the target SQL draft and dismiss comparison.") {
                workspace.schemaComparison == nil && window.attachedSheet == nil && workspace.documents.count == schemaCount + 1
            }
            let schemaEditor = try #require(workspace.selectedDocument)
            #expect(schemaEditor.profileID == targetID && schemaEditor.text == schemaSQL && schemaEditor.runtime == nil && schemaEditor.executions.isEmpty && !schemaEditor.isRunning)
            #expect(sourceUnchanged())
            #expect(try await execute(schemaRead, client: control, session: controlSession).rows == originalSchema)
            #expect(try await execute(targetRead, client: control, session: controlSession).rows == originals)
            try await capture(window, name: "r27-\(scenario)-schema-target-editor", directory: output)

            let dataOperations = R27UIOperations()
            let data = DataComparisonModel(profiles: workspace.library.savedConnections, resolve: { _, _ in connection },
                factory: { R27UIDataBackend(executable: executable, scratch: scratch, operations: dataOperations) },
                openPlan: { sql, target in
                    guard workspace.openSynchronizationPlan(sql, target: target) else { return false }
                    workspace.dismissDataComparison(); return true
                }, validatePlanTarget: { workspace.synchronizationTargetMatches($0) })
            data.sourceID = sourceID; data.targetID = targetID
            data.sourceTable = .init(schema: sourceSchema, name: name); data.targetTable = .init(schema: targetSchema, name: name)
            workspace.dataComparison = data
            try await waitFor("The real data comparison did not mount.") { window.attachedSheet != nil }
            try await press("dataCompareDescribe", in: window)
            try await waitFor("The real data columns did not load.") { data.metadataMatches || data.error != nil }
            try #require(data.error == nil && data.originals == "allColumns")
            let keyIndex = try #require(data.mappings.firstIndex { $0.source == "id" })
            try await press("dataCompareKey-\(keyIndex)", in: window)
            try #require(data.mappings[keyIndex].key && data.canCompare)
            try await press("dataCompareStart", in: window)
            try await waitFor("The real data comparison did not complete.") { data.summary != nil || data.error != nil }
            try #require(data.error == nil && data.summary?.comparison.complete == true)
            #expect(data.summary?.comparison.changedRows == 1 && data.summary?.comparison.deletedRows == 1 && data.summary?.comparison.addedRows == 1)
            let dataCaptures = await dataOperations.snapshot().filter { ["data.describe", "data.start"].contains($0) }
            try await press("dataComparePlan", in: window)
            try await waitFor("The real data SQL plan did not open.") { data.planDraft != nil || data.error != nil }
            let dataDraft = try #require(data.planDraft)
            let dataSQL = try await verifyPreview(dataDraft, kind: "data", window: window)
            #expect(dataDraft.plan.steps.count == 3 && dataDraft.plan.steps.allSatisfy { !$0.manual })
            #expect(await dataOperations.snapshot().filter { ["data.describe", "data.start"].contains($0) } == dataCaptures)
            #expect(await dataOperations.snapshot().filter { $0 == "data.plan" }.count == 1)
            #expect(sourceUnchanged())
            try await capture(deepestSheet(window), name: "r27-\(scenario)-data-plan", directory: output)
            let dataCount = workspace.documents.count
            try await press("syncPlanOpen", in: window)
            try await waitFor("Open did not create the disconnected target data SQL draft.") {
                workspace.dataComparison == nil && window.attachedSheet == nil && workspace.documents.count == dataCount + 1
            }
            let dataEditor = try #require(workspace.selectedDocument)
            #expect(dataEditor.profileID == targetID && dataEditor.text == dataSQL && dataEditor.runtime == nil && dataEditor.executions.isEmpty && !dataEditor.isRunning)
            #expect(sourceUnchanged())
            #expect(try await execute(schemaRead, client: control, session: controlSession).rows == originalSchema)
            #expect(try await execute(targetRead, client: control, session: controlSession).rows == originals)
            try await capture(window, name: "r27-\(scenario)-data-target-editor", directory: output)
            await schema.close(); await data.close()
            await workspace.shutdown()
            await cleanupFixture()
            _ = await control.shutdown()
        } catch {
            try? await capture(deepestSheet(window), name: "r27-\(scenario)-failure", directory: output)
            await workspace.shutdown()
            await cleanupFixture()
            _ = await control.shutdown()
            throw error
        }
    }
}
