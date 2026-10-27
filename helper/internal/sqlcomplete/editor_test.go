package sqlcomplete

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestEditorSharedFormattingFixtures(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/editor-tools-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Version       int                                         `json:"version"`
		FormatCases   []struct{ Engine, Source, Expected string } `json:"formatCases"`
		RejectedCases []struct{ Engine, Source string }           `json:"rejectedCases"`
	}
	if err = json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if fixture.Version != 1 {
		t.Fatal("fixture version")
	}
	for _, c := range fixture.FormatCases {
		t.Run(c.Engine, func(t *testing.T) {
			result, err := FormatEditor(c.Source, c.Engine, FormatOptions{InsertSpaces: true, TabSize: 4})
			if err != nil {
				t.Fatal(err)
			}
			if result != c.Expected {
				t.Fatalf("unexpected formatted fixture: %q", result)
			}
			again, err := FormatEditor(result, c.Engine, FormatOptions{InsertSpaces: true, TabSize: 4})
			if err != nil || again != result {
				t.Fatal("formatter is not idempotent", err)
			}
		})
	}
	for _, c := range fixture.RejectedCases {
		if _, err := FormatEditor(c.Source, c.Engine, FormatOptions{}); err == nil {
			t.Errorf("expected unsupported %s fragment to fail", c.Engine)
		}
	}
}
func TestEditorFormattingPreservesSensitiveTokens(t *testing.T) {
	cases := []struct{ engine, text string }{
		{"postgresql", "SELECT E'\\n', $$FROM; WHERE$$, \"Mixed Name\", 1.200e-03 -- x\r\nFROM t WHERE x='  a  ';"},
		{"mysql", "SELECT 'a\\'b', `a``b`, 0x00ff /* comment */ FROM t;"},
		{"cassandra", "BEGIN UNLOGGED BATCH INSERT INTO t (id,v) VALUES (1, {'x': [1,2]}); INSERT INTO t (id,v) VALUES (2, {}); APPLY BATCH;"},
	}
	for _, c := range cases {
		a, _ := lex(c.text, c.engine)
		formatted, err := FormatEditor(c.text, c.engine, FormatOptions{InsertSpaces: true, TabSize: 2, KeywordCase: "upper"})
		if err != nil {
			t.Fatal(err)
		}
		b, _ := lex(formatted, c.engine)
		if len(a) != len(b) {
			t.Fatal("lost token")
		}
		for i, v := range a {
			if !strings.EqualFold(c.text[v.start:v.end], formatted[b[i].start:b[i].end]) {
				t.Fatal("changed token")
			}
		}
	}
	if _, err := FormatEditor("SELECT 'a'\n'b'", "postgresql", FormatOptions{}); err == nil {
		t.Fatal("newline-sensitive strings must not change semantics")
	}
	for _, c := range []struct {
		engine, text string
		start, end   int
	}{{"postgresql", "SELECT 'a   b'", 9, 12}, {"mongodb", `{"a":"a   b"}`, 7, 10}, {"postgresql", "SELECT foobar", 8, 12}} {
		if SafeEditorRange(c.text, c.engine, c.start, c.end) {
			t.Fatal("accepted a range inside a token")
		}
	}
}

func TestEditorFormattingPreservesContextualIdentifierCase(t *testing.T) {
	for _, engine := range []string{"postgresql", "mysql", "cassandra"} {
		for _, mode := range []string{"upper", "lower"} {
			for _, text := range []string{
				"select first, LAST, nulls, Materialized, Collate from first;",
				"SELECT FIRST(first), Last(last) FROM LAST;",
				"select f.FIRST, f.last from first as f;",
				"SELECT full.FIRST FROM first AS full;",
				"select FIRST.last from FIRST;",
				"select returning.id from first returning;",
				"SELECT offset.id FROM first offset;",
				"select view.id from first view;",
				"SELECT except.id FROM first except;",
				"select intersect.id from first intersect;",
				"select RETURNING, EXCEPT, Intersect, offset, View from first returning;",
			} {
				formatted, err := FormatEditor(text, engine, FormatOptions{InsertSpaces: true, TabSize: 4, KeywordCase: mode})
				if err != nil {
					t.Fatal(err)
				}
				before, _ := lex(text, engine)
				after, _ := lex(formatted, engine)
				for index, original := range before {
					protectedName := false
					for _, name := range strings.Fields("first LAST nulls Materialized Collate FIRST Last last full f returning RETURNING offset view View except EXCEPT intersect Intersect") {
						if original.value == name {
							protectedName = true
							break
						}
					}
					if protectedName && text[original.start:original.end] != formatted[after[index].start:after[index].end] {
						t.Fatalf("%s %s changed identifier spelling: %q", engine, mode, formatted)
					}
				}
				again, err := FormatEditor(formatted, engine, FormatOptions{InsertSpaces: true, TabSize: 4, KeywordCase: mode})
				if err != nil || again != formatted {
					t.Fatal("non-idempotent case formatting", err)
				}
			}
		}
	}
	formatted, err := FormatEditor("select * from first", "mysql", FormatOptions{KeywordCase: "upper"})
	if err != nil || !strings.Contains(formatted, "FROM first") {
		t.Fatalf("case-sensitive MySQL relation changed: %q %v", formatted, err)
	}
}

func TestEditorQualifiedRelationAliasNavigatesLocally(t *testing.T) {
	context := Context{Engine: "postgresql", Catalog: []Relation{{Schema: "public", Name: "orders", Kind: "table", Columns: []string{"id"}}}}
	for _, text := range []string{"SELECT o.id FROM public.orders o;", "SELECT o.id FROM public.orders AS o;", "SELECT o.id FROM public . orders AS o;"} {
		result := AnalyzeEditor(text, strings.Index(text, "o.id"), context)
		if len(result.Definitions) != 1 || result.Definitions[0].Range == nil || result.Definitions[0].Kind != "alias" ||
			result.Definitions[0].Range.Start != strings.LastIndex(text, "o;") {
			t.Fatalf("qualified source alias did not navigate locally: %#v", result.Definitions)
		}
	}
	text := "SELECT orders.id FROM public.orders;"
	result := AnalyzeEditor(text, strings.Index(text, "orders.id"), context)
	if len(result.Definitions) != 1 || result.Definitions[0].Range != nil || result.Definitions[0].Name != "orders" {
		t.Fatalf("unaliased qualified relation should still navigate to catalog: %#v", result.Definitions)
	}
}

func TestEditorMongoFieldReferencesAcrossRequestSections(t *testing.T) {
	text := `{"collection":"orders","find":{"price":1,"billing":{"price":2},"shipping":{"price":3}},"projection":{"price":1,"billing.price":1},"sort":{"price":-1,"shipping.price":1}}`
	context := Context{Engine: "mongodb"}
	for _, test := range []struct {
		needle string
		count  int
	}{{`"price":1`, 3}, {`"billing.price"`, 2}, {`"shipping.price"`, 2}} {
		result := AnalyzeEditor(text, strings.Index(text, test.needle)+2, context)
		if len(result.References) != test.count {
			t.Fatalf("%s has %d references, expected %d", test.needle, len(result.References), test.count)
		}
	}
}
func TestEditorAnalysisScopesAndFolds(t *testing.T) {
	text := "SELECT u.id, (SELECT u.id FROM inner_users u) FROM users u;\nSELECT u.id FROM other_users u;"
	result := AnalyzeEditor(text, strings.Index(text, "u.id"), Context{Engine: "postgresql", Catalog: []Relation{{Schema: "public", Name: "users", Kind: "table", Columns: []string{"id"}}}})
	if len(result.Symbols) != 2 || len(result.Definitions) < 1 {
		t.Fatalf("missing symbols/definition: %#v", result)
	}
	if len(result.References) != 2 {
		t.Fatalf("alias references cross a scope: %#v", result.References)
	}
	for _, span := range result.References {
		if span.Start > strings.Index(text, ";\n") {
			t.Fatal("crossed statement")
		}
	}
	cte := "WITH source AS (SELECT 1 AS id) SELECT source.id FROM source;"
	result = AnalyzeEditor(cte, strings.LastIndex(cte, "source")+1, Context{Engine: "postgresql"})
	if len(result.Definitions) == 0 || result.Definitions[0].Range == nil || result.Definitions[0].Range.Start != 5 {
		t.Fatalf("CTE should navigate to declaration: %#v", result.Definitions)
	}
	result = AnalyzeEditor("SELECT (\n  id\n)\nFROM t;", 0, Context{Engine: "postgresql"})
	if len(result.Folds) != 2 {
		t.Fatalf("expected statement and nested block fold: %#v", result.Folds)
	}
}
func TestEditorJSONStructureAndPaths(t *testing.T) {
	text := "{\n \"find\": {\"id\": 1, \"id\": 2},\n \"other\": {\"id\":3},\n \"aggregate\": [{\"$match\":{\"id\":4}}]\n}"
	result := AnalyzeEditor(text, strings.Index(text, "id")+1, Context{Engine: "mongodb"})
	if len(result.References) != 2 {
		t.Fatalf("only identical paths should match: %#v", result.References)
	}
	if len(result.Folds) == 0 || len(result.Symbols) < 5 {
		t.Fatal("missing JSON object/array outline")
	}
	for _, s := range result.Symbols {
		if s.Range.End > len(text) || s.Range.Start < 0 {
			t.Fatal("invalid JSON span")
		}
	}
}
func TestEditorLargeDocumentIsBounded(t *testing.T) {
	text := strings.Repeat("SELECT '🌍', (\n1\n);\n", 60000)
	if len(text) > 2<<20 {
		t.Fatal("fixture exceeds input limit")
	}
	result := AnalyzeEditor(text, 0, Context{Engine: "postgresql"})
	if len(result.Symbols) > 2048 || len(result.Folds) > 8192 || len(result.References) > 8192 {
		t.Fatal("unbounded response")
	}
	if _, err := FormatEditor(strings.Repeat("x", (2<<20)+1), "postgresql", FormatOptions{}); err == nil {
		t.Fatal("size limit")
	}
}

func TestEditorCatalogInformationForColumnsFunctionsAndMongo(t *testing.T) {
	catalog := []Relation{{Schema: "public", Name: "users", Kind: "table", Columns: []string{"id", "author.name"}}, {Schema: "public", Name: "lookup", Kind: "function", Signatures: []FunctionSignature{{Parameters: []FunctionParameter{{Name: "id", Type: "integer"}}, ReturnType: "text"}}}}
	for _, text := range []string{"SELECT u.id FROM users u", "SELECT id FROM users"} {
		result := AnalyzeEditor(text, strings.Index(text, "id")+1, Context{Engine: "postgresql", Catalog: catalog})
		if len(result.Definitions) != 1 || result.Definitions[0].Name != "users" || !strings.Contains(result.Definitions[0].Detail, "Type unavailable") {
			t.Fatalf("missing column owner metadata: %#v", result.Definitions)
		}
	}
	result := AnalyzeEditor("SELECT lookup(1)", 8, Context{Engine: "postgresql", Catalog: catalog})
	if len(result.Definitions) != 1 || !strings.Contains(result.Definitions[0].Detail, "id integer") || !strings.Contains(result.Definitions[0].Detail, "text") {
		t.Fatal("missing function signatures", result.Definitions)
	}
	text := `{"collection":"users","find":{"author":{"name":"x"}}}`
	result = AnalyzeEditor(text, strings.Index(text, "name")+1, Context{Engine: "mongodb", Catalog: catalog})
	if len(result.Definitions) != 1 || result.Definitions[0].Name != "users" || !strings.Contains(result.Definitions[0].Detail, "Sampled field author.name") {
		t.Fatal("missing sampled field information", result.Definitions)
	}
	text = `{"collection":"users","collection":"users","find":{"id":1}}`
	result = AnalyzeEditor(text, strings.Index(text, "id")+1, Context{Engine: "mongodb", Catalog: catalog})
	if len(result.Definitions) > 0 {
		t.Fatal("ambiguous collection keys must not resolve")
	}
	batch := "BEGIN UNLOGGED BATCH\nINSERT INTO t (id) VALUES (1);\nINSERT INTO t (id) VALUES (2);\nAPPLY BATCH;"
	result = AnalyzeEditor(batch, 0, Context{Engine: "cassandra"})
	if len(result.Symbols) != 1 {
		t.Fatal("CQL batch split into individual statements")
	}
}

func TestEditorOpaqueProceduralOutlineAndKeyspaceIsolation(t *testing.T) {
	for _, c := range []struct{ engine, text string }{{"mysql", "DELIMITER $$\nCREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END$$\nDELIMITER ;\nSELECT 3;"}, {"postgresql", "CREATE FUNCTION f() RETURNS int LANGUAGE SQL BEGIN ATOMIC SELECT 1; SELECT 2; END; SELECT 3;"}} {
		result := AnalyzeEditor(c.text, 0, Context{Engine: c.engine})
		if len(result.Symbols) != 1 || result.Symbols[0].Range.End != len(c.text) {
			t.Fatalf("unsupported procedural syntax must remain one opaque outline entry: %#v", result.Symbols)
		}
	}
	catalog := []Relation{{Schema: "one", Name: "events", Kind: "table"}, {Schema: "two", Name: "events", Kind: "table"}}
	text := "SELECT * FROM events;"
	result := AnalyzeEditor(text, strings.Index(text, "events")+1, Context{Engine: "cassandra", Keyspace: "two", Catalog: catalog})
	if len(result.Definitions) != 1 || result.Definitions[0].Schema != "two" {
		t.Fatal("CQL default keyspace not respected", result.Definitions)
	}
	text = `{"aggregate":[{"$match":{"id":1}}],"find":{}}`
	result = AnalyzeEditor(text, 0, Context{Engine: "mongodb"})
	for i := 1; i < len(result.Symbols); i++ {
		if result.Symbols[i].Range.Start < result.Symbols[i-1].Range.Start {
			t.Fatal("JSON outline should be source ordered")
		}
	}
}

func TestEditorJSONDepthAndExpandedOutputLimits(t *testing.T) {
	deep := strings.Repeat("[", 257) + "0" + strings.Repeat("]", 257)
	if _, err := FormatEditor(deep, "mongodb", FormatOptions{InsertSpaces: true, TabSize: 4}); err == nil {
		t.Fatal("depth limit not enforced")
	}
	if got := AnalyzeEditor(deep, 0, Context{Engine: "mongodb"}); len(got.Symbols) != 0 {
		t.Fatal("unsupported depth should not return incorrect spans")
	}
	expanding := "[" + strings.Repeat("[", 100) + strings.Repeat("0,", 5000) + "0" + strings.Repeat("]", 100) + "]"
	if _, err := FormatEditor(expanding, "mongodb", FormatOptions{InsertSpaces: true, TabSize: 8}); err == nil {
		t.Fatal("expanded output limit not enforced")
	}
	value := `{"}":"{","a":[]}`
	formatted, err := FormatEditor(value, "mongodb", FormatOptions{InsertSpaces: true, TabSize: 4})
	if err != nil {
		t.Fatal(err)
	}
	again, err := FormatEditor(formatted, "mongodb", FormatOptions{InsertSpaces: true, TabSize: 4})
	if err != nil || again != formatted {
		t.Fatal("quoted brace affected formatting")
	}
}
