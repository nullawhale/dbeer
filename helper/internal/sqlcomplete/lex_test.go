package sqlcomplete

import "testing"

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
	context := Context{Engine: "mysql"}
	text := "-- comment\rSELECT CO"
	if _, ok := itemWithLabel(Complete(text, len(text), context), "COALESCE"); !ok {
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

func itemWithLabel(items []Item, label string) (Item, bool) {
	for _, item := range items {
		if item.Label == label {
			return item, true
		}
	}
	return Item{}, false
}
