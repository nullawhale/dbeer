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
                } else { WorkspaceView(model: appDelegate.model, editorThemes: appDelegate.editorThemes,
                    appearance: appDelegate.appearance) }
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
            // Theme the panels so toolbar symbols retain native template rendering.
            TabView {
                AppearanceSettingsView(appearance: appDelegate.appearance, editorThemes: appDelegate.editorThemes)
                    .tabItem { Label("Appearance", systemImage: "paintpalette") }
                if let workspace = appDelegate.workspace {
                    ResultCopySettingsView(settings: workspace.copySettings)
                        .applicationTheme(appearance: appDelegate.appearance)
                        .tabItem { Label("Copying", systemImage: "doc.on.doc") }
                    ShortcutSettingsView(store: workspace.commandShortcuts)
                        .applicationTheme(appearance: appDelegate.appearance)
                        .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                }
            }
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
    @ObservedObject private var commands: AppCommandRegistry

    init(workspace: ApplicationWorkspace) {
        self.workspace = workspace
        self.commands = workspace.commands
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            commandItem(.newConnection)
            commandItem(.newSQLTab)
            commandItem(.closeTab)
            commandItem(.reopenClosedTab)
            commandItem(.openSQL)
            commandItem(.attachSQLFolder)
            commandItem(.checkSQLFiles)
        }
        CommandGroup(replacing: .saveItem) {
            commandItem(.saveSQL)
            commandItem(.saveSQLAs)
        }
        CommandGroup(after: .textEditing) {
            commandItem(.findInConnections)
        }
        CommandGroup(after: .pasteboard) {
            commandItem(.copyAsJSON)
            commandItem(.copyAsMarkdown)
            commandItem(.copyAsSQLInsert)
        }
        CommandMenu("Query") {
            commandItem(.runCurrent)
            commandItem(.runScript)
            Menu("Run to File") {
                commandItem(.runToJSON)
                commandItem(.runToCSV)
            }
            commandItem(.stop)
            Divider()
            commandItem(.showSQLHistory)
            Button("Result Snapshots…") { workspace.isSnapshotsPresented = true }
                .disabled(!workspace.canManageWorkspace)
        }
        CommandMenu("Connections") {
            Button("Compare Schema Structure…") { workspace.showSchemaComparison() }
                .disabled(!workspace.canManageWorkspace)
            Divider()
            commandItem(.importConnections)
            commandItem(.exportConnections)
        }
        CommandGroup(after: .windowArrangement) {
            commandItem(.previousTab)
            commandItem(.nextTab)
        }
    }

    private func commandItem(_ command: AppCommandID) -> some View {
        let shortcut = commands.shortcuts.shortcut(for: command)
        let descriptor = commands.shortcuts.descriptors.first { $0.id == command }
        return Button(descriptor?.title ?? command.rawValue) { commands.perform(command) }
            .keyboardShortcut(shortcut.map { KeyboardShortcut($0.keyEquivalent, modifiers: $0.eventModifiers) })
            .disabled(!commands.canPerform(command))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appearance: AppAppearance
    let editorThemes: EditorThemeStore
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
        self.editorThemes = workspace?.editorThemes ?? EditorThemeStore()
        self.appearance = workspace?.appearance ?? AppAppearance(editorThemes: self.editorThemes)
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

