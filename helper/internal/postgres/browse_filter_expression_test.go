package postgres

import (
	"reflect"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestPostgresBrowseNestedFilterPreservesGroupingAndExactOperands(t *testing.T) {
	exact, binary, text := "9007199254740993.000000000000000001", "AP+A", "needle' OR 1=1 --"
	leaf := func(column, operator string, value *string) protocol.CatalogFilterExpression {
		return protocol.CatalogFilterExpression{Kind: "condition", Condition: &protocol.CatalogFilter{Column: column, Operator: operator, Value: value}}
	}
	expression := protocol.CatalogFilterExpression{Kind: "and", Children: []protocol.CatalogFilterExpression{
		{Kind: "or", Children: []protocol.CatalogFilterExpression{leaf("exact", "gte", &exact), leaf("nullable", "isNull", nil)}},
		{Kind: "or", Children: []protocol.CatalogFilterExpression{leaf("payload", "eq", &binary), leaf(`label"$1`, "contains", &text)}},
	}}
	request := protocol.CatalogRequest{Schema: "public", Object: "items", FilterExpression: &expression,
		Sort: []protocol.CatalogSort{{Column: "exact", Direction: "desc"}, {Column: "nullable", Direction: "asc"}}}
	plan, err := buildBrowsePlan(request, []browseColumn{{name: "id", primary: 1}, {name: "exact", numeric: true}, {name: "nullable"}, {name: "payload", binary: true}, {name: `label"$1`}})
	if err != nil {
		t.Fatal("valid nested browse rejected")
	}
	want := `SELECT * FROM "public"."items" WHERE (("exact" >= $1::numeric OR "nullable" IS NULL) AND ("payload" = $2 OR strpos("label""$1"::text,$3::text)>0)) ORDER BY "exact" DESC,"nullable" ASC,"id" ASC LIMIT 200 OFFSET 0`
	if plan.statement != want || !reflect.DeepEqual(plan.values, [][]byte{[]byte(exact), []byte(`\x00ff80`), []byte(text)}) {
		t.Fatal("nested browse changed precedence, parameter order, exact values, or sort")
	}
	if !strings.Contains(plan.sourceSQL, `(("exact" >= E'9007199254740993.000000000000000001'::numeric OR "nullable" IS NULL) AND ("payload" = pg_catalog.decode('00ff80', 'hex') OR strpos("label""$1"::text,E'needle'' OR 1=1 --'::text)>0))`) {
		t.Fatal("source SQL lost nesting or safe exact literals")
	}
}

func TestPostgresBrowseRejectsMalformedAndMixedFilterTrees(t *testing.T) {
	value := "x"
	valid := protocol.CatalogFilterExpression{Kind: "condition", Condition: &protocol.CatalogFilter{Column: "label", Operator: "eq", Value: &value}}
	for _, expression := range []protocol.CatalogFilterExpression{
		{Kind: "or"},
		{Kind: "condition"},
		{Kind: "condition", Condition: &protocol.CatalogFilter{Column: "missing", Operator: "eq", Value: &value}},
		{Kind: "and", Children: []protocol.CatalogFilterExpression{{Kind: "condition", Condition: &protocol.CatalogFilter{Column: "label", Operator: "isNull", Value: &value}}}},
	} {
		if _, err := buildBrowsePlan(protocol.CatalogRequest{FilterExpression: &expression}, []browseColumn{{name: "label"}}); err == nil {
			t.Fatal("malformed or unavailable tree filter accepted")
		}
	}
	if _, err := buildBrowsePlan(protocol.CatalogRequest{Filters: []protocol.CatalogFilter{*valid.Condition}, FilterExpression: &valid}, []browseColumn{{name: "label"}}); err == nil {
		t.Fatal("ambiguous legacy and tree filters accepted")
	}
}
