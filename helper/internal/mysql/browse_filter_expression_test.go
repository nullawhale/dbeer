package mysql

import (
	"encoding/hex"
	"reflect"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestMySQLBrowseNestedFilterPreservesGroupingAndExactOperands(t *testing.T) {
	exact, binary, text := "9007199254740993.000000000000000001", "AP+A", "needle' OR 1=1 --"
	leaf := func(column, operator string, value *string) protocol.CatalogFilterExpression {
		return protocol.CatalogFilterExpression{Kind: "condition", Condition: &protocol.CatalogFilter{Column: column, Operator: operator, Value: value}}
	}
	expression := protocol.CatalogFilterExpression{Kind: "and", Children: []protocol.CatalogFilterExpression{
		{Kind: "or", Children: []protocol.CatalogFilterExpression{leaf("exact", "gte", &exact), leaf("nullable", "isNull", nil)}},
		{Kind: "or", Children: []protocol.CatalogFilterExpression{leaf("payload", "eq", &binary), leaf("label`?", "contains", &text)}},
	}}
	request := protocol.CatalogRequest{Schema: "demo", Object: "items", FilterExpression: &expression,
		Sort: []protocol.CatalogSort{{Column: "exact", Direction: "desc"}, {Column: "nullable", Direction: "asc"}}}
	plan, err := buildBrowsePlan(request, map[string]string{"id": "int", "exact": "decimal", "nullable": "text", "payload": "varbinary", "label`?": "text"}, []string{"id"})
	if err != nil {
		t.Fatal("valid nested browse rejected")
	}
	want := "SELECT * FROM `demo`.`items` WHERE ((`exact` >= CAST(? AS DECIMAL(65,18)) OR `nullable` IS NULL) AND (`payload` = ? OR LOCATE(?, `label``?`) > 0)) ORDER BY `exact` DESC, `nullable` ASC, `id` LIMIT 200"
	if plan.statement != want || !reflect.DeepEqual(plan.args, []any{exact, []byte{0, 255, 128}, text}) {
		t.Fatal("nested browse changed precedence, parameter order, exact values, or sort")
	}
	wantSource := "((`exact` >= CAST(CONVERT(X'" + hex.EncodeToString([]byte(exact)) + "' USING utf8mb4) AS DECIMAL(65,18)) OR `nullable` IS NULL) AND (`payload` = X'00ff80' OR LOCATE(CONVERT(X'" + hex.EncodeToString([]byte(text)) + "' USING utf8mb4), `label``?`) > 0))"
	if !strings.Contains(plan.sourceSQL, wantSource) {
		t.Fatal("source SQL lost nesting or safe exact literals")
	}
}

func TestMySQLBrowseRejectsMalformedAndMixedFilterTrees(t *testing.T) {
	value := "x"
	valid := protocol.CatalogFilterExpression{Kind: "condition", Condition: &protocol.CatalogFilter{Column: "label", Operator: "eq", Value: &value}}
	for _, expression := range []protocol.CatalogFilterExpression{
		{Kind: "or"},
		{Kind: "condition"},
		{Kind: "condition", Condition: &protocol.CatalogFilter{Column: "missing", Operator: "eq", Value: &value}},
		{Kind: "and", Children: []protocol.CatalogFilterExpression{{Kind: "condition", Condition: &protocol.CatalogFilter{Column: "label", Operator: "isNull", Value: &value}}}},
	} {
		if _, err := buildBrowsePlan(protocol.CatalogRequest{FilterExpression: &expression}, map[string]string{"label": "text"}, nil); err == nil {
			t.Fatal("malformed or unavailable tree filter accepted")
		}
	}
	if _, err := buildBrowsePlan(protocol.CatalogRequest{Filters: []protocol.CatalogFilter{*valid.Condition}, FilterExpression: &valid}, map[string]string{"label": "text"}, nil); err == nil {
		t.Fatal("ambiguous legacy and tree filters accepted")
	}
}
