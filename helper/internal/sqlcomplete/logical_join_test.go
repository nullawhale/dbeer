package sqlcomplete

import (
	"strings"
	"testing"
)

func TestLogicalJoinOriginAndSQLiteBoundValueSemantics(t *testing.T) {
	for _, engine := range []string{"postgresql", "mysql", "sqlite"} {
		context := fixture(engine)
		for i := range context.Catalog {
			for j := range context.Catalog[i].ForeignKeys {
				context.Catalog[i].ForeignKeys[j].Origin = "logical"
			}
		}
		items := suggestions(t, "SELECT * FROM public.orders o JOIN public.customers c ON |", context)
		found := false
		for _, item := range items {
			if item.Kind != 15 {
				continue
			}
			if !strings.Contains(item.Detail, "Local confirmed relationship") || strings.Contains(item.Detail, "Foreign key") {
				t.Fatal("logical link was presented as a server constraint")
			}
			q := func(s string) string { return quoteIdentifier(s, engine) }
			want := q("o") + "." + q("customer_id") + " = " + q("c") + "." + q("id")
			if engine == "sqlite" {
				want = q("c") + "." + q("id") + " = +" + q("o") + "." + q("customer_id")
			}
			if !strings.Contains(item.InsertText, want) {
				t.Fatal("logical equality changed captured-value semantics")
			}
			found = true
		}
		if !found {
			t.Fatal("confirmed logical JOIN was unavailable")
		}
		reverse := suggestions(t, "SELECT * FROM public.customers c JOIN ord|", context)
		if len(reverse) == 0 || reverse[0].Kind != 15 || !strings.Contains(reverse[0].Detail, "Local confirmed relationship") {
			t.Fatal("reverse logical JOIN missing")
		}
	}
	key := ForeignKey{Columns: []ForeignKeyColumn{{Source: "source", Target: "target"}}}
	if got := joinPredicate(key, "a", "b", "sqlite"); got != `"a"."source" = "b"."target"` {
		t.Fatal("declared foreign-key rendering changed")
	}
}

func TestExactOrderedColumnTypesReachEditorWithoutNormalizationOrLegacyFallback(t *testing.T) {
	relation := Relation{Schema: "public", Name: "items", Kind: "table", Columns: []string{"é", "e\u0301"},
		ColumnTypes:       map[string]string{"é": "wrong-legacy", "missing": "invented"},
		ColumnTypeEntries: []ColumnTypeEntry{{Name: "é", NativeType: "text"}, {Name: "e\u0301", NativeType: "bigint"}}}
	for _, c := range relation.ColumnTypeEntries {
		text := `SELECT "` + c.Name + `" FROM public.items`
		result := AnalyzeEditor(text, len(`SELECT "`)+1, Context{Engine: "postgresql", Catalog: []Relation{relation}})
		if len(result.Definitions) != 1 || !strings.Contains(result.Definitions[0].Detail, c.NativeType) || strings.Contains(result.Definitions[0].Detail, "wrong-legacy") {
			t.Fatal("exact native column type lost")
		}
	}
	relation.ColumnTypeEntries = []ColumnTypeEntry{}
	if relation.nativeType("é") != "" {
		t.Fatal("present ordered metadata fell back to legacy map")
	}
}

func TestLogicalJoinsRequireProvenQualifiedExactEndpoints(t *testing.T) {
	for _, engine := range []string{"postgresql", "mysql"} {
		a := Relation{Schema: "a", Name: "orders", Kind: "table", Columns: []string{"customer_id"}, ForeignKeys: []ForeignKey{{Origin: "logical", Name: "only-a", TargetSchema: "a", TargetTable: "customers", Columns: []ForeignKeyColumn{{Source: "customer_id", Target: "id"}}}}}
		b := Relation{Schema: "b", Name: "orders", Kind: "table", Columns: []string{"different"}}
		customers := Relation{Schema: "a", Name: "customers", Kind: "table", Columns: []string{"id"}}
		context := Context{Engine: engine, Catalog: []Relation{a, b, customers}}
		for _, sql := range []string{"SET search_path=b,a; SELECT * FROM orders o JOIN cust|", "SELECT * FROM orders o JOIN a.customers c ON |", "SELECT * FROM a.customers c JOIN orders o ON |"} {
			for _, item := range suggestions(t, sql, context) {
				if strings.Contains(item.Detail, "Local confirmed relationship") {
					t.Fatal("ambiguous endpoint acquired a local mapping")
				}
			}
		}
		for _, sql := range []string{"SELECT * FROM a.orders o JOIN cust|", "SELECT * FROM a.orders o JOIN a.customers c ON |", "SELECT * FROM a.customers c JOIN a.orders o ON |"} {
			found := false
			for _, item := range suggestions(t, sql, context) {
				found = found || strings.Contains(item.Detail, "Local confirmed relationship")
			}
			if !found {
				t.Fatal("exact qualified endpoint lost its local mapping")
			}
		}
		context.Catalog = []Relation{a, customers}
		for _, item := range suggestions(t, "SELECT * FROM orders o JOIN cust|", context) {
			if strings.Contains(item.Detail, "Local confirmed relationship") {
				t.Fatal("unknown active namespace guessed from a partial catalog")
			}
		}
	}
	upper := Relation{Schema: "a", Name: "Orders", Kind: "table", Columns: []string{"customer_id"}, ForeignKeys: []ForeignKey{{Origin: "logical", Name: "case-sensitive", TargetSchema: "a", TargetTable: "customers", Columns: []ForeignKeyColumn{{Source: "customer_id", Target: "id"}}}}}
	context := Context{Engine: "mysql", Catalog: []Relation{upper, {Schema: "a", Name: "customers", Kind: "table", Columns: []string{"id"}}}}
	for _, sql := range []string{"SELECT * FROM a.orders o JOIN cust|", "SELECT * FROM a.orders o JOIN a.customers c ON |", "SELECT * FROM A.Orders o JOIN cust|"} {
		for _, item := range suggestions(t, sql, context) {
			if strings.Contains(item.Detail, "Local confirmed relationship") {
				t.Fatal("case-folded MySQL endpoint acquired a local mapping")
			}
		}
	}
}
