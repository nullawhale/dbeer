import Foundation
import Testing
@testable import DBeer

struct SQLSelectionExpansionTests {
    private func chain(_ text: String, at needle: String, engine: DatabaseEngine = .postgresql) -> [String] {
        let source = text as NSString
        let scopes = SQLSelectionExpansion(text: text, engine: engine)
        var selection = NSRange(location: source.range(of: needle).location + 1, length: 0)
        var values: [String] = []
        for _ in 0..<30 {
            let next = scopes.extending(selection)
            if next == selection { break }
            #expect(next.location <= selection.location && NSMaxRange(next) >= NSMaxRange(selection))
            #expect(next.length > selection.length)
            values.append(source.substring(with: next))
            selection = next
        }
        return values
    }

    @Test func expandsNestedFunctionThenStatementAndDocument() {
        let text = "SELECT sum(coalesce(price, 0)) FROM sales;\nSELECT 2;"
        #expect(chain(text, at: "price") == ["price", "price, 0", "(price, 0)", "coalesce(price, 0)",
            "(coalesce(price, 0))", "sum(coalesce(price, 0))", "SELECT sum(coalesce(price, 0)) FROM sales",
            "SELECT sum(coalesce(price, 0)) FROM sales;", text])
    }

    @Test func quotedTextAndCommentsHideFakeDelimiters() {
        for engine in [DatabaseEngine.postgresql, .mysql, .cassandra] {
            let text = "SELECT fn('hello ) world', /* fake ( */ 1);"
            #expect(chain(text, at: "hello", engine: engine).prefix(3) == ["hello", "hello ) world", "'hello ) world'"])
            let values = chain(text, at: "fake", engine: engine)
            #expect(values.prefix(3) == ["fake", "fake (", "/* fake ( */"])
            #expect(values.contains("('hello ) world', /* fake ( */ 1)"))
        }
    }

    @Test func dollarQuotesAndQualifiedIdentifiersPreserveBoundaries() {
        let text = "SELECT $body$hello ) world$body$, public.\"Mixed Name\";"
        #expect(chain(text, at: "hello").prefix(3) == ["hello", "hello ) world", "$body$hello ) world$body$"])
        #expect(chain(text, at: "Mixed").prefix(4) == ["Mixed", "Mixed Name", "\"Mixed Name\"", "public.\"Mixed Name\""])
    }

    @Test func caseAndAtomicBlocksAreScopes() {
        let text = "SELECT CASE WHEN ready THEN coalesce(price, 0) ELSE 1 END FROM sales;"
        let values = chain(text, at: "price")
        #expect(values.contains("WHEN ready THEN coalesce(price, 0) ELSE 1"))
        #expect(values.contains("CASE WHEN ready THEN coalesce(price, 0) ELSE 1 END"))
        let routine = "CREATE FUNCTION f() RETURNS int LANGUAGE SQL BEGIN ATOMIC SELECT 123; END;"
        #expect(chain(routine, at: "123").contains("BEGIN ATOMIC SELECT 123; END"))
    }

    @Test func jsonAndCQLCollectionsGrowThroughNestedScopes() {
        let json = #"{"find": {"name": "hello } world", "ids": [123, 456]}}"#
        #expect(chain(json, at: "hello", engine: .mongodb).prefix(3) == ["hello", "hello } world", #""hello } world""#])
        #expect(chain(json, at: "123", engine: .mongodb).prefix(3) == ["123", "123, 456", "[123, 456]"])
        let cql = "INSERT INTO t (id, tags) VALUES (1, {'hello', 'world'});"
        #expect(chain(cql, at: "hello", engine: .cassandra).contains("{'hello', 'world'}"))
    }

    @Test func whitespaceMalformedInputAndUTF16SelectionsStayContained() {
        let text = "SELECT fn(  😀цена + 1  );\r\nSELECT 2;"
        #expect(chain(text, at: "😀цена").prefix(2) == ["😀цена", "😀цена + 1"])
        let scopes = SQLSelectionExpansion(text: text, engine: .postgresql)
        let source = text as NSString
        let selection = source.range(of: "цена +")
        let next = scopes.extending(selection)
        #expect(source.substring(with: next) == "😀цена + 1")
        #expect(scopes.extending(NSRange(location: 0, length: source.length)) == NSRange(location: 0, length: source.length))
        #expect(scopes.extending(NSRange(location: NSNotFound, length: 0)).location == NSNotFound)
        #expect(SQLSelectionExpansion(text: "", engine: .postgresql).extending(.init(location: 0, length: 0)) == .init(location: 0, length: 0))
        #expect(chain("SELECT fn([value); SELECT 2;", at: "value").last == "SELECT fn([value); SELECT 2;")
    }
}
