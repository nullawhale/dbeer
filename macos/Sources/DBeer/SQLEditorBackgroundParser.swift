import Foundation

/// One worker per editor serializes large parses. Cancelled requests waiting for
/// the worker never start; callers verify source and dialect before publication.
actor SQLEditorBackgroundParser {
    func parse(_ text: String, engine: DatabaseEngine) -> SQLParseResult? {
        guard !Task.isCancelled else { return nil }
        let result = SQLScriptParser.parse(text, engine: engine)
        return Task.isCancelled ? nil : result
    }
}
