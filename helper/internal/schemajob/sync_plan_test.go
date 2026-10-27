package schemajob

import (
	"context"
	"strings"
	"sync/atomic"
	"testing"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/syncplan"
)

func TestSchemaPlanRequiresLiveCompletedDigestAndNeverReopens(t *testing.T) {
	var opened, rendered atomic.Int32
	m, err := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
		opened.Add(1)
		return &fakeSession{}, nil
	}, Options{Root: t.TempDir(), RenderPlan: func(_ context.Context, report sc.Report) (syncplan.Plan, error) {
		rendered.Add(1)
		return syncplan.New("schema", report.Summary.Engine, report.Summary.ModelDigest), nil
	}})
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()
	started := m.Handle(startCommand())
	id := started.SchemaComparison.JobID
	waitState(t, m, id, "completed")
	status := m.Handle(protocol.Command{Type: "schema.status", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id}})
	digest := status.SchemaComparison.Summary.ModelDigest
	request := func(value string) protocol.Response {
		return m.Handle(protocol.Command{Type: "schema.plan", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id, ModelDigest: value}})
	}
	if wrong := request(strings.Repeat("0", 64)); wrong.SchemaComparison != nil || rendered.Load() != 0 {
		t.Fatal("stale digest reached renderer")
	}
	valid := request(digest)
	if valid.SchemaComparison == nil || valid.SchemaComparison.Plan == nil || opened.Load() != 2 || rendered.Load() != 1 {
		t.Fatal("frozen plan reopened sessions or lost response")
	}
	m.Handle(protocol.Command{Type: "schema.close", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: id}})
	if closed := request(digest); closed.SchemaComparison != nil || rendered.Load() != 1 {
		t.Fatal("closed owner still generated a plan")
	}
}
