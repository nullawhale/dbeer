package protocol

import (
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"
)

func TestBrowseFilterSharedFixture(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/browse-filter-tree-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Version    int               `json:"version"`
		Capability string            `json:"capability"`
		Valid      []json.RawMessage `json:"validCatalogRequests"`
		Invalid    []json.RawMessage `json:"invalidCatalogRequests"`
	}
	if json.Unmarshal(data, &fixture) != nil || fixture.Version != Version || fixture.Capability != BrowseFilterTreeCapability || len(fixture.Valid) != 4 || len(fixture.Invalid) < 10 {
		t.Fatal("invalid browse fixture")
	}
	for index, raw := range fixture.Valid {
		request, valid := parseCatalog(raw)
		if !valid {
			t.Fatalf("valid browse fixture %d rejected", index)
		}
		encoded, err := json.Marshal(request)
		if err != nil {
			t.Fatal(err)
		}
		decoded, valid := parseCatalog(encoded)
		if !valid || !reflect.DeepEqual(request, decoded) {
			t.Fatal("browse fixture did not round trip")
		}
	}
	for _, raw := range fixture.Invalid {
		if _, valid := parseCatalog(raw); valid {
			t.Fatal("invalid browse fixture accepted")
		}
	}
}

func TestBrowseFilterTreeLimitsAndClosedShape(t *testing.T) {
	value := ""
	leaf := CatalogFilterExpression{Kind: "condition", Condition: &CatalogFilter{Column: "x", Operator: "eq", Value: &value}}
	for count, valid := range map[int]bool{32: true, 33: false} {
		root := CatalogFilterExpression{Kind: "and"}
		for i := 0; i < count; i++ {
			root.Children = append(root.Children, leaf)
		}
		if root.Valid() != valid {
			t.Fatal("condition bound changed")
		}
		raw, _ := json.Marshal(root)
		var decoded CatalogFilterExpression
		if (json.Unmarshal(raw, &decoded) == nil) != valid {
			t.Fatal("decode condition bound changed")
		}
	}
	for depth := 1; depth <= 5; depth++ {
		root := leaf
		for i := 1; i < depth; i++ {
			root = CatalogFilterExpression{Kind: "and", Children: []CatalogFilterExpression{root}}
		}
		if root.Valid() != (depth <= 4) {
			t.Fatal("depth bound changed")
		}
		raw, _ := json.Marshal(root)
		var decoded CatalogFilterExpression
		if (json.Unmarshal(raw, &decoded) == nil) != (depth <= 4) {
			t.Fatal("decode depth bound changed")
		}
	}
	// 32 unary groups plus 32 leaves and the root exceed the node budget.
	root := CatalogFilterExpression{Kind: "and"}
	for i := 0; i < 32; i++ {
		root.Children = append(root.Children, CatalogFilterExpression{Kind: "and", Children: []CatalogFilterExpression{leaf}})
	}
	if root.Valid() {
		t.Fatal("node bound changed")
	}
	raw, _ := json.Marshal(root)
	var decoded CatalogFilterExpression
	if json.Unmarshal(raw, &decoded) == nil {
		t.Fatal("oversized node tree decoded")
	}
	root.Children[31] = leaf
	if !root.Valid() {
		t.Fatal("64-node tree rejected")
	}
	raw, _ = json.Marshal(root)
	if json.Unmarshal(raw, &decoded) != nil {
		t.Fatal("64-node tree failed decoding")
	}
	for _, raw := range []string{
		`{"kind":"condition","condition":{"column":"x","operator":"isNull"},"children":null}`,
		`{"kind":"and","children":[null]}`,
		`{"kind":"and","kind":"or","children":[{"kind":"condition","condition":{"column":"x","operator":"isNull"}}]}`,
		`{"kind":"condition","condition":{"column":"x","column":"y","operator":"isNull"}}`,
		`{"kind":"and","children":[{"kind":"condition","condition":{"column":"x","operator":"isNull"}}],"extra":true}`,
	} {
		if json.Unmarshal([]byte(raw), &decoded) == nil {
			t.Fatal("unexpected tree shape decoded")
		}
	}
	tooLarge := strings.Repeat("x", 1024*1024+1)
	leaf.Condition.Value = &tooLarge
	if leaf.Valid() {
		t.Fatal("oversized value accepted")
	}
}

func TestBrowseFilterLegacyNormalizationAndFlattening(t *testing.T) {
	value := "exact"
	filters := []CatalogFilter{{Column: "a", Operator: "eq", Value: &value}, {Column: "b", Operator: "isNull"}}
	expression, ok := (CatalogRequest{Filters: filters}).EffectiveFilterExpression()
	if !ok || expression == nil || expression.Kind != "and" {
		t.Fatal("legacy list not normalized")
	}
	flattened, ok := expression.FlattenAND()
	if !ok || !reflect.DeepEqual(flattened, filters) {
		t.Fatal("legacy values changed")
	}
	expression.Kind = "or"
	if _, ok = expression.FlattenAND(); ok {
		t.Fatal("OR flattened into AND")
	}
	if _, ok = (CatalogRequest{Filters: filters, FilterExpression: expression}).EffectiveFilterExpression(); ok {
		t.Fatal("ambiguous filters accepted")
	}
	if expression, ok = (CatalogRequest{}).EffectiveFilterExpression(); !ok || expression != nil {
		t.Fatal("unfiltered request changed")
	}
}
