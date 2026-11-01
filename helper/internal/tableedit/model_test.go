package tableedit

import (
	"context"
	"testing"
)

type fake struct {
	calls        int
	state        string
	refreshError bool
}

func (f *fake) StructureLoad(_ context.Context, t Target) (Baseline, error) {
	if f.refreshError && f.calls > 0 {
		return Baseline{}, ErrUnsupported
	}
	return Baseline{Target: t, Engine: "postgresql", Fingerprint: Fingerprint(t), Columns: []ObservedColumn{}, Limitations: []string{}}, nil
}
func (f *fake) StructureRender(b Baseline, d Draft) ([]string, []string, error) {
	return []string{"synthetic statement"}, []string{"synthetic risk"}, nil
}
func (f *fake) StructureApply(context.Context, Baseline, []string) Execution {
	f.calls++
	return Execution{State: f.state}
}
func prepare(t *testing.T, s *Store, f *fake) Apply {
	t.Helper()
	r, e := s.Load(context.Background(), f, Target{Schema: "public", Table: "samples", Create: true})
	if e != nil {
		t.Fatal(e)
	}
	p, e := s.Preview(f, r.Baseline.ID, Draft{Columns: []Column{{Name: "name", Type: DataType{Kind: "text"}, Nullable: true, Default: Default{Kind: "none"}}}})
	if e != nil {
		t.Fatal(e)
	}
	return Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "execution"}
}
func TestUnknownOutcomeSurvivesMatchingObservationAndCannotReplay(t *testing.T) {
	s := &Store{}
	f := &fake{state: "unknown"}
	a := prepare(t, s, f)
	r, e := s.Apply(context.Background(), f, a)
	if e != nil || r.Outcome.State != "outcomeUnknown" || r.Outcome.Observed == nil {
		t.Fatal("unknown evidence was lost")
	}
	if _, e = s.Apply(context.Background(), f, a); e == nil || f.calls != 1 {
		t.Fatal("uncertain DDL replayed")
	}
}
func TestAcknowledgedApplySurvivesRefreshFailure(t *testing.T) {
	s := &Store{}
	f := &fake{state: "applied", refreshError: true}
	a := prepare(t, s, f)
	r, e := s.Apply(context.Background(), f, a)
	if e != nil || r.Outcome.State != "applied" || r.Outcome.RefreshError == "" {
		t.Fatal("refresh failure rewrote acknowledgement")
	}
}
func TestCancellationBeforeDispatchAndChangedDigestNeverExecute(t *testing.T) {
	s := &Store{}
	f := &fake{state: "applied"}
	a := prepare(t, s, f)
	changed := a
	changed.Digest = Fingerprint("different")
	if _, e := s.Apply(context.Background(), f, changed); e == nil {
		t.Fatal("changed digest accepted")
	}
	ctx, c := context.WithCancel(context.Background())
	c()
	r, e := s.Apply(ctx, f, a)
	if e != nil || r.Outcome.State != "cancelled" || f.calls != 0 {
		t.Fatal("cancelled request dispatched")
	}
}
func TestAppendRejectsSupportedPrefix(t *testing.T) {
	s := &Store{}
	f := &fake{state: "applied"}
	r, _ := s.Load(context.Background(), f, Target{Schema: "public", Table: "samples"})
	c := Column{Name: "a", Type: DataType{Kind: "text"}, Nullable: true, Default: Default{Kind: "none"}}
	if _, e := s.Preview(f, r.Baseline.ID, Draft{Columns: []Column{c, c}}); e == nil {
		t.Fatal("multi-column append accepted")
	}
	c.Nullable = false
	if _, e := s.Preview(f, r.Baseline.ID, Draft{Columns: []Column{c}}); e == nil {
		t.Fatal("non-null append accepted")
	}
}
