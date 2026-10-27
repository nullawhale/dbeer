package datacomparisonjob

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/syncplan"
	tc "dbeer/helper/internal/tablecapture"
	"encoding/json"
	"strings"
	"sync/atomic"
	"testing"
)

func TestDataPlanUsesCompletedCaptureWithoutOpeningOrExecuting(t *testing.T) {
	var opens, renders atomic.Int32
	m, e := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
		i := opens.Add(1)
		value := "source"
		if i == 2 {
			value = "target"
		}
		return &fakeReader{rows: [][]*string{{str("1"), str(value)}}}, nil
	}, Options{Root: t.TempDir(), RenderData: func(op syncplan.DataOperation) (string, error) {
		renders.Add(1)
		if op.Kind != "update" || op.Source == nil || op.Target == nil || len(op.Target) != 2 {
			t.Fatal("planner received previews instead of full rows")
		}
		return "UPDATE target SET value='draft';", nil
	}})
	if e != nil {
		t.Fatal(e)
	}
	defer m.Close()
	start := m.Handle(command())
	id := start.DataComparison.JobID
	completed := wait(t, m, id)
	if completed.Summary == nil {
		t.Fatal("capture failed")
	}
	request := protocol.Command{Type: "data.plan", DataComparison: &protocol.DataComparisonRequest{JobID: id, ModelDigest: completed.Summary.ModelDigest}}
	plan := m.Handle(request)
	if plan.DataComparison == nil || plan.DataComparison.Plan == nil || len(plan.DataComparison.Plan.Steps) != 1 || !plan.DataComparison.Plan.Steps[0].Destructive || plan.DataComparison.Plan.Steps[0].Selected {
		t.Fatal("completed plan missing or unsafe defaults")
	}
	if opens.Load() != 2 || renders.Load() != 1 {
		t.Fatal("planning opened database sessions")
	}
	request.DataComparison.ModelDigest = strings.Repeat("f", 64)
	if rejected := m.Handle(request); rejected.Type != "error" || renders.Load() != 1 {
		t.Fatal("stale digest reached planner")
	}
	m.Handle(protocol.Command{Type: "data.close", DataComparison: &protocol.DataComparisonRequest{JobID: id}})
	request.DataComparison.ModelDigest = completed.Summary.ModelDigest
	if rejected := m.Handle(request); rejected.Type != "error" {
		t.Fatal("expired capture produced plan")
	}
}

func TestDataPlanRejectsMissingOriginalsWithExplicitManualStep(t *testing.T) {
	var calls atomic.Int32
	m, e := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
		i := calls.Add(1)
		value := "a"
		if i == 2 {
			value = "b"
		}
		return &fakeReader{rows: [][]*string{{str("1"), str(value)}}}, nil
	}, Options{Root: t.TempDir(), RenderData: func(syncplan.DataOperation) (string, error) {
		t.Fatal("incomplete originals reached SQL generator")
		return "", nil
	}})
	if e != nil {
		t.Fatal(e)
	}
	defer m.Close()
	c := command()
	c.DataComparison.Originals = "selectedColumns"
	start := m.Handle(c)
	completed := wait(t, m, start.DataComparison.JobID)
	if completed.Summary == nil {
		t.Fatal("capture failed")
	}
	r := m.Handle(protocol.Command{Type: "data.plan", DataComparison: &protocol.DataComparisonRequest{JobID: start.DataComparison.JobID, ModelDigest: completed.Summary.ModelDigest}})
	if r.DataComparison == nil || r.DataComparison.Plan == nil || len(r.DataComparison.Plan.Steps) != 1 || !r.DataComparison.Plan.Steps[0].Manual {
		t.Fatal("missing originals silently planned")
	}
}

type selectivePlanReader struct {
	*fakeReader
	descriptor tc.Descriptor
}

func (s *selectivePlanReader) DescribeTable(ctx context.Context, table tc.Table) (tc.Descriptor, error) {
	if e := ctx.Err(); e != nil {
		return tc.Descriptor{}, e
	}
	if !s.readonly.Load() || table != s.descriptor.Table {
		return tc.Descriptor{}, tc.ErrInvalid
	}
	return s.descriptor, nil
}
func (s *selectivePlanReader) CaptureTable(ctx context.Context, spec tc.Spec, sink tc.Sink) (tc.Descriptor, tc.Outcome, error) {
	d := s.descriptor
	out := tc.Outcome{StartedAt: "2026-10-27T10:00:00Z", FinishedAt: "2026-10-27T10:00:01Z", Consistency: "repeatableRead", Rendering: "postgresTextUTCISOv1", ReadLimit: spec.ReadLimit, PartialReasons: []string{}}
	if e := tc.Validate(d, spec); e != nil {
		return d, out, e
	}
	for _, row := range s.rows {
		if e := ctx.Err(); e != nil {
			return d, out, e
		}
		selected := []*string{}
		for _, name := range spec.Columns {
			for i, c := range d.Columns {
				if c.Name == name {
					selected = append(selected, row[i])
					break
				}
			}
		}
		if e := sink.Row(selected); e != nil {
			return d, out, e
		}
		out.StoredRows++
		out.ObservedAtLeast++
	}
	return d, out, nil
}

func TestDataPlanManagerSupportsSelectiveAndRenamedMappings(t *testing.T) {
	for _, scenario := range []string{"sourceExcluded", "targetExcluded", "renamed", "insertMissingTarget"} {
		t.Run(scenario, func(t *testing.T) {
			a := descriptor(tc.Table{Schema: "public", Name: "source"})
			b := descriptor(tc.Table{Schema: "public", Name: "target"})
			left, right := [][]*string{{str("1"), str("new")}}, [][]*string{{str("1"), str("old")}}
			mappings := []tc.Mapping{{Source: "id", Target: "id", Key: true}, {Source: "value", Target: "value"}}
			switch scenario {
			case "sourceExcluded":
				a.Columns = append(a.Columns, tc.Column{Index: 2, Name: "revision", NativeType: "int8", TypeLabel: "int8", Definition: json.RawMessage(`{}`)})
				left[0] = append(left[0], str("7"))
			case "targetExcluded", "insertMissingTarget":
				b.Columns = append(b.Columns, tc.Column{Index: 2, Name: "preserved", NativeType: "text", TypeLabel: "text", Definition: json.RawMessage(`{}`)})
				right[0] = append(right[0], str("full original"))
				if scenario == "insertMissingTarget" {
					left = [][]*string{{str("2"), str("insert")}}
					right = [][]*string{}
				}
			case "renamed":
				a.Columns[0].Name = "source_key"
				a.Columns[1].Name = "source_value"
				b.Columns[0].Name = "target_key"
				b.Columns[1].Name = "target_value"
				mappings = []tc.Mapping{{Source: "source_key", Target: "target_key", Key: true}, {Source: "source_value", Target: "target_value"}}
			}
			if e := a.Seal(); e != nil {
				t.Fatal(e)
			}
			if e := b.Seal(); e != nil {
				t.Fatal(e)
			}
			var opens, renders atomic.Int32
			m, e := New(func(_ context.Context, c protocol.Connection) (adapter.Session, error) {
				opens.Add(1)
				d, rows := a, left
				if c.Database == "target" {
					d, rows = b, right
				}
				return &selectivePlanReader{fakeReader: &fakeReader{rows: rows}, descriptor: d}, nil
			}, Options{Root: t.TempDir(), RenderData: func(op syncplan.DataOperation) (string, error) {
				renders.Add(1)
				if scenario == "targetExcluded" && (len(op.Target) != 3 || *op.Target[2] != "full original") {
					t.Fatal("excluded full target original was lost")
				}
				if scenario == "insertMissingTarget" {
					t.Fatal("missing target INSERT mapping reached renderer")
				}
				return "UPDATE target SET value='draft';", nil
			}})
			if e != nil {
				t.Fatal(e)
			}
			defer m.Close()
			filters := []tc.Filter{}
			c := protocol.Command{Type: "data.start", DataComparison: &protocol.DataComparisonRequest{
				Source: &protocol.DataReadSide{Connection: protocol.Connection{Database: "source"}, Table: a.Table, DescriptorDigest: a.Digest, ReadLimit: 100, Filters: &filters},
				Target: &protocol.DataReadSide{Connection: protocol.Connection{Database: "target"}, Table: b.Table, DescriptorDigest: b.Digest, ReadLimit: 100, Filters: &filters}, Columns: mappings, Originals: "allColumns"}}
			start := m.Handle(c)
			if start.DataComparison == nil {
				t.Fatal("capture did not start")
			}
			sum := wait(t, m, start.DataComparison.JobID)
			if sum.Summary == nil || sum.Summary.Comparison.SchemaDifferenceCount == 0 {
				t.Fatal("selective comparison did not retain schema differences")
			}
			planned := m.Handle(protocol.Command{Type: "data.plan", DataComparison: &protocol.DataComparisonRequest{JobID: start.DataComparison.JobID, ModelDigest: sum.Summary.ModelDigest}})
			if planned.DataComparison == nil || planned.DataComparison.Plan == nil || len(planned.DataComparison.Plan.Steps) != 1 {
				t.Fatal("selective capture plan failed")
			}
			manual := scenario == "insertMissingTarget"
			if planned.DataComparison.Plan.Steps[0].Manual != manual || (renders.Load() == 0) != manual || opens.Load() != 2 {
				t.Fatal("selective planning gate or offline ownership incorrect")
			}
		})
	}
}
