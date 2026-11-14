package tableedit

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestAdvancedKindsAreClosedObservationAndGatePortableDrafts(t *testing.T) {
	a := NewAdvancedSupport([]string{"typed"}, "only", 2, false, map[string]string{"addColumn": "Typed shape belongs to the composite type.", "reconstruction": "Client row-copy proof is not implemented."})
	if !a.Valid("postgresql") || a.Valid("mysql") {
		t.Fatal("kind/engine validation failed")
	}
	b := Baseline{Engine: "postgresql", Advanced: a, AdvancedEvidence: &AdvancedEvidence{Rows: map[string][]map[string]any{"policies": {{"node": "retained-private-node"}}}}}
	raw, e := json.Marshal(b)
	if e != nil || strings.Contains(string(raw), "retained-private-node") {
		t.Fatal("private metadata leaked into wire baseline")
	}
	d := Draft{AuthoringVersion: 2, Columns: []Column{}, Changes: []ColumnChange{{Name: "value", Default: &Default{Kind: "null"}}}}
	if e = CheckAdvancedDraft(b, d); e != nil {
		t.Fatal(e)
	}
	expr := "side_effect()"
	d.Changes[0].Default = &Default{Kind: "expression", Value: &expr}
	if CheckAdvancedDraft(b, d) == nil {
		t.Fatal("advanced expression admitted")
	}
	d = Draft{AuthoringVersion: 2, Columns: []Column{{Name: "x", Type: DataType{Kind: "integer"}, Nullable: true, Default: Default{Kind: "none"}}}}
	if CheckAdvancedDraft(b, d) == nil {
		t.Fatal("typed shape admitted")
	}
	a.Operations[0].Kind = "unknown"
	if a.Valid("postgresql") {
		t.Fatal("unknown/reordered operation admitted")
	}
}
