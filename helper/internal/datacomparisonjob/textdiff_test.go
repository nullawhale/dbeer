package datacomparisonjob

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"strings"
	"testing"
)

func TestDiffOperationReadsCapturedValuesAndBindsSelection(t *testing.T) {
	prefix := strings.Repeat("shared ", 80)
	m, e := New(func(_ context.Context, c protocol.Connection) (adapter.Session, error) {
		suffix := "before"
		if c.Database == "target" {
			suffix = "after"
		}
		return &fakeReader{rows: [][]*string{{str("1"), str(prefix + suffix)}}}, nil
	}, Options{Root: t.TempDir()})
	if e != nil {
		t.Fatal(e)
	}
	defer m.Close()
	c := command()
	source, target := *c.DataComparison.Source, *c.DataComparison.Target
	source.Connection.Database = "source"
	target.Connection.Database = "target"
	c.DataComparison.Source = &source
	c.DataComparison.Target = &target
	started := m.Handle(c)
	id := started.DataComparison.JobID
	if wait(t, m, id).State != "completed" {
		t.Fatal("capture failed")
	}
	r := m.Handle(protocol.Command{Type: "data.diff", RequestID: "diff", DataComparison: &protocol.DataComparisonRequest{JobID: id, Offset: 0, CellOffset: 1}})
	if r.DataComparison == nil || r.DataComparison.Diff == nil {
		t.Fatal("diff unavailable")
	}
	d := r.DataComparison.Diff
	if r.DataComparison.Offset == nil || *r.DataComparison.Offset != 0 || r.DataComparison.CellOffset == nil || *r.DataComparison.CellOffset != 1 || r.RequestID != "diff" {
		t.Fatal("selection binding lost")
	}
	if d.Status != "complete" || d.Lines[0].Source.Text != prefix+"before" || d.Lines[0].Target.Text != prefix+"after" {
		t.Fatal("full stored value not used")
	}
	for _, request := range []*protocol.DataComparisonRequest{{JobID: id, Offset: 1, CellOffset: 1}, {JobID: id, Offset: 0, CellOffset: 2}, {JobID: "other", Offset: 0, CellOffset: 1}} {
		if out := m.Handle(protocol.Command{Type: "data.diff", DataComparison: request}); out.Type != "error" {
			t.Fatal("invalid selection accepted")
		}
	}
	m.Handle(protocol.Command{Type: "data.close", DataComparison: &protocol.DataComparisonRequest{JobID: id}})
	if out := m.Handle(protocol.Command{Type: "data.diff", DataComparison: &protocol.DataComparisonRequest{JobID: id, CellOffset: 1}}); out.Type != "error" {
		t.Fatal("closed job returned diff")
	}
}
