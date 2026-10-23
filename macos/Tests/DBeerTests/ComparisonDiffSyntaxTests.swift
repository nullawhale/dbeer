import AppKit
import Foundation
import Testing
@testable import DBeer

/// These checks inspect attributed strings only; they create no views or windows.
@MainActor
struct ComparisonDiffSyntaxTests {
    @Test func postgresDollarQuotedBodyAndNestedCommentsKeepTheirMultilineState() throws {
        let sql = #"""
        CREATE FUNCTION "café🌍"() RETURNS text AS $body$
        BEGIN

          RETURN 'SELECT is function content';
        END;
        $body$ LANGUAGE plpgsql;
        /* outer comment
          /* nested */ SELECT is still a comment
        */
        SELECT 42;
        """#
        let text = NSMutableAttributedString(string: sql, attributes: [.foregroundColor: NSColor.labelColor])
        let source = sql as NSString
        let changed = source.range(of: "SELECT is function content")
        let background = NSColor.systemRed.withAlphaComponent(0.32)
        text.addAttribute(.backgroundColor, value: background, range: changed)
        ComparisonDiffSyntax.apply(to: text, engine: .postgresql)
        #expect(color(in: text, at: changed.location) == SQLSyntaxPalette.string)
        #expect(color(in: text, at: source.range(of: "END;").location) == SQLSyntaxPalette.string)
        #expect(color(in: text, at: source.range(of: "SELECT is still a comment").location) == NSColor.secondaryLabelColor)
        #expect(color(in: text, at: source.range(of: "SELECT 42").location) == SQLSyntaxPalette.keyword)
        #expect(color(in: text, at: source.range(of: "42").location) == SQLSyntaxPalette.number)
        #expect(text.attribute(.backgroundColor, at: changed.location, effectiveRange: nil) as? NSColor == background)
        #expect(text.string == sql)
        #expect(text.length == sql.utf16.count)
    }

    @Test func mysqlMultilineQuotedValuesAndCommentsRespectAlignedBlankRows() {
        let sql = """
        CREATE TABLE `items` (
          `note` text DEFAULT 'first line

        SELECT is part of the literal',
          /* explanation

        SELECT is part of the comment */
          `count` integer DEFAULT 12
        );
        SELECT 7;
        """
        let text = NSMutableAttributedString(string: sql, attributes: [.foregroundColor: NSColor.labelColor])
        let source = sql as NSString
        ComparisonDiffSyntax.apply(to: text, engine: .mysql)
        #expect(color(in: text, at: source.range(of: "SELECT is part of the literal").location) == SQLSyntaxPalette.string)
        #expect(color(in: text, at: source.range(of: "SELECT is part of the comment").location) == NSColor.secondaryLabelColor)
        #expect(color(in: text, at: source.range(of: "SELECT 7").location) == SQLSyntaxPalette.keyword)
        #expect(color(in: text, at: source.range(of: "12").location) == SQLSyntaxPalette.number)
        #expect(text.string == sql)
    }

    private func color(in text: NSAttributedString, at offset: Int) -> NSColor? {
        text.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor
    }
}
