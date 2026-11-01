package mysql

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"fmt"
	"io"
	"testing"
	"time"
)

func TestStructureMetadataOwnsPooledDriverStrings(t *testing.T) {
	s := integrationSession(t)
	name := fmt.Sprintf("structure_owned_%d", time.Now().UnixNano())
	run(t, s, "CREATE TABLE "+QuoteIdentifier(name)+" (value varchar(32) DEFAULT 'NULL')")
	defer run(t, s, "DROP TABLE "+QuoteIdentifier(name))
	target := tableedit.Target{Schema: integrationSettings(t).Database, Table: name}
	b, e := s.StructureLoad(context.Background(), target)
	if e != nil {
		t.Fatal(e)
	}
	frozen, _ := json.Marshal([]any{b, b.Facts})
	identity := s.serverUUID
	for i := 0; i < 12; i++ {
		if _, e = s.StructureLoad(context.Background(), target); e != nil {
			t.Fatal(e)
		}
	}
	after, _ := json.Marshal([]any{b, b.Facts})
	if string(frozen) != string(after) || s.serverUUID != identity {
		t.Fatal("retained metadata or server identity mutated after pooled result reuse")
	}
}
func TestStructureLostDDLAcknowledgementPreservesPrefixAndNeverReplays(t *testing.T) {
	s := integrationSession(t)
	observer := integrationSession(t)
	name := fmt.Sprintf("structure_fault_%d", time.Now().UnixNano())
	run(t, observer, "CREATE TABLE "+QuoteIdentifier(name)+" (id INT)")
	defer run(t, observer, "DROP TABLE "+QuoteIdentifier(name))
	target := tableedit.Target{Schema: integrationSettings(t).Database, Table: name}
	store := &tableedit.Store{}
	b, e := store.Load(context.Background(), s, target)
	if e != nil {
		t.Fatal(e)
	}
	d := tableedit.Draft{Columns: []tableedit.Column{{Name: "acknowledged_added", Type: tableedit.DataType{Kind: "integer"}, Nullable: true, Default: tableedit.Default{Kind: "none"}}}, Indexes: []tableedit.IndexEdit{{Action: "add", Name: "unknown_index", Columns: []string{"id"}}, {Action: "add", Name: "unstarted_index", Columns: []string{"id"}}}}
	p, e := store.Preview(s, b.Baseline.ID, d)
	if e != nil {
		t.Fatal(e)
	}
	s.afterStructureStep = func(i int) {
		if i == 0 {
			s.structureExecuteOverride = func(execute func() error) error {
				if e := execute(); e != nil {
					return e
				}
				return io.ErrUnexpectedEOF
			}
		}
	}
	request := tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "lost_ack"}
	r, e := store.Apply(context.Background(), s, request)
	s.afterStructureStep = nil
	s.structureExecuteOverride = nil
	if e != nil || r.Outcome.State != "outcomeUnknown" || len(r.Outcome.Steps) != 3 || r.Outcome.Steps[0].State != "applied" || r.Outcome.Steps[1].State != "unknown" || r.Outcome.Steps[2].State != "notStarted" {
		t.Fatal("lost acknowledgement erased partial/unknown evidence")
	}
	observed, e := observer.StructureLoad(context.Background(), target)
	if e != nil {
		t.Fatal(e)
	}
	foundUnknown, foundUnstarted := false, false
	for _, x := range observed.Indexes {
		foundUnknown = foundUnknown || x.Name == "unknown_index"
		foundUnstarted = foundUnstarted || x.Name == "unstarted_index"
	}
	if !foundUnknown || foundUnstarted {
		t.Fatal("acknowledgement-loss fixture does not match the intended fault")
	}
	if _, e := store.Apply(context.Background(), s, request); e == nil {
		t.Fatal("unknown DDL was replayed")
	}
	if store.Status().Outcome.State != "outcomeUnknown" {
		t.Fatal("observation rewrote the historical unknown outcome")
	}
}
