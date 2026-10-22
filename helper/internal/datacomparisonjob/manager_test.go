package datacomparisonjob

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	tc "dbeer/helper/internal/tablecapture"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type fakeReader struct {
	closed, readonly atomic.Bool
	rows             [][]*string
	gate             <-chan struct{}
	entered          chan<- struct{}
	failure          error
}

func (s *fakeReader) Execute(context.Context, protocol.Command) protocol.Response {
	panic("comparison executed caller SQL")
}
func (s *fakeReader) TransactionStatus() string                   { return "idle" }
func (s *fakeReader) Close()                                      { s.closed.Store(true) }
func (s *fakeReader) SetReadOnly(_ context.Context, v bool) error { s.readonly.Store(v); return nil }
func descriptor(table tc.Table) tc.Descriptor {
	d := tc.Descriptor{Engine: "postgresql", Table: table, Columns: []tc.Column{{Index: 0, Name: "id", NativeType: "int8", TypeLabel: "int8", PrimaryKey: 1, Definition: json.RawMessage(`{}`)}, {Index: 1, Name: "value", NativeType: "text", TypeLabel: "text", Definition: json.RawMessage(`{}`)}}, Definition: json.RawMessage(`{}`)}
	_ = d.Seal()
	return d
}
func (s *fakeReader) DescribeTable(ctx context.Context, table tc.Table) (tc.Descriptor, error) {
	if !s.readonly.Load() {
		panic("metadata not read only")
	}
	if e := ctx.Err(); e != nil {
		return tc.Descriptor{}, e
	}
	return descriptor(table), s.failure
}
func (s *fakeReader) CaptureTable(ctx context.Context, spec tc.Spec, sink tc.Sink) (tc.Descriptor, tc.Outcome, error) {
	d := descriptor(spec.Table)
	out := tc.Outcome{StartedAt: "2026-10-22T10:00:00Z", FinishedAt: "2026-10-22T10:00:01Z", Consistency: "repeatableRead", Rendering: "postgresTextUTCISOv1", ReadLimit: spec.ReadLimit, PartialReasons: []string{}}
	if e := tc.Validate(d, spec); e != nil {
		return d, out, e
	}
	if s.entered != nil {
		s.entered <- struct{}{}
	}
	if s.gate != nil {
		select {
		case <-s.gate:
		case <-ctx.Done():
			return d, out, ctx.Err()
		}
	}
	for _, row := range s.rows {
		if e := ctx.Err(); e != nil {
			return d, out, e
		}
		out.ObservedAtLeast++
		if out.StoredRows >= int64(spec.ReadLimit) {
			out.PartialReasons = append(out.PartialReasons, "readLimit")
			break
		}
		selected := []*string{}
		for _, name := range spec.Columns {
			index := 0
			if name == "value" {
				index = 1
			}
			selected = append(selected, row[index])
		}
		if e := sink.Row(selected); e != nil {
			return d, out, e
		}
		out.StoredRows++
	}
	return d, out, nil
}
func str(s string) *string { return &s }
func TestCaptureDeadlineStartsAfterPhysicalOpen(t *testing.T) {
	m, e := New(func(ctx context.Context, _ protocol.Connection) (adapter.Session, error) {
		timer := time.NewTimer(200 * time.Millisecond)
		defer timer.Stop()
		select {
		case <-timer.C:
			return &fakeReader{rows: [][]*string{{str("1"), str("exact")}}}, nil
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}, Options{Root: t.TempDir(), CaptureTimeout: 100 * time.Millisecond})
	if e != nil {
		t.Fatal(e)
	}
	defer m.Close()
	start := m.Handle(command())
	result := wait(t, m, start.DataComparison.JobID)
	if result.State != "completed" || result.Summary == nil || !result.Summary.Comparison.FullEquality {
		t.Fatal("physical open consumed the independent capture deadline")
	}
}
func command() protocol.Command {
	table := tc.Table{Schema: "public", Name: "fixture"}
	d := descriptor(table)
	filters := []tc.Filter{}
	side := protocol.DataReadSide{Table: table, DescriptorDigest: d.Digest, ReadLimit: 10000, Filters: &filters}
	return protocol.Command{Type: "data.start", RequestID: "start", DataComparison: &protocol.DataComparisonRequest{Source: &side, Target: &side, Columns: []tc.Mapping{{Source: "id", Target: "id", Key: true}, {Source: "value", Target: "value"}}, Originals: "allColumns"}}
}
func wait(t *testing.T, m *Manager, id string) *protocol.DataComparisonResponse {
	t.Helper()
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		r := m.Handle(protocol.Command{Type: "data.status", DataComparison: &protocol.DataComparisonRequest{JobID: id}})
		if r.DataComparison != nil && r.DataComparison.State != "pending" && r.DataComparison.State != "running" {
			return r.DataComparison
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("comparison did not terminate")
	return nil
}
func TestTwoOwnersExactTypesPartialDuplicatesAndCleanup(t *testing.T) {
	var calls atomic.Int32
	owners := make(chan *fakeReader, 2)
	m, e := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
		i := calls.Add(1)
		rows := [][]*string{{str("1"), str("9007199254740993.123456789")}, {str("2"), nil}, {str("2"), str("")}}
		if i == 2 {
			rows = [][]*string{{str("1"), str("9007199254740993.123456788")}, {str("3"), str("NULL")}}
		}
		s := &fakeReader{rows: rows}
		owners <- s
		return s, nil
	}, Options{Root: t.TempDir()})
	if e != nil {
		t.Fatal(e)
	}
	defer m.Close()
	start := m.Handle(command())
	if start.DataComparison == nil {
		t.Fatal("start rejected")
	}
	id := start.DataComparison.JobID
	out := wait(t, m, id)
	if out.State != "completed" || out.Summary == nil {
		t.Fatal("comparison failed")
	}
	sum := out.Summary.Comparison
	if sum.ChangedRows != 1 || sum.AmbiguousRows != 2 || sum.AddedRows+sum.DeletedRows != 1 || sum.FullEquality {
		t.Fatal("exact/duplicate comparison incorrect")
	}
	for range 2 {
		if s := <-owners; !s.closed.Load() {
			t.Fatal("database session remained open for offline inspection")
		}
	}
	page := m.Handle(protocol.Command{Type: "data.page", DataComparison: &protocol.DataComparisonRequest{JobID: id, Limit: 100, MaxBytes: 262144}})
	if page.DataComparison == nil || len(page.DataComparison.Page.Rows) == 0 {
		t.Fatal("page unavailable")
	}
	root := m.root
	m.Close()
	if _, e = os.Stat(root); !os.IsNotExist(e) {
		t.Fatal("temporary data survived shutdown")
	}
}
func TestLimitNAndQuotaNeverEstablishCompleteEquality(t *testing.T) {
	for _, quota := range []bool{false, true} {
		t.Run(map[bool]string{false: "readLimit", true: "storageLimit"}[quota], func(t *testing.T) {
			gate := make(chan struct{})
			entered := make(chan struct{}, 2)
			rows := [][]*string{{str("1"), str("a")}, {str("2"), str("b")}, {str("3"), str("c")}}
			options := Options{Root: t.TempDir()}
			if quota {
				options.QuotaBytes = 16 << 20
				for i := range rows {
					rows[i][1] = str(strings.Repeat("x", 2<<20))
				}
			}
			m, e := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
				return &fakeReader{rows: rows, gate: gate, entered: entered}, nil
			}, options)
			if e != nil {
				t.Fatal(e)
			}
			defer m.Close()
			c := command()
			if !quota {
				c.DataComparison.Source.ReadLimit = 2
				c.DataComparison.Target.ReadLimit = 2
			}
			start := m.Handle(c)
			<-entered
			<-entered
			close(gate)
			out := wait(t, m, start.DataComparison.JobID)
			if out.State != "completed" || out.Summary.Comparison.Complete || out.Summary.Comparison.FullEquality {
				t.Fatal("partial capture was presented as complete")
			}
			if len(out.Summary.Source.PartialReasons) == 0 || len(out.Summary.Target.PartialReasons) == 0 {
				t.Fatal("partial scopes were not both marked")
			}
		})
	}
}
func TestCancelDuringLateOpenAndSafeFailure(t *testing.T) {
	gate := make(chan struct{})
	entered := make(chan struct{}, 2)
	closed := make(chan *fakeReader, 2)
	m, e := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
		entered <- struct{}{}
		<-gate
		s := &fakeReader{}
		closed <- s
		return s, nil
	}, Options{Root: t.TempDir()})
	if e != nil {
		t.Fatal(e)
	}
	start := m.Handle(command())
	<-entered
	<-entered
	out := m.Handle(protocol.Command{Type: "data.cancel", DataComparison: &protocol.DataComparisonRequest{JobID: start.DataComparison.JobID}})
	if out.DataComparison.State != "cancelled" {
		t.Fatal("cancel did not acknowledge")
	}
	close(gate)
	m.Close()
	for range 2 {
		if !(<-closed).closed.Load() {
			t.Fatal("late successful open leaked")
		}
	}
	failure, e := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
		return nil, errors.New("synthetic-secret-server-detail")
	}, Options{Root: t.TempDir()})
	if e != nil {
		t.Fatal(e)
	}
	defer failure.Close()
	failed := wait(t, failure, failure.Handle(command()).DataComparison.JobID)
	b, _ := json.Marshal(failed)
	if strings.Contains(string(b), "synthetic-secret") {
		t.Fatal("server detail leaked")
	}
}
