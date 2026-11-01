package postgres

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"io"
	"testing"
)

func TestStructureLostCommitAcknowledgementPreservesPrefixAndNeverReplays(t *testing.T) {
	f := newChangeFixture(t)
	s := &Session{conn: f.conn}
	f.exec("CREATE TABLE " + f.table("structure_fault") + " (id integer)")
	target := tableedit.Target{Schema: f.schema, Table: "structure_fault"}
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
			s.structureCommitOverride = func(commit func() error) error {
				if e := commit(); e != nil {
					return e
				}
				return io.ErrUnexpectedEOF
			}
		}
	}
	request := tableedit.Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "lost_ack"}
	r, e := store.Apply(context.Background(), s, request)
	s.afterStructureStep = nil
	s.structureCommitOverride = nil
	if e != nil || r.Outcome.State != "outcomeUnknown" || len(r.Outcome.Steps) != 3 || r.Outcome.Steps[0].State != "applied" || r.Outcome.Steps[1].State != "unknown" || r.Outcome.Steps[2].State != "notStarted" {
		t.Fatal("lost acknowledgement erased partial/unknown evidence")
	}
	if r.Outcome.Observed == nil {
		t.Fatal("test could not observe the committed structure")
	}
	foundUnknown, foundUnstarted := false, false
	for _, x := range r.Outcome.Observed.Indexes {
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
		t.Fatal("matching observation rewrote the historical unknown outcome")
	}
}
