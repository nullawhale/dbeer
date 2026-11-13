package tableedit

import (
	sc "dbeer/helper/internal/schemacompare"
	"testing"
)

func TestExpressionComparisonPreservesTokenBoundaries(t *testing.T) {
	for _, pair := range [][2]string{{"base * 2", `((base * 2))`}, {"lower('A  B')", "LOWER('A  B')"}} {
		if !SameExpression("postgresql", pair[0], pair[1]) {
			t.Fatal("server whitespace/parentheses normalization rejected")
		}
	}
	for _, pair := range [][2]string{{"a + + b", "a ++ b"}, {"1 2", "12"}, {"1 . 2", "1.2"}, {"lower('A B')", "lower('AB')"}, {`"CaseSensitive"`, "casesensitive"}} {
		if SameExpression("postgresql", pair[0], pair[1]) {
			t.Fatal("distinct expression tokens were conflated")
		}
	}
}

func TestMySQLCatalogExpressionDecodesOnlyLiteralNormalization(t *testing.T) {
	facts := &Facts{EngineContext: []sc.Option{{Name: "sqlMode", Value: ""}}}
	if !SameCatalogExpression("mysql", `concat(_utf8mb4'a\'b;--',_utf8mb4'kept')`, `concat('a''b;--','kept')`, facts) {
		t.Fatal("known catalog literal normalization rejected")
	}
	if SameCatalogExpression("mysql", "`_utf8mb4'kept'`", "`'kept'`", facts) {
		t.Fatal("charset prefix inside identifier was discarded")
	}
	if SameCatalogExpression("mysql", `concat(_latin1'kept')`, `concat('kept')`, facts) {
		t.Fatal("a different literal character set was accepted")
	}
	facts.EngineContext[0].Value = "NO_BACKSLASH_ESCAPES"
	if !SameCatalogExpression("mysql", `concat(_utf8mb4'a''b;--')`, `concat('a''b;--')`, facts) {
		t.Fatal("NO_BACKSLASH_ESCAPES catalog normalization rejected")
	}
}

func TestMySQLCatalogEscapeEnvelopeIsReversibleAndComparisonOnly(t *testing.T) {
	facts := &Facts{EngineContext: []sc.Option{{Name: "sqlMode", Value: ""}}}
	if !SameCatalogExpression("mysql", `concat(_utf8mb4\'a\\\'b;--\',_utf8mb4\'kept\')`, `concat('a''b;--','kept')`, facts) {
		t.Fatal("known I_S expression envelope rejected")
	}
	if _, ok := mysqlCatalogEnvelope(`concat('unescaped',\'escaped\')`); ok {
		t.Fatal("mixed raw SQL was mistaken for a complete catalog envelope")
	}
}

func TestDollarQuotedExpressionComparisonPreservesLiteralBytes(t *testing.T) {
	if !SameExpression("postgresql", `$body$Upper +  Value$body$`, `'Upper +  Value'`) {
		t.Fatal("equivalent dollar/single quote literals rejected")
	}
	for _, other := range []string{`$$upper +  Value$$`, `$$Upper+Value$$`, `$$Upper + Value$$`} {
		if SameExpression("postgresql", `$body$Upper +  Value$body$`, other) {
			t.Fatal("dollar literal bytes were normalized as SQL tokens")
		}
	}
}

func TestQuotedKeywordsRequireProvenIdentifierInterpretation(t *testing.T) {
	for _, engine := range []string{"postgresql", "mysql"} {
		f := &Facts{ExpressionKeywords: []string{"null", "current_user"}, Table: sc.Table{Columns: sc.Complete([]sc.Column{{Ref: sc.Ref{Name: "base"}}, {Ref: sc.Ref{Name: "null"}}, {Ref: sc.Ref{Name: "current_user"}}})}}
		quote := "\""
		if engine == "mysql" {
			quote = "`"
		}
		for _, word := range []string{"null", "current_user"} {
			if SameCatalogExpression(engine, quote+word+quote, word, f) {
				t.Fatal("quoted identifier matched a SQL value keyword")
			}
		}
		if !SameCatalogExpression(engine, quote+"base"+quote+" * 2", "base * 2", f) {
			t.Fatal("known non-keyword column identifier was not normalized")
		}
		if SameExpression(engine, quote+"base"+quote, "base") {
			t.Fatal("unproven bare identifier interpretation was assumed")
		}
	}
}

func TestMySQLRenameExpressionAbsenceStaysConservative(t *testing.T) {
	f := &Facts{ExpressionKeywords: []string{"null", "current_user"}, EngineContext: []sc.Option{{Name: "sqlMode", Value: ""}}, Table: sc.Table{Columns: sc.Complete([]sc.Column{
		{Ref: sc.Ref{Name: "id"}}, {Ref: sc.Ref{Name: "base"}}, {Ref: sc.Ref{Name: "$base"}}, {Ref: sc.Ref{Name: "1base"}}, {Ref: sc.Ref{Name: "é"}},
	})}}
	for _, test := range []struct {
		raw, mode string
		id, base  bool
	}{
		{"base * 2", "", true, false},
		{"`base` * 2", "", true, false},
		{"`ID` * 2", "", false, true},
		{"tbl.id + base", "", false, false},
		{"concat('id',base)", "", true, false},
		{"id(base)", "", false, false},
		{`"id" + base`, "", true, false},
		{`"id" + base`, "ANSI_QUOTES", false, false},
		{"concat(_utf8mb4\\'id\\',`base`)", "", true, false},
		{"$base * 2", "", true, false},
		{"1base * 2", "", true, false},
		{"`$base` * 2", "", true, true},
		{"`1base` * 2", "", true, true},
		{"'constant'", "", true, true},
	} {
		f.EngineContext[0].Value = test.mode
		if MySQLExpressionExcludesColumn(test.raw, "id", f) != test.id || MySQLExpressionExcludesColumn(test.raw, "base", f) != test.base {
			t.Fatal("bounded identifier proof differs")
		}
		for _, name := range []string{"$base", "1base", "é"} {
			if MySQLExpressionExcludesColumn(test.raw, name, f) {
				t.Fatal("unsupported identifier received an absence proof")
			}
		}
	}
	for _, raw := range []string{"base /* id */", "base -- id", "base # id", "base + ?", "concat('unfinished)", "base + \\id", "base; id", "base + é"} {
		if MySQLExpressionExcludesColumn(raw, "id", f) {
			t.Fatal("uncertain SQL received an absence proof")
		}
	}
	f.Table.Columns.Complete = false
	if MySQLExpressionExcludesColumn("base*2", "id", f) {
		t.Fatal("incomplete columns received an absence proof")
	}
}

func TestMySQLCatalogDoubleQuotesRespectSQLMode(t *testing.T) {
	f := &Facts{EngineContext: []sc.Option{{Name: "sqlMode", Value: "ANSI_QUOTES"}}}
	if SameCatalogExpression("mysql", `"null"`, "'null'", f) {
		t.Fatal("ANSI quoted identifier matched a literal")
	}
	f.EngineContext[0].Value = ""
	if !SameCatalogExpression("mysql", `"null"`, "'null'", f) {
		t.Fatal("ordinary double-quoted string was not preserved")
	}
}

func TestMySQLRenameAbsenceDoesNotUpgradeGeneralDependencyProof(t *testing.T) {
	b := transitionFixture("mysql")
	c := b.Facts.Table.Columns.Items[0]
	c.Ref.Name = "derived"
	expression := &sc.Expression{Text: "value * 2", Dependencies: sc.Collection[sc.Ref]{Complete: false, Code: "notExposed"}}
	c.Generated = sc.Known(sc.Generated{Kind: "stored", Expression: expression})
	b.Facts.Table.Columns.Items = append(b.Facts.Table.Columns.Items, c)
	unrelated := c
	unrelated.Ref.Name = "unrelated"
	unrelated.Generated = sc.Known(sc.Generated{Kind: "none"})
	b.Facts.Table.Columns.Items = append(b.Facts.Table.Columns.Items, unrelated)

	if CheckRename(b, "unrelated") != nil || CheckRename(b, "value") == nil || expression.Dependencies.Complete {
		t.Fatal("bounded absence proof changed dependency admission")
	}
	expression.Text = "unrelated * 2"
	if CheckRename(b, "unrelated") == nil {
		t.Fatal("changed expression reference was treated as absent")
	}
}
