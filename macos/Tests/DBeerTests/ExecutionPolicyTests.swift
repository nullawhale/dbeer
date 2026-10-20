import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct ExecutionPolicyTests {
    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var executed: URL { directory.appendingPathComponent("executed.jsonl") }
        var decision = "confirm"
        var delayConnection = false
        var entered: URL { directory.appendingPathComponent("entered") }
        var release: URL { directory.appendingPathComponent("release") }
        init() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: directory) }
        var commands: [[String: Any]] {
            guard let text = try? String(contentsOf: executed, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        func client() -> BackendClient {
            BackendClient(executableURL: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", """
            import json, sys, time
            from pathlib import Path
            policies = {}
            for line in sys.stdin:
                c = json.loads(line)
                kind = c['type']
                r = {'requestId':c['requestId']}
                if kind == 'hello':
                    r.update(type='hello.ack', protocolVersion=3)
                elif kind == 'connect':
                    if sys.argv[3] == 'delay' and not policies:
                        Path(sys.argv[1]).with_name('entered').touch()
                        deadline = time.monotonic() + 5
                        while not Path(sys.argv[1]).with_name('release').exists() and time.monotonic() < deadline: time.sleep(.005)
                    sid = 'session-' + str(len(policies))
                    policies[sid] = c['connection']['policy']
                    r.update(type='connect.result', sessionId=sid, engine='postgresql', capabilities=['execute','catalog','transactions'], transactionStatus='idle')
                elif kind == 'catalog' and c['catalog']['kind'] == 'completion':
                    print(json.dumps({'type':'query.started','requestId':c['requestId'],'sessionId':c['sessionId'],'queryId':c['queryId']}),flush=True)
                    r.update(type='query.result',sessionId=c['sessionId'],queryId=c['queryId'],transactionStatus='idle',durationMs=1,columns=[],rows=[],commandTag='SELECT 0',rowCount=0,displayedRowCount=0,truncated=False)
                elif kind == 'operation.assess':
                    ops = [{'kind':'destructive' if 'DELETE' in op.get('sql','') else 'write' if op['type']=='changes.apply' else 'read','statements':[]} for op in c['operations']]
                    assessment = {'decision':sys.argv[2],'policy':policies[c['sessionId']],'operations':ops}
                    if sys.argv[2] != 'deny': assessment['authorization'] = 'exact-batch'
                    r.update(type='operation.assessment',sessionId=c['sessionId'],queryId=c['queryId'],assessment=assessment)
                elif kind in ['execute','changes.apply','changes.preview']:
                    if kind != 'changes.preview':
                        with open(sys.argv[1], 'a') as f:
                            f.write(json.dumps(c)+'\\n')
                    print(json.dumps({'type':'query.started','requestId':c['requestId'],'sessionId':c['sessionId'],'queryId':c['queryId']}),flush=True)
                    if c.get('sql') == 'SELECT FAIL':
                        r.update(type='error',sessionId=c['sessionId'],queryId=c['queryId'],category='sql',message='Fixture error.',connected=True,outcomeUnknown=False,transactionStatus='idle')
                    else:
                        r.update(type='query.result',sessionId=c['sessionId'],queryId=c['queryId'],transactionStatus='transaction' if c.get('sql')=='BEGIN' else 'idle',durationMs=1,columns=[],rows=[],commandTag='SELECT 0',rowCount=0,displayedRowCount=0,truncated=False)
                        if kind == 'changes.preview':
                            r.update(columns=[{'index':i,'name':n} for i,n in enumerate(['operation','sql','parameters'])],rows=[['update','UPDATE public.demo SET label=$1 WHERE id=$2','[{"kind":"text","value":"changed"}]']],rowCount=1,displayedRowCount=1)
                elif kind == 'cancel':
                    r.update(type='cancel.ack',sessionId=c['sessionId'],queryId=c['queryId'],status='alreadyFinished')
                elif kind == 'disconnect':
                    r.update(type='disconnect.ack',sessionId=c['sessionId'])
                elif kind == 'shutdown':
                    r.update(type='shutdown.ack')
                else:
                    sys.exit(40)
                print(json.dumps(r),flush=True)
                if kind == 'shutdown': break
            """, executed.path, decision, delayConnection ? "delay" : "immediate"])
        }
    }

    private final class CloseState {
        var decision = WorkspaceCloseDecision.cancel
        var issues: [WorkspaceCloseIssue] = []
    }

    private func setup(_ fixture: Fixture, readOnly: Bool = false,
                       close: @escaping @MainActor (WorkspaceCloseIssue) async -> WorkspaceCloseDecision = { _ in .rollback },
                       decide: @escaping @MainActor (OperationConfirmation) async -> Bool) async throws -> (ApplicationWorkspace, SQLDocument) {
        let client = fixture.client()
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore(), closeDecision: close,
            executionDecision: decide, helperFactory: { client })
        await workspace.start()
        try #require(await workspace.library.saveConnection(name: "Production fixture", settings: ConnectionSettings(
            host: "localhost", port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable",
            policy: ExecutionPolicy(environment: .production, readOnly: readOnly))))
        let id = try #require(workspace.library.selectedConnectionId)
        let document = workspace.newDocument(profileID: id, text: "-- entire source\nSELECT 1; DELETE FROM demo; SELECT 3;")
        return (workspace, document)
    }

    @Test func cancelReviewsWholeScriptOnceAndSendsNoUserCommand() async throws {
        let fixture = try Fixture()
        var confirmations: [OperationConfirmation] = []
        let (workspace, document) = try await setup(fixture) { confirmations.append($0); return false }
        await workspace.runScript(document)
        #expect(confirmations.count == 1)
        #expect(confirmations.first?.isScript == true)
        #expect(confirmations.first?.operations.count == 3)
        #expect(confirmations.first?.sourceSQL == document.text)
        #expect(confirmations.first?.assessment.operations.map(\.kind) == ["read", "destructive", "read"])
        #expect(fixture.commands.isEmpty)
        #expect(document.executions.allSatisfy { $0.status == "Not executed" })
        await workspace.shutdown()
    }

    @Test func nativeReturnAndEscapeCancelWholeWorkspaceScriptWithoutSendingSQL() async throws {
        NSApplication.shared.activate(ignoringOtherApps: true)
        for _ in 0..<20 where !NSApplication.shared.isActive {
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(NSApplication.shared.isActive)
        for (characters, keyCode) in [("\r", UInt16(36)), ("\u{1b}", UInt16(53))] {
            let fixture = try Fixture()
            let (workspace, document) = try await setup(fixture, decide: ExecutionConfirmation.present)
            let captured = ModalCapture()
            let eventTimer = Timer(timeInterval: 0.15, repeats: false) { _ in
                MainActor.assumeIsolated {
                    do {
                        let window = try #require(NSApplication.shared.modalWindow)
                        NSApplication.shared.activate(ignoringOtherApps: true)
                        window.makeKeyAndOrderFront(nil)
                        captured.cancelIsDefault = window.defaultButtonCell?.title == "Cancel"
                        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
                        NSApplication.shared.postEvent(event, atStart: true)
                    } catch {
                        captured.error = error
                        NSApplication.shared.abortModal()
                    }
                }
            }
            let fallback = Timer(timeInterval: 1, repeats: false) { _ in
                MainActor.assumeIsolated {
                    captured.fallbackUsed = true
                    NSApplication.shared.abortModal()
                }
            }
            defer {
                eventTimer.invalidate()
                fallback.invalidate()
                Task { await workspace.shutdown() }
            }
            RunLoop.main.add(eventTimer, forMode: .modalPanel)
            RunLoop.main.add(fallback, forMode: .modalPanel)
            await workspace.runScript(document)
            eventTimer.invalidate()
            fallback.invalidate()
            if let error = captured.error { throw error }
            #expect(captured.cancelIsDefault && !captured.fallbackUsed, "Key code \(keyCode) must cancel through the native event")
            #expect(fixture.commands.isEmpty)
            #expect(document.executions.allSatisfy { $0.status == "Not executed" })
            await workspace.shutdown()
        }
    }

    @Test func changedSQLOrProfileAfterAwaitingConfirmationCannotExecute() async throws {
        for changeProfile in [false, true] {
            let fixture = try Fixture()
            var mutate: (@MainActor () async -> Void)?
            let (workspace, document) = try await setup(fixture) { _ in
                await Task.yield()
                await mutate?()
                return true
            }
            mutate = {
                if changeProfile {
                    let profile = workspace.library.savedConnections[0]
                    var settings = profile.settings(password: "")
                    settings.policy.environment = .staging
                    _ = await workspace.library.saveConnection(name: profile.name, settings: settings, id: profile.id)
                } else { document.text += " DELETE FROM changed;" }
            }
            await workspace.runScript(document)
            #expect(fixture.commands.isEmpty)
            #expect(document.executions.allSatisfy { $0.status == "Not executed" })
            await workspace.shutdown()
        }
    }

    @Test func helperDenyNeverPresentsConfirmationOrSendsSQL() async throws {
        let fixture = try Fixture()
        fixture.decision = "deny"
        var confirmations = 0
        let (workspace, document) = try await setup(fixture, readOnly: true) { _ in confirmations += 1; return true }
        await workspace.runScript(document)
        #expect(confirmations == 0 && fixture.commands.isEmpty)
        #expect(document.localError?.contains("Readonly") == true)
        #expect(document.executions.allSatisfy { $0.status == "Not executed" })
        await workspace.shutdown()
    }

    @Test func editDuringInitialConnectionInvalidatesTheOriginalScript() async throws {
        let fixture = try Fixture()
        fixture.delayConnection = true
        var confirmations = 0
        let (workspace, document) = try await setup(fixture) { _ in confirmations += 1; return true }
        let task = Task { await workspace.runScript(document) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !FileManager.default.fileExists(atPath: fixture.entered.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(FileManager.default.fileExists(atPath: fixture.entered.path))
        document.text = "SELECT 'changed during connection';"
        try Data().write(to: fixture.release)
        await task.value
        #expect(confirmations == 0 && fixture.commands.isEmpty)
        #expect(document.localError?.contains("changed while connecting") == true)
        await workspace.shutdown()
    }

    @Test func executeSelectionWithMultipleStatementsUsesWholeBatchPreview() async throws {
        let fixture = try Fixture()
        fixture.decision = "allow"
        var confirmations: [OperationConfirmation] = []
        let (workspace, document) = try await setup(fixture) { confirmations.append($0); return false }
        defer { Task { await workspace.shutdown() } }
        document.text = "SELECT 1; INSERT INTO demo VALUES(1);"
        document.selection = NSRange(location: 0, length: document.text.utf16.count)
        await workspace.run(document)
        #expect(confirmations.count == 1)
        let confirmation = try #require(confirmations.first)
        #expect(confirmation.isScript)
        #expect(confirmation.sourceSQL == document.text)
        #expect(confirmation.operations.count == 2)
        #expect(fixture.commands.isEmpty)
        await workspace.shutdown()
    }

    @Test func changedSessionAfterAwaitingConfirmationCannotExecute() async throws {
        let fixture = try Fixture()
        var mutate: (@MainActor () async -> Void)?
        let (workspace, document) = try await setup(fixture) { _ in await mutate?(); return true }
        mutate = { await document.runtime?.disconnect() }
        await workspace.runScript(document)
        #expect(fixture.commands.isEmpty)
        await workspace.shutdown()
    }

    @Test func policyEditDisconnectWorkflowKeepsOpenTransactionUntilExplicitRollback() async throws {
        let fixture = try Fixture()
        fixture.decision = "allow"
        let state = CloseState()
        let (workspace, document) = try await setup(fixture, close: { state.issues.append($0); return state.decision }) { _ in true }
        await workspace.run(document, sql: "BEGIN")
        try #require(document.runtime?.transactionStatus == .transaction)
        let profile = try #require(workspace.library.savedConnections.first)
        #expect(!(await workspace.disconnectProfile(profile.id)))
        #expect(document.runtime?.transactionStatus == .transaction)
        #expect(state.issues == [.transaction(document.title, failed: false)])
        #expect(fixture.commands.compactMap { $0["sql"] as? String } == ["BEGIN"])
        #expect(workspace.library.savedConnections.first?.policy == profile.policy)
        state.decision = .rollback
        #expect(await workspace.disconnectProfile(profile.id))
        #expect(fixture.commands.compactMap { $0["sql"] as? String } == ["BEGIN", "ROLLBACK"])
        var settings = profile.settings(password: "")
        settings.policy.readOnly = true
        settings.policy.environment = .staging
        #expect(await workspace.library.saveConnection(name: profile.name, settings: settings, id: profile.id))
        await workspace.run(document, sql: "SELECT 1")
        #expect(document.runtime?.policy == settings.policy)
        #expect(document.runtime?.transactionStatus == .idle)
        await workspace.shutdown()
    }

    @Test func applyShowsGeneratedSQLAndRejectsChangedSnapshotAfterConfirmation() async throws {
        let fixture = try Fixture()
        var mutation: (@MainActor () -> Void)?
        var confirmations: [OperationConfirmation] = []
        let (workspace, document) = try await setup(fixture) { confirmation in
            confirmations.append(confirmation)
            mutation?()
            return true
        }
        await workspace.run(document, sql: "SELECT 1")
        let result = BackendMessage(type: "query.result", requestId: "fixture", columns: [ResultColumn(index: 0, name: "id"), ResultColumn(index: 1, name: "label")], rows: [["1", "original"]])
        let grid = GridDraft(reference: TableReference(schema: "public", name: "demo", kind: "table"), result: result,
            metadata: [["name":"id","primaryKey":"1","editable":"true"], ["name":"label","editable":"true"]])
        document.table = grid.reference
        document.attachGrid(grid)
        grid.set(ChangeValue(kind: "text", value: "changed"), row: 0, column: 1)
        mutation = { grid.rows[0].assignments[1] = ChangeValue(kind: "text", value: "changed after confirmation") }
        #expect(!(await workspace.applyGrid(document)))
        let confirmation = try #require(confirmations.last)
        #expect(confirmation.generatedPreview?.contains("UPDATE public.demo SET label=$1 WHERE id=$2") == true)
        #expect(confirmation.operations.first?.changes?.changes.first?.values?.first?.value.value == "changed")
        #expect(!fixture.commands.contains { $0["type"] as? String == "changes.apply" })
        #expect(grid.pendingCount == 1)
        await workspace.shutdown()
    }

    @Test func scriptUsesOneBatchGrantAndStopsAtFirstError() async throws {
        let fixture = try Fixture()
        var confirmations = 0
        let (workspace, document) = try await setup(fixture) { _ in confirmations += 1; return true }
        document.text = "SELECT 1; SELECT FAIL; DELETE FROM never_sent;"
        await workspace.runScript(document)
        #expect(confirmations == 1)
        #expect(fixture.commands.compactMap { $0["sql"] as? String } == ["SELECT 1", "SELECT FAIL"])
        #expect(fixture.commands.allSatisfy { $0["authorization"] as? String == "exact-batch" })
        #expect(document.executions[2].status == "Skipped")
        await workspace.shutdown()
    }

    @Test func nativeConfirmationShowsExactSQLContextAndUsesCancelAsReturnDefault() throws {
        _ = NSApplication.shared
        let settings = ConnectionSettings(host: "prod.example", port: 5432, database: "warehouse", user: "analyst", password: "", sslMode: "verify-full", policy: ExecutionPolicy(environment: .production))
        let sql = "SELECT 'Unicode 🌍';\nDELETE FROM demo;"
        let operations = [OperationRequest(type: "execute", sql: sql)]
        let assessment = OperationAssessment(decision: "confirm", policy: settings.policy,
            operations: [AssessedOperation(kind: "destructive", statements: [StatementAssessment(start: "SELECT 'Unicode 🌍';\n".utf8.count, end: sql.utf8.count - 1, kind: "destructive", reason: "destructive_statement")])], authorization: "grant")
        let alert = ExecutionConfirmation.makeAlert(OperationConfirmation(profile: SavedConnection(name: "Warehouse", settings: settings), operations: operations, assessment: assessment, isScript: true, sourceSQL: sql))
        let scroll = try #require(alert.accessoryView as? NSScrollView)
        let text = try #require(scroll.documentView as? NSTextView)
        #expect(text.string.contains(sql))
        #expect(alert.informativeText.components(separatedBy: "\n").contains("prod"))
        #expect(alert.informativeText.contains("prod.example:5432/warehouse"))
        #expect(alert.buttons[1].title == "Cancel" && alert.buttons[1].keyEquivalent == "\r")
        #expect(!text.isEditable && text.isSelectable && text.isVerticallyResizable)
        let dangerRange = (text.string as NSString).range(of: "DELETE FROM demo", options: .backwards)
        #expect(dangerRange.location != NSNotFound)
        #expect(text.textStorage?.attribute(.backgroundColor, at: dangerRange.location, effectiveRange: nil) as? NSColor == NSColor.systemRed.withAlphaComponent(0.14))
        #expect(text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor.systemRed)
    }

    @Test func profilePolicySurvivesTransferAndReadonlyDisablesGridMutation() throws {
        let settings = ConnectionSettings(host: "localhost", port: 5432, database: "fixture", user: "fixture", password: "secret", sslMode: "disable", policy: ExecutionPolicy(environment: .staging, readOnly: true))
        let imported = try ProfileTransfer.preview(ProfileTransfer.encode([SavedConnection(name: "Readonly", settings: settings)]))
        #expect(imported[0].profile.policy == settings.policy)
        let result = BackendMessage(type: "query.result", requestId: "fixture", columns: [ResultColumn(index: 0, name: "id")], rows: [["1"]])
        let grid = GridDraft(reference: TableReference(schema: "public", name: "demo", kind: "table"), result: result,
            metadata: [["name":"id","primaryKey":"1","editable":"true"]])
        grid.policyReadOnly = true
        grid.set(ChangeValue(kind: "text", value: "2"), row: 0, column: 0)
        grid.insert()
        grid.selectedRows = [0]
        grid.deleteSelected()
        #expect(!grid.canEdit && grid.pendingCount == 0 && grid.displayedRows == [["1"]])
    }

    private func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    private func accessibilityObjects(_ root: NSObject) -> [NSObject] {
        var result: [NSObject] = []
        var visited: Set<ObjectIdentifier> = []
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] {
                children.forEach(visit)
            }
            (object as? NSView)?.subviews.forEach(visit)
        }
        visit(root)
        return result
    }

    private func accessibilityIdentifier(_ object: NSObject) -> String? {
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private func capture(_ view: NSView, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let composite = NSImage(size: view.bounds.size)
        composite.lockFocus()
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: view.bounds.size)).fill()
            bitmap.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        }
        composite.unlockFocus()
        let flattened = try #require(composite.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try #require(flattened.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("r23-\(name).png"))
    }

    @MainActor private final class ModalCapture {
        var error: Error?
        var cancelIsDefault = false
        var fallbackUsed = false
        var fallbackTimer: Timer?
    }

    private func capture(_ window: NSWindow, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] else { return }
        // Capture only this process's test-owned alert. WindowServer preserves
        // real modal vibrancy and button materials that cacheDisplay loses.
        // The symbol remains available on macOS 14+ although newer SDKs remove
        // its Swift declaration; this compatibility bridge is QA-only.
        typealias WindowCapture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let library = try #require(dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW))
        defer { dlclose(library) }
        let capture = unsafeBitCast(try #require(dlsym(library, "CGWindowListCreateImage")), to: WindowCapture.self)
        let image = try #require(capture(.null, CGWindowListOption.optionIncludingWindow.rawValue,
            UInt32(window.windowNumber), CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue())
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("r23-\(name).png"))
    }

    @Test func nativePolicyControlsAndFullSQLConfirmationRemainAccessibleAndFocusableInBothThemes() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        application.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        application.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(),
            credentialStore: MemoryConnectionCredentialStore())
        let settings = ConnectionSettings(host: "prod.example", port: 5432, database: "warehouse", user: "analyst", password: "", sslMode: "verify-full",
            policy: ExecutionPolicy(environment: .production, readOnly: true))
        try #require(await workspace.library.saveConnection(name: "Warehouse", settings: settings))
        let profile = try #require(workspace.library.savedConnections.first)
        let policy = NativeButtonFocusPolicy()
        for (theme, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua), ("dark", .dark, .darkAqua)] {
            let host = NSHostingView(rootView: ConnectionEditorView(model: workspace.library, connection: profile) {}
                .background(AppPalette.background).preferredColorScheme(scheme).tint(AppPalette.accent))
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 650, height: 840),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            application.activate(ignoringOtherApps: true)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(180))
            host.layoutSubtreeIfNeeded()
            let objects = accessibilityObjects(host)
            for identifier in ["connectionEnvironment", "connectionReadOnly"] {
                #expect(objects.contains { accessibilityIdentifier($0) == identifier }, "Missing policy accessibility element \(identifier)/\(theme)")
            }
            let controls = descendants(host, of: NSControl.self).filter {
                ($0 is NSButton || $0 is NSTextField || $0 is NSSegmentedControl) &&
                    $0.isEnabled && $0.acceptsFirstResponder && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
            }
            #expect(!controls.isEmpty)
            for control in controls {
                window.makeKeyAndOrderFront(nil)
                #expect(window.makeFirstResponder(control))
                policy.apply(to: window)
                #expect(control.focusRingType == .none)
                #expect(control.cell?.focusRingType == NSFocusRingType.none)
            }
            for toggle in descendants(host, of: NSSwitch.self) where toggle.isEnabled {
                #expect(window.makeFirstResponder(toggle))
                let center = toggle.convert(NSPoint(x: toggle.bounds.midX, y: toggle.bounds.midY), to: host)
                let feedback = try #require(descendants(host, of: ControlFeedbackView.self).filter {
                    $0.convert($0.bounds, to: host).contains(center)
                }.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
                let parent = try #require(toggle.superview)
                let alignment = parent.convert(toggle.alignmentRect(forFrame: toggle.frame), to: feedback)
                #expect(feedback.bounds.contains(alignment), "Readonly keyboard and hover feedback must enclose the entire native switch")
                let state = toggle.state
                toggle.performClick(nil)
                #expect(toggle.state != state)
                toggle.performClick(nil)
                #expect(toggle.state == state)
            }
            try capture(host, name: "policy-controls-\(theme)")
            window.close()

            let sql = "-- Entire script, including the final command\nSELECT 'Unicode 🌍';\nUPDATE public.orders SET status = 'archived' WHERE id = 42;\nDELETE FROM public.orders WHERE id = 43;"
            let operations = [OperationRequest(type: "execute", sql: sql)]
            var confirmationProfile = profile
            confirmationProfile.policy.readOnly = false
            let updateStart = sql[..<(try #require(sql.range(of: "UPDATE public"))).lowerBound].utf8.count
            let deleteStart = sql[..<(try #require(sql.range(of: "DELETE FROM"))).lowerBound].utf8.count
            let assessment = OperationAssessment(decision: "confirm", policy: confirmationProfile.policy,
                operations: [AssessedOperation(kind: "destructive", statements: [
                    StatementAssessment(start: 0, end: updateStart, kind: "read", reason: "read_statement"),
                    StatementAssessment(start: updateStart, end: deleteStart - 1, kind: "write", reason: "write_statement"),
                    StatementAssessment(start: deleteStart, end: sql.utf8.count, kind: "destructive", reason: "destructive_statement"),
                ])], authorization: "fixture")
            let alert = ExecutionConfirmation.makeAlert(OperationConfirmation(profile: confirmationProfile, operations: operations,
                assessment: assessment, isScript: true, sourceSQL: sql))
            let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            alert.icon = NSImage(contentsOf: repository.appendingPathComponent("build/DBeer.app/Contents/Resources/\(theme == "dark" ? "AppIconDark" : "AppIcon").icns"))
            alert.window.appearance = NSAppearance(named: appearance)
            alert.layout()
            alert.window.makeKeyAndOrderFront(nil)
            defer { alert.window.close() }
            let text = try #require((alert.accessoryView as? NSScrollView)?.documentView as? NSTextView)
            #expect(text.string.contains(sql))
            #expect(text.accessibilityIdentifier() == "executionSQLPreview")
            #expect(text.accessibilityLabel() == "Entire operation preview")
            #expect(text.isSelectable && !text.isEditable)
            let cancel = alert.buttons[1]
            #expect(alert.window.defaultButtonCell === cancel.cell)
            #expect(alert.window.makeFirstResponder(cancel))
            #expect(cancel.keyEquivalent == "\r" && alert.buttons[0].keyEquivalent.isEmpty)
            #expect(alert.window.makeFirstResponder(text))
            text.setSelectedRange(NSRange(location: 0, length: text.string.utf16.count))
            #expect(text.selectedRange().length == text.string.utf16.count)
            text.setSelectedRange(NSRange(location: 0, length: 0))
            #expect(alert.window.makeFirstResponder(cancel))
            policy.apply(to: alert.window)
            for (key, characters, keyCode) in [("return", "\r", UInt16(36)), ("escape", "\u{1b}", UInt16(53))] {
                let captured = ModalCapture()
                let fallback = Timer(timeInterval: 0.8, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        captured.fallbackUsed = true
                        cancel.performClick(nil)
                    }
                }
                captured.fallbackTimer = fallback
                let timer = Timer(timeInterval: 0.15, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        captured.cancelIsDefault = alert.window.defaultButtonCell === cancel.cell
                        do {
                            if key == "return" { try capture(alert.window, name: "full-sql-confirmation-\(theme)") }
                            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: alert.window.windowNumber,
                                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
                            // WindowServer capture and PNG encoding can consume
                            // the deadline; measure native event delivery only.
                            captured.fallbackTimer?.fireDate = Date(timeIntervalSinceNow: 0.8)
                            application.postEvent(event, atStart: true)
                        } catch {
                            captured.error = error
                            cancel.performClick(nil)
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .modalPanel)
                RunLoop.main.add(fallback, forMode: .modalPanel)
                let response = ExecutionConfirmation.runModal(alert)
                timer.invalidate()
                fallback.invalidate()
                captured.fallbackTimer = nil
                if let error = captured.error { throw error }
                #expect(captured.cancelIsDefault && !captured.fallbackUsed, "\(key)/\(theme) must cancel through its actual native event")
                #expect(response == .alertSecondButtonReturn)
            }
            alert.window.close()
        }
        await workspace.shutdown()
    }
}
