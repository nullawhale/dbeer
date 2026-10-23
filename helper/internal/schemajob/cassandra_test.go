package schemajob

import (
	"context"
	"sync/atomic"
	"testing"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
)

type cassandraSchemaReader struct{ closed atomic.Bool }

func (*cassandraSchemaReader) Execute(context.Context, protocol.Command) protocol.Response {
	panic("schema capture ran caller CQL")
}
func (*cassandraSchemaReader) TransactionStatus() string { return "unsupported" }
func (s *cassandraSchemaReader) Close()                  { s.closed.Store(true) }
func (*cassandraSchemaReader) ReadSchema(_ context.Context, spec sc.CaptureSpec, sink sc.Sink) error {
	for _, name := range spec.Schemas {
		if err := sink.Inventory(sc.Inventory{Schema: name, Existence: "present", Tables: sc.Complete[sc.Ref](nil), Types: sc.Complete[sc.Ref](nil)}); err != nil {
			return err
		}
	}
	return sink.Context(sc.CaptureContext{Engine: "cassandra", Version: "5.0", Database: "fixture", StartedAt: "2026-10-23T10:00:00Z", FinishedAt: "2026-10-23T10:00:01Z", Consistency: "bestEffort", Visibility: "complete", EngineContext: sc.Known([]sc.Option{})})
}
func TestCassandraSchemaCaptureUsesTwoCatalogReadersWithoutServerTransactions(t *testing.T) {
	owners := make(chan *cassandraSchemaReader, 2)
	m, err := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
		s := &cassandraSchemaReader{}
		owners <- s
		return s, nil
	}, Options{Root: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	c := startCommand()
	c.SchemaComparison.Source.Connection.Engine, c.SchemaComparison.Target.Connection.Engine = "cassandra", "cassandra"
	started := m.Handle(c)
	if started.SchemaComparison == nil {
		t.Fatal("Cassandra schema rejected")
	}
	waitState(t, m, started.SchemaComparison.JobID, "completed")
	result := m.Handle(protocol.Command{Type: "schema.status", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: started.SchemaComparison.JobID}})
	if result.SchemaComparison.Summary.Engine != "cassandra" || result.SchemaComparison.Summary.Source.Consistency != "bestEffort" {
		t.Fatal("Cassandra capture context was lost")
	}
	for range 2 {
		if !(<-owners).closed.Load() {
			t.Fatal("catalog owner leaked")
		}
	}
}
