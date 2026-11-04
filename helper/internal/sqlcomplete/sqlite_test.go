package sqlcomplete

import (
	"strings"
	"testing"
)

func sqliteCompletionContext() Context {
	return Context{Engine: "sqlite", Catalog: []Relation{
		{Schema: "temp", Name: "Shared", Kind: "table", Columns: []string{"temp_only"}},
		{Schema: "main", Name: "Shared", Kind: "table", Columns: []string{"main_only"}},
		{Schema: "z_old", Name: "Shared", Kind: "table", Columns: []string{"old_only"}},
		{Schema: "a_new", Name: "Shared", Kind: "table", Columns: []string{"new_only"}},
	}}
}

func TestSQLiteCompletionResolvesOneSchemaInSuppliedOrder(t *testing.T) {
	context := sqliteCompletionContext()
	for _, tc := range []struct {
		query, want string
		absent      []string
	}{
		{`SELECT s.| FROM shared s`, "temp_only", []string{"main_only", "old_only", "new_only"}},
		{`SELECT s.| FROM "MAIN"."SHARED" AS s`, "main_only", []string{"temp_only", "old_only", "new_only"}},
		{`SELECT S.| FROM [Z_OLD].[SHARED] AS [s]`, "old_only", []string{"temp_only", "main_only", "new_only"}},
		{"SELECT `S`.| FROM `A_NEW`.`shared` AS `s`", "new_only", []string{"temp_only", "main_only", "old_only"}},
		{`WITH SHARED AS (SELECT 1 AS cte_only) SELECT s.| FROM "shared" s`, "cte_only", []string{"temp_only", "main_only", "old_only", "new_only"}},
	} {
		items := suggestions(t, tc.query, context)
		if _, ok := itemWithLabel(items, tc.want); !ok {
			t.Fatalf("SQLite completion missed resolved column %s", tc.want)
		}
		for _, absent := range tc.absent {
			if _, ok := itemWithLabel(items, absent); ok {
				t.Fatal("SQLite completion merged shadowed relation columns")
			}
		}
	}
	for _, want := range []string{"temp_only", "main_only", "old_only", "new_only"} {
		items := suggestions(t, `SELECT s.| FROM Shared s`, context)
		if _, ok := itemWithLabel(items, want); !ok {
			t.Fatal("SQLite search order did not choose the first remaining relation")
		}
		context.Catalog = context.Catalog[1:]
	}
}

func TestSQLiteIdentifiersFoldOnlyASCIIIncludingQuotes(t *testing.T) {
	for _, kind := range []tokenKind{wordToken, quotedToken} {
		if !identifierEqual(token{kind: kind, value: "MiXeD"}, "mixed", "sqlite") {
			t.Fatal("SQLite ASCII identifier matching is case sensitive")
		}
		for _, pair := range [][2]string{{"K", "K"}, {"Ä", "ä"}, {"ſ", "s"}} {
			if identifierEqual(token{kind: kind, value: pair[0]}, pair[1], "sqlite") {
				t.Fatal("SQLite identifier matching incorrectly folded Unicode")
			}
		}
	}
	context := Context{Engine: "sqlite", Catalog: []Relation{{Schema: "main", Name: "Ä", Kind: "table", Columns: []string{"upper_only"}}, {Schema: "main", Name: "ä", Kind: "table", Columns: []string{"lower_only"}}}}
	items := suggestions(t, `SELECT v.| FROM "ä" v`, context)
	if _, ok := itemWithLabel(items, "lower_only"); !ok {
		t.Fatal("SQLite quoted Unicode identifier did not match its exact spelling")
	}
	if _, ok := itemWithLabel(items, "upper_only"); ok {
		t.Fatal("SQLite Unicode-distinct relation leaked columns")
	}
	if !identifierEqual(token{kind: quotedToken, value: "MiXeD"}, "MiXeD", "postgresql") || identifierEqual(token{kind: quotedToken, value: "MiXeD"}, "mixed", "postgresql") {
		t.Fatal("SQLite matching changed PostgreSQL quoted semantics")
	}
}

func TestSQLiteLexerUsesSQLiteQuotesAndComments(t *testing.T) {
	query := "SELECT [semi;column],`odd``name` FROM [main].[shared] --comment\n WHERE value='a\\' AND other=1 /* closed /* inner */"
	tokens, diagnostics := lex(query, "sqlite")
	if len(diagnostics) != 0 {
		t.Fatal("SQLite quoting or comments produced a false diagnostic")
	}
	quoted := []string{}
	for _, token := range tokens {
		if token.kind == quotedToken {
			quoted = append(quoted, token.value)
		}
	}
	if strings.Join(quoted, "|") != "semi;column|odd`name|main|shared" {
		t.Fatal("SQLite bracket/backtick identifiers were not lexical units")
	}
	context := Context{Engine: "sqlite", Catalog: []Relation{{Schema: "main", Name: "shared", Kind: "table", Columns: []string{"column"}}}}
	for _, query := range []string{`SELECT [column]| FROM shared`, "SELECT `column`| FROM shared", `SELECT "COLUMN"| FROM shared`} {
		if _, ok := itemWithLabel(suggestions(t, query, context), "column"); !ok {
			t.Fatal("quoted SQLite completion prefix retained its closing delimiter")
		}
	}
}
