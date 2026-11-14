package protocol

import (
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"os"
	"testing"
)

func TestStructureAdvancedSharedFactsProducer(t *testing.T) {
	data, e := os.ReadFile("../../../protocol/fixtures/table-structure-advanced-kinds-v1.json")
	if e != nil {
		t.Fatal(e)
	}
	var fixture struct {
		Capability string               `json:"capability"`
		Valid      []tableedit.Baseline `json:"valid"`
	}
	if json.Unmarshal(data, &fixture) != nil || fixture.Capability != StructureAdvancedKindsCapability || len(fixture.Valid) < 2 {
		t.Fatal("advanced fixture malformed")
	}
	for _, b := range fixture.Valid {
		if !tableedit.ValidBaseline(b) || b.Advanced == nil || !b.Advanced.Valid(b.Engine) {
			t.Fatal("producer rejected complete advanced kind/fact fixture")
		}
		raw, e := json.Marshal(b)
		if e != nil {
			t.Fatal(e)
		}
		var object map[string]json.RawMessage
		_ = json.Unmarshal(raw, &object)
		for _, key := range []string{"advancedEvidence", "authorization", "planId", "connection", "password"} {
			if _, ok := object[key]; ok {
				t.Fatal("private evidence/authority leaked into baseline")
			}
		}
	}
	plain := fixture.Valid[0]
	plain.Advanced = nil
	raw, e := json.Marshal(plain)
	if e != nil {
		t.Fatal(e)
	}
	var object map[string]json.RawMessage
	_ = json.Unmarshal(raw, &object)
	if _, ok := object["advanced"]; ok {
		t.Fatal("ordinary nil eligibility emitted a nullable advanced object")
	}
}
