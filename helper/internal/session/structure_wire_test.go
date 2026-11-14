package session

import (
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestStructureWireSummaryRetainsPrivateFactsWithoutUnadvertisedV4Fields(t *testing.T) {
	unsigned := false
	charset := "utf8mb4"
	baseline := tableedit.Baseline{Engine: "mariadb", ID: "retained", Fingerprint: strings.Repeat("a", 64), Scope: "private-scope", NativeDefinition: "private native definition", Facts: &tableedit.Facts{Proof: true}, Columns: []tableedit.ObservedColumn{{Name: "n", NativeType: "bigint(20)", Unsigned: &unsigned}, {Name: "v", NativeType: "varchar(40)", Charset: &charset, Collation: &tableedit.TypeReference{Name: "utf8mb4_bin"}}}}
	original := tableedit.Reply{Baseline: &baseline, Outcome: &tableedit.Outcome{State: "applied", Observed: &baseline, Steps: []tableedit.StepOutcome{{State: "applied"}}}}
	rawBefore, e := json.Marshal(original)
	if e != nil {
		t.Fatal(e)
	}
	projected := structureWireReply(original)
	if projected.Baseline == &baseline || projected.Outcome == original.Outcome || projected.Outcome.Observed == &baseline {
		t.Fatal("response projection reused mutable Store wrappers")
	}
	for _, b := range []*tableedit.Baseline{projected.Baseline, projected.Outcome.Observed} {
		if b.Fingerprint != baseline.Fingerprint || b.Scope != baseline.Scope || b.Facts != baseline.Facts || b.NativeDefinition != baseline.NativeDefinition {
			t.Fatal("wire projection changed retained proof authority")
		}
		for _, c := range b.Columns {
			if c.Unsigned != nil || c.Charset != nil || c.Collation != nil {
				t.Fatal("unadvertised version4 control field crossed the wire")
			}
		}
	}
	rawAfter, e := json.Marshal(original)
	if e != nil || !reflect.DeepEqual(rawBefore, rawAfter) || baseline.Columns[0].Unsigned == nil || baseline.Columns[1].Charset == nil {
		t.Fatal("wire projection mutated complete retained summary or observation")
	}
	if projected.Outcome.State != "applied" || projected.Outcome.Steps[0].State != "applied" {
		t.Fatal("known native acknowledgement was replaced")
	}
	baseline.Engine = "mysql"
	if structureWireReply(original).Baseline != &baseline {
		t.Fatal("completed old-engine rich wire contract changed")
	}
	empty := tableedit.Reply{Baseline: &tableedit.Baseline{Engine: "mariadb", Columns: []tableedit.ObservedColumn{}}}
	if structureWireReply(empty).Baseline.Columns == nil {
		t.Fatal("complete empty columns became JSON null")
	}
}

func TestStructureWirePartialAdvancedObservationRetainsAcknowledgement(t *testing.T) {
	b := tableedit.Baseline{Engine: "mariadb", Fingerprint: strings.Repeat("a", 64), Advanced: &tableedit.AdvancedKindSupport{Kinds: []string{"mariaDBPartitions"}}, Facts: &tableedit.Facts{Proof: true}}
	retained := tableedit.Reply{Baseline: &b, Outcome: &tableedit.Outcome{State: "applied", Observed: &b, Steps: []tableedit.StepOutcome{{State: "applied"}}}}
	projected := structureWireReply(retained)
	if projected.Baseline != nil || projected.Outcome == nil || projected.Outcome.Observed != nil || projected.Outcome.State != "applied" || projected.Outcome.Steps[0].State != "applied" || projected.Outcome.RefreshError == "" {
		t.Fatal("deferred advanced observation crossed the wire or erased known acknowledgement")
	}
	if retained.Baseline != &b || retained.Outcome.Observed != &b || retained.Outcome.RefreshError != "" || b.Advanced == nil || b.Facts == nil {
		t.Fatal("partial observation fence changed retained native evidence")
	}
}
