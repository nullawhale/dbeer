import Foundation
import Testing
@testable import DBeer

struct SQLTextEditingTests {
    @Test func normalizationRetainsPrimaryAndMergesOnlyOverlaps() {
        let ranges = SQLTextEditing.normalized([NSRange(location: 8, length: 2), NSRange(location: 1, length: 4), NSRange(location: 3, length: 3), NSRange(location: 8, length: 2), NSRange(location: 10, length: 0)], length: 12)
        #expect(ranges == [NSRange(location: 8, length: 2), NSRange(location: 1, length: 5), NSRange(location: 10, length: 0)])
    }

    @Test func batchEditsMapUTF16CaretsAndRejectOverlaps() {
        let text = "😀 aa bb"
        let edits = [SQLTextEdit(range: NSRange(location: 3, length: 2), text: "X"), SQLTextEdit(range: NSRange(location: 6, length: 2), text: "long")]
        #expect(SQLTextEditing.applying(edits, to: text) == "😀 X long")
        #expect(SQLTextEditing.mapped(NSRange(location: 8, length: 0), through: edits) == NSRange(location: 9, length: 0))
        #expect(SQLTextEditing.applying([SQLTextEdit(range: NSRange(location: 0, length: 4), text: ""), SQLTextEdit(range: NSRange(location: 3, length: 2), text: "")], to: text) == nil)
    }

    @Test func replacingAdjacentSelectionsMapsEachCaretToItsOwnInsertion() {
        let ranges = [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)]
        let edits = ranges.map { SQLTextEdit(range: $0, text: "x") }
        #expect(SQLTextEditing.applying(edits, to: "aabb") == "xx")
        #expect(SQLTextEditing.insertionCarets(for: ranges, edits: edits) == [NSRange(location: 1, length: 0), NSRange(location: 2, length: 0)])
    }

    @Test func wholeLineSelectionDoesNotIncludeFollowingLine() {
        #expect(SQLTextEditing.lineRanges(in: "a\r\nb\r\nc", selections: [NSRange(location: 0, length: 3)]) == [NSRange(location: 0, length: 3)])
    }

    @Test func commentsToggleIndentAndKeepJSONStrict() {
        let source = "  SELECT 1;\n\tSELECT 2;"
        let selection = [NSRange(location: 0, length: source.utf16.count)]
        let edits = SQLTextEditing.lineEdits(action: .toggleLineComment, text: source, selections: selection, indent: "    ", engine: .postgresql)
        let commented = SQLTextEditing.applying(edits, to: source)!
        #expect(commented == "  -- SELECT 1;\n\t-- SELECT 2;")
        let uncomment = SQLTextEditing.lineEdits(action: .toggleLineComment, text: commented, selections: [NSRange(location: 0, length: commented.utf16.count)], indent: "    ", engine: .postgresql)
        #expect(SQLTextEditing.applying(uncomment, to: commented) == source)
        #expect(SQLTextEditing.lineEdits(action: .toggleBlockComment, text: "{}", selections: [NSRange(location: 0, length: 2)], indent: "    ", engine: .mongodb).isEmpty)
    }

    @Test func movingUnterminatedLastLinePreservesLineBoundary() {
        let source = "first\r\nlast"
        let edits = SQLTextEditing.lineEdits(action: .moveLinesUp, text: source, selections: [NSRange(location: 7, length: 0)], indent: "    ", engine: .mysql)
        #expect(SQLTextEditing.applying(edits, to: source) == "last\r\nfirst")
    }

    @Test func movingLinesKeepsCaretColumnAndBlockCommentsDoNotNest() {
        let text = "one\ntwo\nthree"
        let selections = [NSRange(location: 5, length: 0)]
        let edits = SQLTextEditing.lineEdits(action: .moveLinesUp, text: text, selections: selections, indent: "    ", engine: .mysql)
        #expect(SQLTextEditing.selectionsAfterMovingLines(action: .moveLinesUp, text: text, selections: selections, edits: edits) == [NSRange(location: 1, length: 0)])
        let mixed = "SELECT /* note */ 1;"
        let comment = SQLTextEditing.lineEdits(action: .toggleBlockComment, text: mixed, selections: [NSRange(location: 0, length: mixed.utf16.count)], indent: "    ", engine: .mysql)
        #expect(comment.isEmpty)
    }

    @Test func duplicateAndOutdentHandleMixedIndentation() {
        let source = "\tSELECT 1;\n  SELECT 2;"
        let ranges = [NSRange(location: 0, length: source.utf16.count)]
        let outdent = SQLTextEditing.lineEdits(action: .outdent, text: source, selections: ranges, indent: "    ", engine: .cassandra)
        #expect(SQLTextEditing.applying(outdent, to: source) == "SELECT 1;\nSELECT 2;")
        let duplicate = SQLTextEditing.lineEdits(action: .duplicateLines, text: "last", selections: [NSRange(location: 1, length: 0)], indent: "    ", engine: .postgresql)
        #expect(SQLTextEditing.applying(duplicate, to: "last") == "last\nlast")
    }
}
