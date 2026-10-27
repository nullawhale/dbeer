import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

/// Exercises the production workspace in an owned native window. Artifacts and
/// profile metadata are isolated; no database, Keychain or external
/// Accessibility permission is required. Run only with explicit UI permission.
@Suite(.serialized)
@MainActor
struct ResultSnapshotUIIntegrationTests {
    private struct NativeElement {
        let object: NSObject
        func value<T>(_ name: String) -> T? {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector) else { return nil }
            return object.perform(selector)?.takeUnretainedValue() as? T
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
            let value: String? = self.value("accessibilityValue")
            let attributed: NSAttributedString? = self.value("accessibilityValue")
            return [label, value, attributed?.string].compactMap { $0 }.joined(separator: " ")
        }
    }

    private func elements(in window: NSWindow) -> [NativeElement] {
        var result: [NativeElement] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: AnyObject) {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return }
            if let object = object as? NSObject {
                let element = NativeElement(object: object)
                result.append(element)
                let children: [Any] = element.value("accessibilityChildren") ?? []
                for child in children { visit(child as AnyObject) }
            }
            if let view = object as? NSView { view.subviews.forEach { visit($0) } }
        }
        visit(window)
        if let content = window.contentView { visit(content) }
        if let sheet = window.attachedSheet {
            visit(sheet)
            if let content = sheet.contentView { visit(content) }
        }
        return result
    }

    private func waitFor(_ description: String, diagnostics: @MainActor () -> String,
                         condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), "Timed out waiting for \(description). \(diagnostics())")
        try await Task.sleep(for: .milliseconds(120))
    }

    private func diagnostics(workspace: ApplicationWorkspace, window: NSWindow) -> String {
        let document = workspace.selectedDocument
        let identifiers = elements(in: window).compactMap(\.identifier)
        let counts = Dictionary(identifiers.map { ($0, 1) }, uniquingKeysWith: +)
            .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        return "selectedSnapshot=\(document?.isSnapshot == true), selectedSQL=\(document?.isSQLDocument == true), " +
            "available=\(document?.snapshotModel?.isAvailable == true), loading=\(document?.snapshotModel?.isLoading == true), " +
            "hasManifest=\(document?.snapshotModel?.manifest != nil), hasLocalError=\(document?.snapshotModel?.error != nil), " +
            "sheetFlag=\(workspace.isSnapshotsPresented), attachedSheet=\(window.attachedSheet != nil), " +
            "windowVisible=\(window.isVisible), identifiers=[\(counts)]"
    }

    private func captureFixtureWindow(_ window: NSWindow, directory: URL) throws -> String {
        let view = try #require(window.contentView?.superview ?? window.contentView)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "snapshot-ui-failure-\(UUID().uuidString).png"
        try png.write(to: directory.appendingPathComponent(name))
        return name
    }

    private func element(_ id: String, in window: NSWindow) throws -> NativeElement {
        try #require(elements(in: window).first { $0.identifier == id }, "Missing snapshot control: \(id)")
    }

    private func press(_ id: String, in window: NSWindow) async throws {
        let element = try element(id, in: window)
        let button = (element.object as? NSButton) ?? ((element.object as? NSCell)?.controlView as? NSButton)
        if let button, button.isEnabled { button.performClick(nil) }
        else {
            try #require(element.flag("isAccessibilityEnabled", fallback: true) && element.flag("accessibilityPerformPress"),
                "Snapshot control could not be pressed: \(id)")
        }
        try await Task.sleep(for: .milliseconds(120))
    }

    @Test func nativePinOpenDraftReopenAndMissingArtifactFollowTheOfflineWorkflow() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/r15/ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ResultSnapshotsModel(store: ResultSnapshotStore(rootURL: root))
        let savedProfile = SavedConnection(name: "Historical fixture", settings: ConnectionSettings(host: "fixture.test",
            port: 5432, database: "fixture", user: "reader", password: "", sslMode: "disable",
            policy: ExecutionPolicy(environment: .staging)))
        var helperStarts = 0
        let workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
                SavedConnectionLibrary(connections: [savedProfile], selectedConnectionId: savedProfile.id)),
            credentialStore: MemoryConnectionCredentialStore(), resultSnapshots: manager,
            closeDecision: { _ in .discard }, helperFactory: {
                helperStarts += 1
                return BackendClient(executableURL: root.appendingPathComponent("unused-helper"))
            })
        await workspace.restoreSavedWorkspace()
        await workspace.library.loadConnections()
        let document = workspace.newDocument(profileID: savedProfile.id, text: "SELECT captured_fixture;")
        let reply = BackendMessage(type: "query.result", requestId: "ui-fixture", columns: [
            ResultColumn(index: 0, name: "exact", engine: .postgresql, nativeType: "numeric")],
            rows: [["9007199254740993.000000001"], [nil]], commandTag: "SELECT 7", rowCount: 7,
            displayedRowCount: 2, truncated: true)
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_123)
        let source = try #require(ResultSnapshotSource(sql: document.text, profileID: savedProfile.id,
            profile: SQLHistoryProfile(savedProfile), completion: WorkspaceModel.QueryCompletion(startedAt: capturedAt,
                finishedAt: capturedAt, durationMs: 1, reply: reply, failure: nil)))
        document.executions = [SQLExecution(sql: document.text, range: NSRange(location: 0, length: document.text.utf16.count),
            status: "Completed", result: reply, snapshotSource: source)]
        let application = NSApplication.shared
        application.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        application.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXManualAccessibility"))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1240, height: 780),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "DBeer offline result snapshot verification"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ApplicationWorkspaceView(workspace: workspace).preferredColorScheme(.dark))
        workspace.presentationWindow = window
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let state: @MainActor @Sendable () -> String = { diagnostics(workspace: workspace, window: window) }
        do {
            try await waitFor("the Pin Result button", diagnostics: state) {
                elements(in: window).contains { $0.identifier == "pinQueryResult" }
            }
            try await press("pinQueryResult", in: window)
            try await waitFor("one saved artifact", diagnostics: state) { manager.snapshots.count == 1 }
            let saved = try #require(manager.snapshots.first)
            workspace.isSnapshotsPresented = true
            try await waitFor("the snapshot manager open action", diagnostics: state) {
                elements(in: window).contains { $0.identifier == "openSnapshot-\(saved.id.uuidString)" }
            }
            try await press("openSnapshot-\(saved.id.uuidString)", in: window)
            try await waitFor("the dismissed manager and rendered offline snapshot provenance", diagnostics: state) {
                guard workspace.selectedDocument?.snapshotModel?.isAvailable == true,
                      !workspace.isSnapshotsPresented, window.attachedSheet == nil else { return false }
                let visible = elements(in: window)
                return ["snapshotCapturedAt", "snapshotOutcome", "snapshotPartialNotice", "openSnapshotSQLInNewTab"]
                    .allSatisfy { id in visible.contains { $0.identifier == id } }
            }
            let snapshot = try #require(workspace.selectedDocument)
            #expect(snapshot.snapshotID == saved.id && snapshot.runtime == nil && helperStarts == 0)
            #expect(snapshot.snapshotModel?.manifest?.capturedAt == capturedAt)
            #expect(try element("snapshotCapturedAt", in: window).text.contains(
                capturedAt.formatted(.dateTime.year().month().day().hour().minute().second())))
            #expect(try element("snapshotOutcome", in: window).text.contains("Completed"))
            #expect(try element("snapshotPartialNotice", in: window).text.contains("Partial result"))
            #expect(elements(in: window).allSatisfy { $0.identifier != "runQuery" && $0.identifier != "documentConnection" })
            try await press("openSnapshotSQLInNewTab", in: window)
            try await waitFor("the separate SQL draft", diagnostics: state) { workspace.selectedDocument?.isSQLDocument == true }
            let draft = try #require(workspace.selectedDocument)
            #expect(draft.id != document.id && draft.profileID == nil && draft.text == source.sql)
            #expect(draft.runtime == nil && helperStarts == 0 && workspace.library.selectedConnectionId == savedProfile.id)
            try await press("closeDocument-\(draft.id.uuidString)", in: window)
            try await press("closeDocument-\(snapshot.id.uuidString)", in: window)
            let reopened = try #require(workspace.reopenClosedTab())
            try await waitFor("the reopened local snapshot", diagnostics: state) { reopened.snapshotModel?.isAvailable == true }
            #expect(reopened.snapshotID == saved.id && reopened.id != snapshot.id && helperStarts == 0)
            try await manager.store.delete(id: saved.id)
            await reopened.snapshotModel?.load()
            try await waitFor("the unavailable artifact explanation", diagnostics: state) {
                elements(in: window).contains { $0.identifier == "snapshotUnavailable" }
            }
            #expect(reopened.snapshotModel?.result == nil && reopened.runtime == nil && helperStarts == 0)
            #expect(!(try element("openSnapshotSQLInNewTab", in: window)).flag("isAccessibilityEnabled", fallback: true))
            await workspace.shutdown()
        } catch {
            // This owned window contains only the synthetic fixtures declared
            // above. Diagnostics contain identifiers and state, never SQL or
            // result values; the fixture image stays in ignored build output.
            if let name = try? captureFixtureWindow(window, directory: root.deletingLastPathComponent()) {
                print("Snapshot UI fixture failure image: build/r15/" + name)
            }
            await workspace.shutdown()
            throw error
        }
    }
}
