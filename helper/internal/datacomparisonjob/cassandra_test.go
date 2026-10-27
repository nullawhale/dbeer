package datacomparisonjob

import (
	"context"
	"sync/atomic"
	"testing"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	tc "dbeer/helper/internal/tablecapture"
)

// This session deliberately has no server ReadOnlySession implementation.
// Cassandra comparison must use its SELECT-only capture API directly.
type cassandraReader struct{ closed atomic.Bool }

func (*cassandraReader) Execute(context.Context, protocol.Command) protocol.Response {
	panic("comparison ran caller CQL")
}
func (*cassandraReader) TransactionStatus() string { return "unsupported" }
func (s *cassandraReader) Close()                  { s.closed.Store(true) }
func (*cassandraReader) DescribeTable(_ context.Context, table tc.Table) (tc.Descriptor, error) {
	d := descriptor(table)
	d.Engine = "cassandra"
	return d, d.Seal()
}
func (s *cassandraReader) CaptureTable(ctx context.Context, spec tc.Spec, sink tc.Sink) (tc.Descriptor, tc.Outcome, error) {
	d, err := s.DescribeTable(ctx, spec.Table)
	out := tc.Outcome{StartedAt: "2026-10-23T10:00:00Z", FinishedAt: "2026-10-23T10:00:01Z", Consistency: "bestEffort", Rendering: "cassandraCQLv1", ReadLimit: spec.ReadLimit, PartialReasons: []string{"nonSnapshot"}, StoredRows: 1, ObservedAtLeast: 1}
	if err != nil {
		return d, out, err
	}
	if err = tc.Validate(d, spec); err != nil {
		return d, out, err
	}
	return d, out, sink.Row([]*string{str("1"), str("exact")})
}
func TestCassandraCapturesHaveIndependentOwnersAndNeverClaimSnapshotEquality(t *testing.T) {
	owners := make(chan *cassandraReader, 2)
	m, err := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
		s := &cassandraReader{}
		owners <- s
		return s, nil
	}, Options{Root: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	c := command()
	for _, side := range []*protocol.DataReadSide{c.DataComparison.Source, c.DataComparison.Target} {
		side.Connection.Engine = "cassandra"
		d, _ := (&cassandraReader{}).DescribeTable(context.Background(), side.Table)
		side.DescriptorDigest = d.Digest
	}
	started := m.Handle(c)
	if started.DataComparison == nil {
		t.Fatal("Cassandra capture rejected")
	}
	result := wait(t, m, started.DataComparison.JobID)
	if result.State != "completed" || result.Summary == nil || result.Summary.Comparison.Complete || result.Summary.Comparison.FullEquality || result.Summary.Comparison.EqualRows != 1 {
		t.Fatal("non-snapshot capture was lost or claimed complete equality")
	}
	for range 2 {
		if !(<-owners).closed.Load() {
			t.Fatal("capture owner leaked")
		}
	}
}
