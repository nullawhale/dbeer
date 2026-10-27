import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DBeer

@Suite(.serialized)
@MainActor
struct SQLExecutionSuccessTests {
    @Test func marksBelongToTheExecutedSourceAndResetOnEditsContextAndNewRuns() {
        let document = SQLDocument(text: "SELECT '😀';\r\nSELECT 2;")
        let statements = SQLScriptParser.parse(document.text, engine: .postgresql).statements
        let revision = document.executionRevision
        document.recordExecutionSuccess(statements[1], revision: revision)
        #expect(document.successfulExecutionRanges == [statements[1].range])
        let unchanged = document.text
        document.text = unchanged // Binding echoes do not invalidate a run.
        #expect(document.successfulExecutionRanges.count == 1)
        document.text += " "
        #expect(document.successfulExecutionRanges.isEmpty)
        document.text.removeLast()
        document.recordExecutionSuccess(statements[1], revision: revision)
        #expect(document.successfulExecutionRanges.isEmpty) // Editing back is a new revision.
        document.recordExecutionSuccess(statements[0], revision: document.executionRevision)
        #expect(document.successfulExecutionRanges.count == 1)
        document.profileID = UUID()
        #expect(document.successfulExecutionRanges.isEmpty)
        document.recordExecutionSuccess(statements[0], revision: document.executionRevision)
        document.clearExecutionSuccess()
        #expect(document.successfulExecutionRanges.isEmpty)
        document.recordExecutionSuccess(SQLStatement(sql: "SELECT 99", range: statements[0].range),
            revision: document.executionRevision)
        document.recordExecutionSuccess(SQLStatement(sql: "outside", range: NSRange(location: NSNotFound, length: 7)),
            revision: document.executionRevision)
        #expect(document.successfulExecutionRanges.isEmpty)
    }

    @Test func nativeRulerDrawsSuccessBesideTheCorrectUTF16LinesAndKeepsTabsAndUndoIndependent() async throws {
        let first = SQLDocument(text: "SELECT '😀';\r\n\r\nSELECT\n  2;")
        let second = SQLDocument(text: "SELECT 3;")
        let statements = SQLScriptParser.parse(first.text, engine: .postgresql).statements
        for statement in statements { first.recordExecutionSuccess(statement, revision: first.executionRevision) }
        let state = SQLEditorState()
        let firstBinding = Binding(get: { first.text }, set: { first.text = $0 })
        let secondBinding = Binding(get: { second.text }, set: { second.text = $0 })
        let coordinator = SQLEditorView.Coordinator(text: firstBinding)
        let scroll = coordinator.makeScrollView()
        coordinator.update(text: firstBinding, isEditable: true, in: scroll, editorState: state,
            documentID: first.id, successfulExecutionRanges: first.successfulExecutionRanges)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 100, width: 820, height: 440),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { window.close() }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            coordinator.update(text: firstBinding, isEditable: true, in: scroll, editorState: state,
                documentID: first.id, successfulExecutionRanges: first.successfulExecutionRanges)
            let editor = try #require(scroll.documentView as? SQLTextView)
            let ruler = try #require(scroll.verticalRulerView as? SQLLineNumberRuler)
            #expect(ruler.successfulLines == [0, 2])
            let width = ruler.ruleThickness
            try #require(window.makeFirstResponder(editor))
            editor.setSelectedRange(NSRange(location: 0, length: 6))
            let selection = editor.selectedRange()
            let undo = editor.undoManager
            try await Task.sleep(for: .milliseconds(100))
            scroll.layoutSubtreeIfNeeded()
            scroll.displayIfNeeded()
            if let output = ProcessInfo.processInfo.environment["DBEER_QA_OUTPUT_DIR"] {
                let bitmap = try #require(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
                scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                let directory = URL(fileURLWithPath: output, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: directory.appendingPathComponent("execution-success-\(appearance.rawValue).png"))
            }
            coordinator.update(text: secondBinding, isEditable: true, in: scroll, editorState: state,
                documentID: second.id)
            #expect((scroll.verticalRulerView as? SQLLineNumberRuler)?.successfulLines.isEmpty == true)
            coordinator.update(text: firstBinding, isEditable: true, in: scroll, editorState: state,
                documentID: first.id, successfulExecutionRanges: first.successfulExecutionRanges)
            #expect(scroll.documentView === editor)
            #expect(editor.selectedRange() == selection && editor.undoManager === undo)
            #expect(window.firstResponder === editor)
            #expect((scroll.verticalRulerView as? SQLLineNumberRuler)?.ruleThickness == width)
            editor.insertText("select", replacementRange: editor.selectedRange())
            #expect(first.successfulExecutionRanges.isEmpty)
            #expect((scroll.verticalRulerView as? SQLLineNumberRuler)?.successfulLines.isEmpty == true)
            editor.undoManager?.undo()
            #expect(first.text == "SELECT '😀';\r\n\r\nSELECT\n  2;")
            #expect(first.successfulExecutionRanges.isEmpty)
            for statement in statements { first.recordExecutionSuccess(statement, revision: first.executionRevision) }
        }
        await state.languageService.shutdown()
    }
}
