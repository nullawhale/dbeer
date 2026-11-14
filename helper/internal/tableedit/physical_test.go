package tableedit

import (
	"context"
	"strings"
	"testing"
	"time"
)

type physicalFake struct {
	state      string
	observeErr error
	entered    chan struct{}
	release    chan struct{}
	calls      int
}

func (f *physicalFake) PhysicalPrepare(_ context.Context, d PhysicalDraft) (PhysicalPlan, error) {
	return PhysicalPlan{Engine: "postgresql", ServerVersion: 170000, SQL: []string{"reviewed"}, Objects: []PhysicalObject{{Target: d.Target}}, EvidenceDigest: strings.Repeat("a", 64)}, nil
}
func (f *physicalFake) PhysicalExecute(ctx context.Context, p PhysicalPlan, progress func(int, string)) []Execution {
	f.calls++
	progress(0, "running")
	if f.entered != nil {
		close(f.entered)
		select {
		case <-ctx.Done():
		case <-f.release:
		}
	}
	return []Execution{{State: f.state}}
}
func (f *physicalFake) PhysicalObserve(context.Context, PhysicalPlan) ([]PhysicalObject, error) {
	return []PhysicalObject{{Kind: "observed"}}, f.observeErr
}
func physicalTestDraft() PhysicalDraft {
	return PhysicalDraft{Version: 1, Target: Target{Schema: "app", Table: "t"}, Intent: PhysicalIntent{Kind: "concurrentIndex", Index: &IndexEdit{Action: "add", Name: "idx", Columns: []string{"c"}}}}
}
func TestPhysicalSingleUseAndUnknownObservation(t *testing.T) {
	for _, state := range []string{"applied", "unknown", "failed", "notStarted"} {
		t.Run(state, func(t *testing.T) {
			a := &physicalFake{state: state}
			var s PhysicalStore
			r, e := s.Preview(context.Background(), a, physicalTestDraft())
			if e != nil {
				t.Fatal(e)
			}
			apply := Apply{PlanID: r.Plan.ID, Digest: r.Plan.Digest, ExecutionID: "execution"}
			result, e := s.Apply(context.Background(), a, apply)
			if e != nil {
				t.Fatal(e)
			}
			if result.Outcome.Steps[0].State != state || !result.Outcome.Reconciled {
				t.Fatal(result)
			}
			if state == "unknown" && result.Outcome.State != "outcomeUnknown" {
				t.Fatal("observation promoted unknown acknowledgement")
			}
			if _, e = s.Apply(context.Background(), a, apply); e == nil || a.calls != 1 {
				t.Fatal("physical plan replayed")
			}
		})
	}
}
func TestPhysicalStatusDoesNotWaitForWorkerAndPreservesEvidence(t *testing.T) {
	a := &physicalFake{state: "unknown", entered: make(chan struct{}), release: make(chan struct{}), observeErr: ErrUnsupported}
	var s PhysicalStore
	r, e := s.Preview(context.Background(), a, physicalTestDraft())
	if e != nil {
		t.Fatal(e)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		_, _ = s.Apply(context.Background(), a, Apply{PlanID: r.Plan.ID, Digest: r.Plan.Digest, ExecutionID: "e"})
	}()
	<-a.entered
	status := s.Status()
	if status.Outcome.State != "applying" || status.Outcome.Phase != "running" || s.Close() {
		t.Fatal(status)
	}
	if _, e = s.Preview(context.Background(), a, physicalTestDraft()); e == nil {
		t.Fatal("active plan replaced")
	}
	close(a.release)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("worker stuck")
	}
	if !s.NeedsReconciliation() || s.Close() {
		t.Fatal("unknown evidence erased")
	}
	a.observeErr = nil
	if _, e = s.Reconcile(context.Background(), a); e != nil || s.Status().Outcome.State != "outcomeUnknown" || !s.Close() {
		t.Fatal("reconciliation changed acknowledgement")
	}
}
func TestPhysicalClosedIntentAndExactValues(t *testing.T) {
	v := func(k, s string) PhysicalValue { return PhysicalValue{Kind: k, Value: &s} }
	for _, value := range []PhysicalValue{v("integer", "90071992547409931234567890"), v("text", ""), v("text", "NULL"), {Kind: "null"}} {
		if !value.Valid() {
			t.Fatal(value)
		}
	}
	for _, value := range []PhysicalValue{v("integer", "01"), v("integer", "+1"), v("integer", "-0"), v("null", "NULL"), v("text", "\x00"), v("expression", "1")} {
		if value.Valid() {
			t.Fatal(value)
		}
	}
	d := physicalTestDraft()
	d.Intent.Engine = "MyISAM"
	if d.Valid() {
		t.Fatal("unselected field admitted")
	}
	d = physicalTestDraft()
	d.Version = 2
	if d.Valid() {
		t.Fatal("future intent version admitted")
	}
}
