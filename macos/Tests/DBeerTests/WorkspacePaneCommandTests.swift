import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import DBeer

/// Injected contexts exercise pane routing without creating native windows.
@Suite(.serialized)
@MainActor
struct WorkspacePaneCommandTests {
    @MainActor private final class Invocations { var values: [AppCommandInvocation] = [] }

    @MainActor private struct Fixture {
        let defaultsName = "dev.dbeer.tests.pane-commands.\(UUID().uuidString)"
        let defaults: UserDefaults
        let shortcuts: AppShortcutStore
        let workspace: ApplicationWorkspace
        let profile: SavedConnection
        let captured = Invocations()
        let registry: AppCommandRegistry

        init() throws {
            defaults = try #require(UserDefaults(suiteName: defaultsName))
            shortcuts = AppShortcutStore(defaults: defaults)
            profile = SavedConnection(name: "Pane fixture", settings: ConnectionSettings(host: "fixture.invalid",
                port: 5432, database: "fixture", user: "fixture", password: "", sslMode: "disable"))
            workspace = ApplicationWorkspace(connectionStore: MemoryConnectionLibraryStore(library:
                SavedConnectionLibrary(connections: [profile], selectedConnectionId: profile.id)),
                credentialStore: MemoryConnectionCredentialStore(), documentStore: MemorySQLDocumentStore(),
                commandShortcuts: shortcuts, sqlFolders: SQLFolderLibrary(automaticallyRefresh: false),
                automaticallyWatchFiles: false, closeDecision: { _ in .discard })
            let captured = captured
            registry = AppCommandRegistry(workspace: workspace, shortcuts: shortcuts) { captured.values.append($0) }
        }

        func context(_ document: SQLDocument?, focus: AppCommandFocus = .sqlEditor,
                     modal: Bool = false, foreign: Bool = false, composing: Bool = false) -> AppCommandContext {
            AppCommandContext(documentID: document?.id, focus: focus, isWorkspaceWindow: !foreign,
                hasModal: modal, isComposingText: composing)
        }
    }

    @Test func bothVisibleSelectionsResolveAndHiddenTabsStayIneligible() async throws {
        let fixture = try Fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        await fixture.workspace.restoreSavedWorkspace()
        await fixture.workspace.library.loadConnections()
        let left = fixture.workspace.newDocument(profileID: fixture.profile.id, text: "SELECT 11;", in: .left)
        let hidden = fixture.workspace.newDocument(profileID: fixture.profile.id, text: "SELECT 12;", in: .left)
        let right = fixture.workspace.newDocument(profileID: fixture.profile.id, text: "SELECT 21;", in: .right)
        fixture.workspace.selectDocument(left.id, in: .left)
        for document in [left, right] {
            #expect(fixture.registry.canPerform(.runCurrent, context: fixture.context(document)))
            #expect(fixture.registry.canPerform(.saveSQL, context: fixture.context(document, focus: .textInput)))
        }
        for command: AppCommandID in [.runCurrent, .runScript, .runToJSON, .runToCSV, .saveSQL, .closeTab] {
            #expect(!fixture.registry.canPerform(command, context: fixture.context(hidden)))
            #expect(fixture.registry.perform(command, context: fixture.context(hidden)) == nil)
        }
        let task = try #require(fixture.registry.perform(.runCurrent, context: fixture.context(right)))
        #expect(fixture.workspace.activePaneID == .right)
        fixture.workspace.activatePane(.left)
        fixture.workspace.moveDocument(right.id, to: .left)
        await task.value
        #expect(fixture.captured.values.map(\.documentID) == [right.id])
        #expect(fixture.captured.values.first?.fragment?.sourceSQL == "SELECT 21")
        #expect(left.runtime == nil && right.runtime == nil)
        await fixture.workspace.shutdown()
    }

    @Test func everyExecutionCommandCapturesTheExplicitVisibleDocumentBeforePaneChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        await fixture.workspace.restoreSavedWorkspace()
        await fixture.workspace.library.loadConnections()
        let left = fixture.workspace.newDocument(profileID: fixture.profile.id, text: "SELECT 11;\nSELECT 12;", in: .left)
        let right = fixture.workspace.newDocument(profileID: fixture.profile.id, text: "SELECT 21;\nSELECT 22;", in: .right)
        left.selection = (left.text as NSString).range(of: "SELECT 12")
        right.selection = (right.text as NSString).range(of: "SELECT 22")
        for command: AppCommandID in [.runCurrent, .runScript, .runToJSON, .runToCSV, .stop] {
            left.isRunning = command == .stop
            right.isRunning = command == .stop
            fixture.workspace.activatePane(.right)
            let task = try #require(fixture.registry.perform(command, context: fixture.context(left, focus: .workspace)))
            #expect(fixture.workspace.activePaneID == .left)
            fixture.workspace.activatePane(.right)
            await task.value
            let invocation = try #require(fixture.captured.values.last)
            #expect(invocation.documentID == left.id && invocation.profile?.id == fixture.profile.id)
            #expect(invocation.documentText == left.text)
            if command == .runScript { #expect(invocation.fragment?.sourceSQL == left.text) }
            else if command != .stop { #expect(invocation.fragment?.sourceSQL == "SELECT 12") }
            #expect(fixture.workspace.activePaneID == .right)
        }
        left.isRunning = false
        right.isRunning = false
        await fixture.workspace.shutdown()
    }

    @Test func tabNavigationCyclesOnlyTheActivePaneAndSupportsAnEmptyActivePane() async throws {
        let fixture = try Fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        await fixture.workspace.restoreSavedWorkspace()
        let left = fixture.workspace.newDocument(in: .left)
        let right = fixture.workspace.newDocument(in: .right)
        let rightSecond = fixture.workspace.newDocument(in: .right)
        let context = fixture.context(nil, focus: .workspace)
        let next = try #require(fixture.registry.perform(.nextTab, context: context))
        #expect(fixture.workspace.selectedDocument(in: .right) === right)
        #expect(fixture.workspace.selectedDocument(in: .left) === left)
        await next.value
        let previous = try #require(fixture.registry.perform(.previousTab, context: context))
        #expect(fixture.workspace.selectedDocument(in: .right) === rightSecond)
        await previous.value
        fixture.workspace.activatePane(.left)
        #expect(!fixture.registry.canPerform(.nextTab, context: context))
        fixture.workspace.moveDocument(left.id, to: .right)
        fixture.workspace.activatePane(.left)
        #expect(!fixture.registry.canPerform(.nextTab, context: context))
        #expect(fixture.registry.canPerform(.newSQLTab, context: context))
        await fixture.workspace.shutdown()
    }

    @Test func responderRoutingKeepsWindowModalCompositionAndTextInputGuards() async throws {
        let fixture = try Fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        await fixture.workspace.restoreSavedWorkspace()
        await fixture.workspace.library.loadConnections()
        let document = fixture.workspace.newDocument(profileID: fixture.profile.id, in: .left)
        fixture.workspace.newDocument(in: .right)
        for context in [fixture.context(document, modal: true), fixture.context(document, foreign: true),
                        fixture.context(document, composing: true), fixture.context(document, focus: .textInput)] {
            #expect(!fixture.registry.canPerform(.runCurrent, context: context))
            #expect(fixture.registry.perform(.runCurrent, context: context) == nil)
        }
        document.isRunning = true
        #expect(fixture.registry.canPerform(.stop, context: fixture.context(document, focus: .textInput)))
        #expect(!fixture.registry.canPerform(.stop, context: fixture.context(document, modal: true)))
        document.isRunning = false
        await fixture.workspace.shutdown()
    }

    @Test func saveUsesTheResolvedPaneDocumentWithoutOpeningAChooser() async throws {
        let fixture = try Fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/r11/save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let leftURL = root.appendingPathComponent("left.sql")
        let rightURL = root.appendingPathComponent("right.sql")
        try Data("SELECT 1;".utf8).write(to: leftURL)
        try Data("SELECT 2;".utf8).write(to: rightURL)
        await fixture.workspace.restoreSavedWorkspace()
        let left = try #require(await fixture.workspace.openSQLFile(at: leftURL))
        let right = try #require(await fixture.workspace.openSQLFile(at: rightURL))
        fixture.workspace.moveDocument(right.id, to: .right)
        left.text = "SELECT 11;"
        right.text = "SELECT 22;"
        let saved = try #require(fixture.registry.perform(.saveSQL, context: fixture.context(left, focus: .textInput)))
        await saved.value
        #expect(try Data(contentsOf: leftURL) == Data(left.text.utf8))
        #expect(try Data(contentsOf: rightURL) == Data("SELECT 2;".utf8))
        #expect(right.fileDocument?.isDirty == true)
        await fixture.workspace.shutdown()
    }

    @Test func tabTransfersRequireTheCurrentWindowSessionAndAnOwnedOpenDocument() async throws {
        let fixture = try Fixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsName) }
        await fixture.workspace.restoreSavedWorkspace()
        let document = fixture.workspace.newDocument(in: .left)
        let session = UUID()
        let transfer = WorkspaceTabTransfer(workspaceSessionID: session, documentID: document.id)
        let decoded = try JSONDecoder().decode(WorkspaceTabTransfer.self, from: JSONEncoder().encode(transfer))
        #expect(decoded.validatedDocumentID(in: fixture.workspace, sessionID: session) == document.id)
        #expect(decoded.validatedDocumentID(in: fixture.workspace, sessionID: UUID()) == nil)
        #expect(WorkspaceTabTransfer(workspaceSessionID: session, documentID: UUID())
            .validatedDocumentID(in: fixture.workspace, sessionID: session) == nil)
        await fixture.workspace.closeDocument(document)
        #expect(decoded.validatedDocumentID(in: fixture.workspace, sessionID: session) == nil)
        #expect(!UTType.dbeerWorkspaceTab.conforms(to: .plainText))
        await fixture.workspace.shutdown()
    }
}
