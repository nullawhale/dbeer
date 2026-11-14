package protocol

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestNativeCellFilterSharedContract(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/native-cell-filter-v1.json")
	if err != nil {
		t.Fatal("shared native filter fixture is unavailable")
	}
	var fixture struct {
		Capability     string
		Valid, Invalid []json.RawMessage
		InvalidJSON    []string
	}
	if json.Unmarshal(data, &fixture) != nil || fixture.Capability != NativeCellFilterCapability || len(fixture.Valid) < 8 || len(fixture.Invalid) < 20 || len(fixture.InvalidJSON) < 4 {
		t.Fatal("invalid native filter fixture")
	}
	for i, raw := range fixture.Valid {
		var filter CatalogFilter
		if err := json.Unmarshal(raw, &filter); err != nil || !filter.Valid() {
			t.Fatalf("valid native filter %d rejected", i)
		}
		for _, predicate := range []string{`"filters":[` + string(raw) + `]`, `"filterExpression":{"kind":"condition","condition":` + string(raw) + `}`} {
			catalog := `{"kind":"browse","schema":"main","object":"typed","objectKind":"table",` + predicate + `}`
			request, ok := parseCatalog(json.RawMessage(catalog))
			if !ok || !request.Valid() {
				t.Fatal("valid native operand rejected by catalog wire parsing")
			}
		}
		encoded, err := json.Marshal(filter)
		var roundTrip CatalogFilter
		if err != nil || json.Unmarshal(encoded, &roundTrip) != nil || !roundTrip.Valid() {
			t.Fatal("native filter did not round-trip")
		}
	}
	for i, raw := range fixture.Invalid {
		var filter CatalogFilter
		if json.Unmarshal(raw, &filter) == nil {
			t.Fatalf("invalid native filter %d accepted", i)
		}
		catalog := `{"kind":"browse","schema":"main","object":"typed","objectKind":"table","filters":[` + string(raw) + `]}`
		if _, ok := parseCatalog(json.RawMessage(catalog)); ok {
			t.Fatal("invalid native operand accepted by catalog wire parsing")
		}
	}
	for i, raw := range fixture.InvalidJSON {
		var filter CatalogFilter
		if json.Unmarshal([]byte(raw), &filter) == nil {
			t.Fatalf("invalid native filter JSON %d accepted", i)
		}
	}
}

func nativeFilterWith(value string) CatalogFilter {
	return CatalogFilter{Column: "v", Operator: "eq", NativeValue: &NativeCellFilterValue{Cell: CellValue{Kind: "text", Value: &value}, SourceEngine: "postgresql", SourceType: "text", SQLiteStorage: "text"}}
}

func TestNativeCellFilterBoundsAndAggregateBudget(t *testing.T) {
	filter := nativeFilterWith(strings.Repeat("x", NativeCellFilterValueLimit))
	if !filter.Valid() {
		t.Fatal("maximum native payload rejected")
	}
	long := strings.Repeat("x", NativeCellFilterValueLimit+1)
	filter.NativeValue.Cell.Value = &long
	if filter.Valid() {
		t.Fatal("oversized native payload accepted")
	}
	filter = nativeFilterWith("v")
	for _, kind := range []string{strings.Repeat("x", 16385), "bad\x00type", "", string([]byte{255})} {
		filter.NativeValue.SourceType = kind
		if filter.Valid() {
			t.Fatal("invalid source metadata accepted")
		}
	}
	filter.NativeValue.SourceType = strings.Repeat("x", 16384)
	if !filter.Valid() {
		t.Fatal("maximum source type rejected")
	}
	filter = nativeFilterWith(strings.Repeat("x", NativeCellFilterValueLimit))
	request := CatalogRequest{Filters: []CatalogFilter{filter, filter, filter}}
	if _, ok := request.EffectiveFilterExpression(); !ok {
		t.Fatal("bounded native AND list rejected")
	}
	request.Filters = append(request.Filters, filter)
	if _, ok := request.EffectiveFilterExpression(); ok {
		t.Fatal("native AND list exceeded total encoded operand budget")
	}
	expr := CatalogFilterExpression{Kind: "or"}
	for i := 0; i < 4; i++ {
		copy := filter
		expr.Children = append(expr.Children, CatalogFilterExpression{Kind: "condition", Condition: &copy})
	}
	if expr.Valid() {
		t.Fatal("native expression exceeded total encoded operand budget")
	}
	encoded, _ := json.Marshal(expr)
	var decoded CatalogFilterExpression
	if json.Unmarshal(encoded, &decoded) == nil {
		t.Fatal("oversized decoded native expression accepted")
	}
	expr.Children = expr.Children[:3]
	if !expr.Valid() {
		t.Fatal("bounded native expression rejected")
	}
	encoded, _ = json.Marshal(expr)
	if json.Unmarshal(encoded, &decoded) != nil {
		t.Fatal("bounded decoded native expression rejected")
	}
	// Escapes consume wire bytes too; an escaped control byte is six JSON bytes.
	escaped := nativeFilterWith(strings.Repeat("\x00", NativeCellFilterValueLimit))
	request.Filters = []CatalogFilter{escaped}
	if _, ok := request.EffectiveFilterExpression(); ok {
		t.Fatal("escaped payload bypassed encoded byte budget")
	}
}

func TestNativeCellFilterRequiredPresence(t *testing.T) {
	filter := nativeFilterWith("v")
	raw, _ := json.Marshal(filter.NativeValue)
	var object map[string]json.RawMessage
	json.Unmarshal(raw, &object)
	for _, name := range []string{"cell", "sourceEngine", "sourceType", "sqliteStorage"} {
		original := object[name]
		delete(object, name)
		missing, _ := json.Marshal(object)
		var operand NativeCellFilterValue
		if json.Unmarshal(missing, &operand) == nil {
			t.Fatal("missing native operand field accepted")
		}
		object[name] = json.RawMessage("null")
		null, _ := json.Marshal(object)
		if json.Unmarshal(null, &operand) == nil {
			t.Fatal("null native operand field accepted")
		}
		object[name] = original
	}
	for _, raw := range []string{`{"kind":"text"}`, `{"value":"x"}`, `{"kind":"text","value":null}`, `{"kind":null,"value":"x"}`} {
		object["cell"] = json.RawMessage(raw)
		invalid, _ := json.Marshal(object)
		var operand NativeCellFilterValue
		if json.Unmarshal(invalid, &operand) == nil {
			t.Fatal("missing or null cell field accepted")
		}
	}
}

func TestNativeCellFilterJSONUnicodeEscapesPreserveScalars(t *testing.T) {
	raw := `{"column":"v","operator":"eq","nativeValue":{"cell":{"kind":"text","value":"\ud83c\udf0d"},"sourceEngine":"postgresql","sourceType":"text","sqliteStorage":"text"}}`
	var filter CatalogFilter
	if json.Unmarshal([]byte(raw), &filter) != nil || *filter.NativeValue.Cell.Value != "🌍" {
		t.Fatal("valid surrogate pair rejected or changed")
	}
	raw = `{"column":"v","operator":"eq","nativeValue":{"cell":{"kind":"text","value":"\\ud800"},"sourceEngine":"postgresql","sourceType":"text","sqliteStorage":"text"}}`
	if json.Unmarshal([]byte(raw), &filter) != nil || *filter.NativeValue.Cell.Value != `\ud800` {
		t.Fatal("literal escaped text changed")
	}
}
