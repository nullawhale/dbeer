package session

import (
	"context"
	"dbeer/helper/internal/mariadb"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"fmt"
	"slices"
	"testing"
	"time"
)

func TestMariaDBNormalManagerStructureWirePreservesFullInternalProofLive(t *testing.T) {
	settings := mariaDBManagerSettings(t)
	setup, e := mariadb.Open(context.Background(), settings)
	if e != nil {
		t.Fatal("native setup owner unavailable")
	}
	defer setup.Close()
	name := fmt.Sprintf("g1_wire_%d", time.Now().UnixNano())
	qualified := mariadb.QuoteIdentifier(settings.Database) + "." + mariadb.QuoteIdentifier(name)
	defer setup.Execute(context.Background(), protocol.Command{SQL: "DROP TABLE IF EXISTS " + qualified})
	manager := New(mariadb.Open)
	defer manager.Close()
	settings.SessionPurpose = "structure"
	settings.Policy = &protocol.ExecutionPolicy{Environment: "production"}
	submit(t, manager, protocol.Command{Type: "connect", RequestID: "open-wire", Connection: &settings})
	connected := receive(t, manager)
	if connected.Type != "connect.result" || slices.Contains(connected.Capabilities, protocol.StructureDestructiveCapability) {
		t.Fatal("test must exercise the honest partial capability contract")
	}
	run := func(c protocol.Command) protocol.Response {
		t.Helper()
		c.SessionID = connected.SessionID
		c.RequestID = tableedit.Token()
		if c.QueryID == "" {
			c.QueryID = tableedit.Token()
		}
		submit(t, manager, c)
		return mariaDBManagerTerminal(t, manager)
	}
	target := tableedit.Target{Schema: settings.Database, Table: name, Create: true}
	loaded := run(protocol.Command{Type: "structure.load", Structure: &tableedit.Request{Target: &target}})
	if loaded.Structure == nil || loaded.Structure.Baseline == nil || loaded.Structure.Baseline.Columns == nil {
		t.Fatal("missing-target empty summary is not a valid native array")
	}
	draft := tableedit.Draft{Columns: []tableedit.Column{{Name: "id", Type: tableedit.DataType{Kind: "bigint"}, Default: tableedit.Default{Kind: "none"}}, {Name: "payload", Type: tableedit.DataType{Kind: "varchar", Length: 40}, Nullable: true, Default: tableedit.Default{Kind: "none"}}}}
	preview := run(protocol.Command{Type: "structure.preview", Structure: &tableedit.Request{BaselineID: loaded.Structure.Baseline.ID, Draft: &draft}})
	if preview.Structure == nil || preview.Structure.Plan == nil {
		t.Fatal("normal native CREATE preview unavailable")
	}
	plan := preview.Structure.Plan
	apply := tableedit.Apply{PlanID: plan.ID, Digest: plan.Digest, ExecutionID: tableedit.Token()}
	assessment := run(protocol.Command{Type: "operation.assess", Operations: []protocol.OperationRequest{{Type: "structure.apply", Structure: &apply}}})
	if assessment.Assessment == nil || assessment.Assessment.Decision != "confirm" {
		t.Fatal("exact native CREATE review unavailable")
	}
	applied := run(protocol.Command{Type: "structure.apply", Authorization: assessment.Assessment.Authorization, Structure: &tableedit.Request{Apply: &apply}})
	if applied.Structure == nil || applied.Structure.Outcome == nil || applied.Structure.Outcome.State != "applied" || applied.Structure.Outcome.Observed == nil {
		t.Fatal("acknowledged native CREATE did not retain an observed wire outcome")
	}
	observed := applied.Structure.Outcome.Observed
	check := func(b *tableedit.Baseline) {
		t.Helper()
		for _, c := range b.Columns {
			if c.Unsigned != nil || c.Charset != nil || c.Collation != nil {
				t.Fatal("unadvertised version4 observed fields crossed normal response boundary")
			}
		}
	}
	check(observed)
	encoded, e := json.Marshal(applied)
	if e != nil || len(encoded) == 0 {
		t.Fatal("acknowledged native outcome cannot be encoded")
	}
	full, e := setup.(tableedit.Adapter).StructureLoad(context.Background(), tableedit.Target{Schema: settings.Database, Table: name})
	if e != nil || full.Columns[0].Unsigned == nil || full.Columns[1].Charset == nil || full.Fingerprint != observed.Fingerprint {
		t.Fatal("wire projection weakened or changed full native preservation proof")
	}
	status := run(protocol.Command{Type: "structure.status", Structure: &tableedit.Request{}})
	if status.Structure == nil || status.Structure.Outcome == nil || status.Structure.Outcome.State != "applied" || status.Structure.Outcome.Observed == nil {
		t.Fatal("retained acknowledgement/status lost after response projection")
	}
	check(status.Structure.Outcome.Observed)
	if replay := run(protocol.Command{Type: "structure.apply", Authorization: assessment.Assessment.Authorization, Structure: &tableedit.Request{Apply: &apply}}); replay.Category != "policy" {
		t.Fatal("wire projection altered one-use authority")
	}
}
