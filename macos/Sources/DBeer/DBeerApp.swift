import AppKit
import SwiftUI

@main
struct DBeerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("DBeer", id: "workspace") {
            Group {
                if let workspace = appDelegate.workspace {
                    ApplicationWorkspaceView(workspace: workspace)
                } else { WorkspaceView(model: appDelegate.model) }
            }
                .frame(minWidth: 900, minHeight: 620)
                .task { await appDelegate.start() }
        }
        .defaultSize(width: 1120, height: 760)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            if let workspace = appDelegate.workspace {
                WorkspaceCommands(workspace: workspace)
            } else { ConnectionCommands(model: appDelegate.model) }
        }

        Settings {
            AppearanceSettingsView(appearance: appDelegate.appearance)
        }
    }
}

private struct ConnectionCommands: Commands {
    @ObservedObject var model: WorkspaceModel
    var workspace: ApplicationWorkspace?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Connection…") { model.isConnectionEditorPresented = true }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.isConnectionEditorPresented || model.isSavingConnection)
            Button("New SQL Tab") { workspace?.newDocument() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(workspace == nil)
        }
    }
}

private struct WorkspaceCommands: Commands {
    @ObservedObject var workspace: ApplicationWorkspace
    @FocusedValue(\.focusCatalogSearch) private var focusCatalogSearch

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Connection…") { workspace.library.isConnectionEditorPresented = true }
                .keyboardShortcut("n", modifiers: .command)
            Button("New SQL Tab") { workspace.newDocument() }.keyboardShortcut("t", modifiers: .command)
            Button("Open SQL…") { workspace.openSQLFile() }.keyboardShortcut("o", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save SQL") { if let document = workspace.selectedDocument { workspace.saveSQLFile(document) } }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(workspace.selectedDocument?.table != nil || workspace.selectedDocument == nil)
            Button("Save SQL As…") {
                if let document = workspace.selectedDocument { workspace.saveSQLFile(document, chooseLocation: true) }
            }.keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(workspace.selectedDocument?.table != nil || workspace.selectedDocument == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find in Connections") { focusCatalogSearch?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(focusCatalogSearch == nil)
        }
        CommandMenu("Query") {
            Button("Run Selection or Current Statement") {
                if let document = workspace.selectedDocument { Task { await workspace.run(document) } }
            }.keyboardShortcut(.return, modifiers: .command)
                .disabled(workspace.selectedDocument?.isRunning == true || workspace.selectedDocument?.profileID == nil)
            Button("Run Script") {
                if let document = workspace.selectedDocument { Task { await workspace.runScript(document) } }
            }.keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(workspace.selectedDocument?.isRunning == true || workspace.selectedDocument?.profileID == nil || workspace.selectedDocument?.table != nil)
            Button("Stop") { if let document = workspace.selectedDocument { Task { await workspace.stop(document) } } }
                .disabled(workspace.selectedDocument?.isRunning != true && workspace.selectedDocument?.grid?.isApplying != true)
            Divider()
            Button("SQL History…") { workspace.isHistoryPresented = true }
        }
        CommandMenu("Connections") {
            Button("Import Connections…") { workspace.previewProfileImport() }
            Button("Export Connections…") { workspace.exportProfiles() }
                .disabled(workspace.library.savedConnections.isEmpty)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appearance = AppAppearance()
    let buttonFocusPolicy = NativeButtonFocusPolicy()
    let model: WorkspaceModel
    let workspace: ApplicationWorkspace?
    private let terminationReply: (@MainActor (Bool) -> Void)?
    private var hasStarted = false
    private var isTerminating = false

    override convenience init() {
        let workspace = ApplicationWorkspace(documentStore: FileSQLDocumentStore())
        self.init(model: workspace.library, workspace: workspace)
    }

    init(model: WorkspaceModel,
         workspace: ApplicationWorkspace? = nil,
         terminationReply: (@MainActor (Bool) -> Void)? = nil) {
        self.model = model
        self.workspace = workspace
        self.terminationReply = terminationReply
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buttonFocusPolicy.start()
        appearance.start()
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        let settings = await StartupConnection.load(arguments: CommandLine.arguments)
        if let workspace { await workspace.start(startupConnection: settings) }
        else { await model.start(startupConnection: settings) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task {
            if let workspace {
                guard await workspace.prepareToClose(.application) else {
                    isTerminating = false
                    if let terminationReply { terminationReply(false) }
                    else { sender.reply(toApplicationShouldTerminate: false) }
                    return
                }
                await workspace.shutdown()
            }
            else { await model.shutdown() }
            if let terminationReply { terminationReply(true) }
            else { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}

