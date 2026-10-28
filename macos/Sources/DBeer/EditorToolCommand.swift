import AppKit

enum SQLToolCommand: String, CaseIterable, Identifiable {
    case find, replace, findNext, findPrevious, formatCurrent, formatSelection, formatDocument
    case indent, outdent, toggleLineComment, toggleBlockComment, duplicateLines, deleteLines, moveLinesUp, moveLinesDown
    case extendSelection, selectNextOccurrence, selectAllOccurrences, addCursorAbove, addCursorBelow
    case goToLine, previousStatement, nextStatement, outline, definition, showInformation
    case collapseCurrent, expandCurrent, collapseAll, expandAll
    var id: String { rawValue }
    var commandID: AppCommandID { .init(rawValue: "editor." + rawValue) }
    var title: String {
        switch self {
        case .find: "Find in Editor…"
        case .replace: "Find and Replace…"
        case .findNext: "Find Next"
        case .findPrevious: "Find Previous"
        case .formatCurrent: "Format Current Statement"
        case .formatSelection: "Format Selection"
        case .formatDocument: "Format Document"
        case .indent: "Indent Lines"
        case .outdent: "Outdent Lines"
        case .toggleLineComment: "Toggle Line Comment"
        case .toggleBlockComment: "Toggle Block Comment"
        case .duplicateLines: "Duplicate Lines"
        case .deleteLines: "Delete Lines"
        case .moveLinesUp: "Move Lines Up"
        case .moveLinesDown: "Move Lines Down"
        case .extendSelection: "Extend Selection"
        case .selectNextOccurrence: "Select Next Occurrence"
        case .selectAllOccurrences: "Select All Occurrences"
        case .addCursorAbove: "Add Cursor Above"
        case .addCursorBelow: "Add Cursor Below"
        case .goToLine: "Go to Line…"
        case .previousStatement: "Previous Statement"
        case .nextStatement: "Next Statement"
        case .outline: "Document Outline…"
        case .definition: "Go to Definition…"
        case .showInformation: "Show Symbol Information…"
        case .collapseCurrent: "Collapse Current Block"
        case .expandCurrent: "Expand Current Block"
        case .collapseAll: "Collapse All Blocks"
        case .expandAll: "Expand All Blocks"
        }
    }
    var defaultShortcut: AppShortcut? {
        switch self {
        case .find: .init(key: "f", modifiers: .command)
        case .replace: .init(key: "f", modifiers: [.command, .option])
        case .findNext: .init(key: "g", modifiers: .command)
        case .findPrevious: .init(key: "g", modifiers: [.command, .shift])
        case .formatCurrent: .init(key: "i", modifiers: [.command, .shift])
        case .toggleLineComment: .init(key: "/", modifiers: .command)
        case .toggleBlockComment: .init(key: "/", modifiers: [.command, .option])
        case .duplicateLines: .init(key: "d", modifiers: [.command, .shift])
        case .extendSelection: .init(key: "w", modifiers: .command)
        case .selectNextOccurrence: .init(key: "d", modifiers: .command)
        case .selectAllOccurrences: .init(key: "g", modifiers: [.command, .control])
        case .addCursorAbove: .init(key: "upArrow", modifiers: [.control, .shift])
        case .addCursorBelow: .init(key: "downArrow", modifiers: [.control, .shift])
        case .goToLine: .init(key: "l", modifiers: .command)
        case .definition: .init(key: "b", modifiers: .command)
        default: nil
        }
    }
    var descriptor: AppCommandDescriptor {
        .init(id: commandID, title: title, scope: .sqlDocument, defaultShortcut: defaultShortcut)
    }
    var textAction: SQLTextEditorAction? {
        switch self {
        case .indent: .indent
        case .outdent: .outdent
        case .toggleLineComment: .toggleLineComment
        case .toggleBlockComment: .toggleBlockComment
        case .duplicateLines: .duplicateLines
        case .deleteLines: .deleteLines
        case .moveLinesUp: .moveLinesUp
        case .moveLinesDown: .moveLinesDown
        case .extendSelection: .extendSelection
        case .selectNextOccurrence: .selectNextOccurrence
        case .selectAllOccurrences: .selectAllOccurrences
        case .addCursorAbove: .addCursorAbove
        case .addCursorBelow: .addCursorBelow
        default: nil
        }
    }
}

extension AppCommandID {
    var editorTool: SQLToolCommand? {
        guard rawValue.hasPrefix("editor.") else { return nil }
        return SQLToolCommand(rawValue: String(rawValue.dropFirst(7)))
    }
}
