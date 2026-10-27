import Foundation

enum AppCommandGroup: String, CaseIterable, Identifiable, Sendable {
    case connections, sidebar, tabs, panes, files, editor, execution, results, history, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .connections: "Connections"
        case .sidebar: "Sidebar Panels"
        case .tabs: "Tabs and Navigation"
        case .panes: "Split Panes"
        case .files: "SQL Files and Folders"
        case .editor: "Editor"
        case .execution: "Query Execution"
        case .results: "Results and Copying"
        case .history: "SQL History"
        case .other: "Other Commands"
        }
    }
}

extension AppCommandDescriptor {
    var group: AppCommandGroup {
        if id.editorTool != nil { return .editor }
        return switch id {
        case .newConnection, .importConnections, .exportConnections, .findInConnections: .connections
        case .toggleConnectionsPanel, .toggleFilesPanel, .toggleSQLLibraryPanel, .toggleInvestigationsPanel: .sidebar
        case .newSQLTab, .closeTab, .reopenClosedTab, .nextTab, .previousTab: .tabs
        case .splitLeft, .splitRight, .splitUp, .splitDown, .unsplitCurrent, .unsplitAll: .panes
        case .openSQL, .saveSQL, .saveSQLAs, .attachSQLFolder, .checkSQLFiles: .files
        case .runCurrent, .runScript, .stop: .execution
        case .runToJSON, .runToCSV, .copyAsJSON, .copyAsMarkdown, .copyAsSQLInsert: .results
        case .showSQLHistory: .history
        default: .other
        }
    }
}

struct ShortcutSettingsGroup: Identifiable, Sendable {
    let group: AppCommandGroup
    let commands: [AppCommandDescriptor]
    var id: AppCommandGroup { group }
}

@MainActor
extension AppShortcutStore {
    func groups(matching query: String) -> [ShortcutSettingsGroup] {
        let tokens = Self.searchTokens(query)
        let modifiers: Set<String> = ["command", "control", "option", "shift"]
        let searchesBinding = tokens.contains { modifiers.contains($0) }
        return AppCommandGroup.allCases.compactMap { group in
            let commands = descriptors.filter { descriptor in
                guard descriptor.group == group else { return false }
                let shortcut = shortcut(for: descriptor.id)
                let bindingTokens = shortcut.map { Self.searchTokens($0.displayString + " " + $0.key) } ?? []
                let binding = shortcut.map { $0.displayString + " " + $0.key } ?? "unassigned unbound none"
                let searchable = Self.searchTokens(descriptor.title + " " + group.title + " " + descriptor.scope.title + " " + binding)
                    .joined(separator: " ")
                return tokens.allSatisfy { token in
                    if modifiers.contains(token) || (searchesBinding && token.count == 1) {
                        return bindingTokens.contains(token)
                    }
                    return searchable.contains(token)
                }
            }
            return commands.isEmpty ? nil : ShortcutSettingsGroup(group: group, commands: commands)
        }
    }

    private static func searchTokens(_ text: String) -> [String] {
        var value = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        for (symbol, name) in [("⌘", " command "), ("⌃", " control "), ("⌥", " option "), ("⇧", " shift "), ("↩", " return ")] {
            value = value.replacingOccurrences(of: symbol, with: name)
        }
        for (pattern, replacement) in [(#"\b(cmd|meta)\b"#, "command"), (#"\b(ctrl|ctl)\b"#, "control"),
                                       (#"\b(alt|opt)\b"#, "option"), (#"\bbackslash\b"#, "\\"), (#"\benter\b"#, "return")] {
            // Use a closure-free literal replacement so backslashes stay literal.
            let regex = try! NSRegularExpression(pattern: pattern)
            value = regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value),
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
        }
        return value.split(whereSeparator: { $0.isWhitespace || $0 == "+" }).map(String.init)
    }
}
