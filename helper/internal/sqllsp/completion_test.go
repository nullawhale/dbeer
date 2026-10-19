package sqllsp

import (
	"strings"
	"testing"
)

func TestUnicodeQuotedAliasAndWholeIdentifierEdit(t *testing.T) {
	text := "SELECT '🦀', \"😀\".\"Na\" FROM \"Sales\".\"Order Items\" AS \"😀\""
	offset := strings.Index(text, "Na") + 2
	context := configuration{Engine: "postgresql", Catalog: []catalogEntry{{Schema: "Sales", Name: "Order Items", Kind: "table", Columns: []string{"Name Value", "id"}}}}
	items := complete(text, offset, context)
	item, ok := itemWithLabel(items, "Name Value")
	if !ok {
		t.Fatalf("missing quoted alias column: %#v", items)
	}
	if item.TextEdit.NewText != `"Name Value"` || item.InsertText != item.TextEdit.NewText {
		t.Fatalf("wrong identifier quote: %#v", item)
	}
	start, _ := offsetAt(text, item.TextEdit.Range.Start)
	end, _ := offsetAt(text, item.TextEdit.Range.End)
	if text[start:end] != `"Na"` {
		t.Fatalf("wrong whole-identifier range: %q", text[start:end])
	}
	if item.TextEdit.Range.Start.Character != 18 {
		t.Fatalf("range is not UTF-16: %#v", item.TextEdit.Range.Start)
	}
	updated := text[:start] + item.TextEdit.NewText + text[end:]
	if !strings.Contains(updated, `"😀"."Name Value" FROM`) {
		t.Fatalf("bad edited text: %s", updated)
	}
}

func TestAliasColumnsSchemaTablesAndDialectQuotes(t *testing.T) {
	context := configuration{Engine: "mysql", Catalog: []catalogEntry{
		{Schema: "db", Name: "order items", Kind: "table", Columns: []string{"select", "odd`name", "id"}},
		{Schema: "other", Name: "order items", Kind: "table", Columns: []string{"wrong"}},
		{Schema: "db", Name: "order_view", Kind: "view"},
	}}
	for _, text := range []string{"SELECT o. FROM db.`order items` AS o", "SELECT db.`order items`. FROM db.`order items`"} {
		offset := strings.Index(text, ". FROM") + 1
		items := complete(text, offset, context)
		if item, ok := itemWithLabel(items, "select"); !ok || item.InsertText != "`select`" {
			t.Fatalf("missing reserved quoted column: %#v", items)
		}
		if item, ok := itemWithLabel(items, "odd`name"); !ok || item.InsertText != "`odd``name`" {
			t.Fatal("identifier escape missing")
		}
		if _, ok := itemWithLabel(items, "wrong"); ok {
			t.Fatal("unrelated schema leaked into qualified columns")
		}
	}
	items := complete("SELECT * FROM db.", 17, context)
	if _, ok := itemWithLabel(items, "order_view"); !ok {
		t.Fatalf("missing schema member: %#v", items)
	}
	if _, ok := itemWithLabel(items, "SELECT"); ok {
		t.Fatal("keyword in qualified member list")
	}
}

func TestCompletionIgnoresStringsCommentsAndPreviousStatements(t *testing.T) {
	context := configuration{Engine: "postgresql", Catalog: []catalogEntry{{Name: "users", Kind: "table", Columns: []string{"unique_column"}}}}
	for _, text := range []string{"SELECT 'CO", "-- CO", "SELECT $body$ CO", "/* CO"} {
		if items := complete(text, len(text), context); len(items) != 0 {
			t.Fatalf("completion inside literal/comment %q", text)
		}
	}
	context.Engine = "mysql"
	for _, text := range []string{"# CO", `SELECT "CO`} {
		if items := complete(text, len(text), context); len(items) != 0 {
			t.Fatalf("completion inside MySQL literal/comment %q", text)
		}
	}
	context.Engine = "postgresql"
	text := "SELECT * FROM users u; SELECT u."
	if items := complete(text, len(text), context); len(items) != 0 {
		t.Fatalf("alias leaked from preceding statement: %#v", items)
	}
	items := complete("SELECT * FROM ", 14, context)
	if _, ok := itemWithLabel(items, "users"); !ok {
		t.Fatal("table context missing table")
	}
	if _, ok := itemWithLabel(items, "COALESCE"); ok {
		t.Fatal("table context contains function")
	}
}

func TestUTF16PositionsIncludingCRLF(t *testing.T) {
	text := "a😀b\r\néø\r🦀\nx"
	for _, check := range []struct {
		offset int
		p      position
	}{{0, position{0, 0}}, {1, position{0, 1}}, {5, position{0, 3}}, {8, position{1, 0}}, {12, position{1, 2}}, {13, position{2, 0}}, {17, position{2, 2}}, {18, position{3, 0}}} {
		if p := positionAt(text, check.offset); p != check.p {
			t.Fatalf("position at %d: %#v", check.offset, p)
		}
		if offset, ok := offsetAt(text, check.p); !ok || offset != check.offset {
			t.Fatalf("offset at %#v: %d %v", check.p, offset, ok)
		}
	}
	for _, p := range []position{{0, 2}, {4, 0}, {2, 1}, {-1, 0}, {0, -1}} {
		if _, ok := offsetAt(text, p); ok {
			t.Fatalf("accepted invalid position %#v", p)
		}
	}
}

func TestLexicalDiagnosticsRespectDialectLiterals(t *testing.T) {
	for _, check := range []struct{ engine, text string }{
		{"postgresql", `DO $body$ BEGIN RAISE NOTICE '('; END $body$; SELECT 'it''s )'; /* outer /* nested ) */ ( */`},
		{"postgresql", `SELECT 'backslash\', E'escaped\' quote)', "(" FROM t`},
		{"postgresql", `SELECT $ετι$ unpaired ) '$ετι$`},
		{"mysql", "SELECT 'it\\'s )', `(`; # )\r\n /* ) */ SELECT (1)"},
		{"mysql", `SELECT "it's )"`},
	} {
		if _, d := lex(check.text, check.engine); len(d) != 0 {
			t.Fatalf("false diagnostic in %s: %#v", check.engine, d)
		}
	}
	for _, check := range []struct {
		text  string
		count int
	}{{"SELECT (1", 1}, {"SELECT )", 1}, {"SELECT 'unterminated", 1}, {"SELECT /* open", 1}, {"SELECT $tag$ open", 1}, {"SELECT \"open", 1}} {
		_, d := lex(check.text, "postgresql")
		if len(d) != check.count {
			t.Fatalf("diagnostics for %q: %#v", check.text, d)
		}
	}
}

func TestMySQLDashCommentRequiresWhitespace(t *testing.T) {
	tokens, _ := lex("SELECT 1--2", "mysql")
	for _, token := range tokens {
		if token.kind == commentToken {
			t.Fatal("MySQL subtraction parsed as comment")
		}
	}
	context := configuration{Engine: "mysql"}
	text := "-- comment\rSELECT CO"
	if _, ok := itemWithLabel(complete(text, len(text), context), "COALESCE"); !ok {
		t.Fatal("bare CR did not end line comment")
	}
}

func TestEveryCatalogIdentifierIsQuoted(t *testing.T) {
	for _, engine := range []string{"postgresql", "mysql"} {
		quote := "\""
		if engine == "mysql" {
			quote = "`"
		}
		for _, name := range []string{"user", "constraint", "column", "interval", "ordinary"} {
			if got := quoteIdentifier(name, engine); got != quote+name+quote {
				t.Fatalf("unsafe %s identifier %s", engine, got)
			}
		}
	}
}

func TestPostgresCatalogAndAliasCaseSemantics(t *testing.T) {
	context := configuration{Engine: "postgresql", Catalog: []catalogEntry{
		{Name: "Users", Kind: "table", Columns: []string{"wrong"}},
		{Name: "users", Kind: "table", Columns: []string{"correct"}},
	}}
	for _, text := range []string{"SELECT u. FROM users u", "SELECT u. FROM users AS U", `SELECT u. FROM users AS "u"`} {
		offset := strings.Index(text, ". FROM") + 1
		items := complete(text, offset, context)
		if _, ok := itemWithLabel(items, "correct"); !ok {
			t.Fatalf("lost case-folded alias in %s", text)
		}
		if _, ok := itemWithLabel(items, "wrong"); ok {
			t.Fatal("quoted mixed-case table selected for unquoted name")
		}
	}
	text := `SELECT u. FROM users AS "U"`
	if items := complete(text, strings.Index(text, ". FROM")+1, context); len(items) != 0 {
		t.Fatalf("unquoted alias matched different quoted name: %#v", items)
	}
	text = `SELECT "U". FROM "Users" AS "U"`
	if _, ok := itemWithLabel(complete(text, strings.Index(text, ". FROM")+1, context), "wrong"); !ok {
		t.Fatal("quoted table/alias exact match missing")
	}
}

func TestCompletionImmediatelyAfterTerminatedLiteralAndBlockComment(t *testing.T) {
	for _, check := range []struct{ text, engine string }{
		{`SELECT 'x'`, "postgresql"}, {`SELECT $$x$$`, "postgresql"},
		{`/* block */`, "postgresql"}, {`SELECT "x"`, "mysql"}, {`/* block */`, "mysql"},
	} {
		if items := complete(check.text, len(check.text), configuration{Engine: check.engine}); len(items) == 0 {
			t.Fatalf("completion suppressed after terminated %s", check.text)
		}
	}
	for _, text := range []string{"-- line", "/* block", "SELECT 'x", "SELECT $$x"} {
		if items := complete(text, len(text), configuration{Engine: "postgresql"}); len(items) != 0 {
			t.Fatalf("completion escaped open literal/comment %s", text)
		}
	}
}

func TestTableCompletionPreservesSchemasAndAmbiguousCatalogCandidates(t *testing.T) {
	context := configuration{Engine: "postgresql", Catalog: []catalogEntry{
		{Schema: "Sales", Name: "users", Kind: "table", Columns: []string{"sales_only"}},
		{Schema: "public", Name: "users", Kind: "table", Columns: []string{"public_only"}},
	}}
	items := complete("SELECT * FROM us", 16, context)
	insertions := map[string]bool{}
	for _, item := range items {
		if item.Label == "users" {
			insertions[item.InsertText] = true
		}
	}
	if !insertions[`"Sales"."users"`] || !insertions[`"public"."users"`] {
		t.Fatalf("lost catalog schema: %#v", insertions)
	}
	text := "SELECT u. FROM users u"
	items = complete(text, 9, context)
	for _, label := range []string{"sales_only", "public_only"} {
		if _, ok := itemWithLabel(items, label); !ok {
			t.Fatalf("arbitrarily discarded ambiguous catalog candidate %s", label)
		}
	}
	text = `SELECT u. FROM "Sales".users u`
	items = complete(text, 9, context)
	if _, ok := itemWithLabel(items, "public_only"); ok {
		t.Fatal("explicit schema failed to restrict catalog candidate")
	}
}

func TestCatalogFunctionsPreserveSchemasOutsideTableContext(t *testing.T) {
	context := configuration{Engine: "postgresql", Catalog: []catalogEntry{
		{Schema: "Sales", Name: "calculate", Kind: "function"},
		{Schema: "public", Name: "calculate", Kind: "function"},
	}}
	items := complete("SELECT cal", 10, context)
	insertions := map[string]bool{}
	for _, item := range items {
		if item.Label == "calculate" {
			insertions[item.InsertText] = true
			if item.Kind != 3 {
				t.Fatal("catalog function has wrong completion kind")
			}
		}
	}
	if !insertions[`"Sales"."calculate"`] || !insertions[`"public"."calculate"`] {
		t.Fatalf("catalog function schema lost: %#v", insertions)
	}
	items = complete("SELECT CO", 9, context)
	if item, ok := itemWithLabel(items, "COALESCE"); !ok || item.InsertText != "COALESCE" {
		t.Fatal("builtin function was qualified")
	}
	text := `SELECT "Sales".cal`
	items = complete(text, len(text), context)
	if item, ok := itemWithLabel(items, "calculate"); !ok || item.InsertText != `"calculate"` {
		t.Fatal("qualified completion repeated the schema")
	}
}
