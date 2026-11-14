package tableedit

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"encoding/json"
	"strings"
	"testing"
)

type migrationFake struct {
	db           map[string]Baseline
	calls, loads int
	states       []string
	after        func(*migrationFake)
}

func migrationTestBaseline(name string) Baseline {
	target := Target{Schema: "fixture", Table: name}
	f := &Facts{Proof: true, Dependents: map[string][]string{}, Table: sc.Table{Ref: sc.Ref{Kind: "table", Schema: target.Schema, Name: name}, Columns: sc.Complete[sc.Column](nil), Constraints: sc.Complete[sc.Constraint](nil), Indexes: sc.Complete[sc.Index](nil)}}
	b := Baseline{Target: target, Engine: "postgresql", Scope: "same-server", Identity: name, Guard: "unchanged", Facts: f, Attributes: map[string]map[string]any{}, Columns: []ObservedColumn{}, Keys: []Key{}, Indexes: []Index{}, Limitations: []string{}}
	b.Fingerprint = Fingerprint([]any{name, f})
	return b
}
func (a *migrationFake) StructureLoad(_ context.Context, t Target) (Baseline, error) {
	a.loads++
	b, ok := a.db[migrationTarget(t)]
	if !ok {
		if !t.Create {
			return b, ErrInvalid
		}
		b = migrationTestBaseline(t.Table)
		b.Target = t
		b.Identity = ""
	}
	if t.Reconcile {
		t.Create = b.Target.Create
		t.Reconcile = false
	}
	if t.Create != b.Target.Create {
		return b, ErrInvalid
	}
	loaded := migrationClone(b)
	// Real adapter loads publish the required public collections as arrays.
	loaded.Columns = append([]ObservedColumn{}, loaded.Columns...)
	loaded.Keys = append([]Key{}, loaded.Keys...)
	loaded.Indexes = append([]Index{}, loaded.Indexes...)
	return loaded, nil
}
func (a *migrationFake) StructureRender(Baseline, Draft) ([]string, []string, error) {
	return nil, nil, ErrUnsupported
}
func (a *migrationFake) StructureApply(context.Context, Baseline, []string) Execution {
	return Execution{State: "unknown"}
}
func (a *migrationFake) StructurePrepare(ctx context.Context, b Baseline, d Draft) (Prepared, error) {
	return a.StructurePrepareMigration(ctx, b, d, func(t Target) (Baseline, error) { return a.StructureLoad(ctx, t) })
}
func (a *migrationFake) StructurePrepareMigration(_ context.Context, b Baseline, d Draft, load func(Target) (Baseline, error)) (Prepared, error) {
	ops, refs, err := PlanMigrationOperations(b, d, b.Engine, load)
	if err != nil {
		return Prepared{}, err
	}
	p := Prepared{SQL: []string{}, Risks: []string{}, References: refs, ResultTarget: ResultTarget(b.Target, d), DroppedTarget: d.DropTable}
	for _, op := range ops {
		p.SQL = append(p.SQL, "synthetic "+op.Kind)
		p.Conditions = append(p.Conditions, Condition{Operation: op, Columns: d.Columns})
	}
	return p, nil
}
func (a *migrationFake) StructureApplySteps(_ context.Context, b Baseline, p Plan) []Execution {
	a.calls++
	state := "applied"
	if a.calls <= len(a.states) {
		state = a.states[a.calls-1]
	}
	if state != "applied" {
		return []Execution{{State: state}}
	}
	for _, condition := range p.Conditions {
		d := Draft{Columns: []Column{}}
		op := condition.Operation
		switch op.Kind {
		case "addColumn":
			d.Columns = []Column{*op.Column}
		case "dropKey", "addKey":
			d.Keys = []KeyEdit{*op.Key}
		case "renameColumn":
			d.Changes = []ColumnChange{*op.Change}
		case "renameTable":
			d.RenameTable = op.Name
		case "dropTable":
			d.DropTable = true
		}
		before := b
		b, _ = migrationProject(b, d)
		b.Fingerprint = Fingerprint([]any{b.Target, b.Facts, b.Keys, b.Columns})
		delete(a.db, migrationTarget(before.Target))
		a.db[migrationTarget(b.Target)] = b
		for key, other := range a.db {
			for _, edit := range d.Keys {
				if edit.Kind != "foreign" {
					continue
				}
				if edit.Action == "drop" {
					for _, k := range before.Keys {
						if k.Name == edit.Name {
							edit.Reference = k.Reference
							edit.ReferenceColumns = k.ReferenceColumns
						}
					}
				}
				other = migrationIncoming(other, before.Target, edit, edit.Action != "drop")
			}
			other.Fingerprint = Fingerprint([]any{other.Target, other.Facts, other.Keys, other.Columns})
			a.db[key] = other
		}
	}
	if a.after != nil {
		a.after(a)
	}
	out := make([]Execution, len(p.SQL))
	for i := range out {
		out[i].State = "applied"
	}
	return out
}
func migrationTestDraft() MigrationDraft {
	col := Column{Name: "added", Type: DataType{Kind: "integer"}, Nullable: true, Default: Default{Kind: "none"}}
	return MigrationDraft{Version: 1, Objects: []MigrationObject{{ID: "later", Target: Target{Schema: "fixture", Table: "b"}, Draft: Draft{Columns: []Column{col}}, After: []string{"first"}}, {ID: "first", Target: Target{Schema: "fixture", Table: "a"}, Draft: Draft{Columns: []Column{col}}, After: []string{}}}, Repairs: []MigrationRepair{}}
}
func migrationTestAdapter() *migrationFake {
	return &migrationFake{db: map[string]Baseline{"fixture\x00a": migrationTestBaseline("a"), "fixture\x00b": migrationTestBaseline("b")}}
}
func migrationTestPlan(t *testing.T, s *MigrationStore, a *migrationFake) Apply {
	t.Helper()
	r, e := s.Preview(context.Background(), a, migrationTestDraft())
	if e != nil {
		t.Fatal(e)
	}
	if r.Plan.Steps[0].ObjectID != "first" || len(r.Plan.Steps[1].Before) != 2 || len(r.Plan.Steps[1].Before[0].AfterSteps) != 1 || len(r.Plan.Steps[1].After[0].AfterSteps) != 2 {
		t.Fatal("dependency order or semantic intermediate structures missing")
	}
	return Apply{PlanID: r.Plan.ID, Digest: r.Plan.Digest, ExecutionID: "execution"}
}
func TestMigrationPartialRetainsIntentAndRequiresReconciliation(t *testing.T) {
	a := migrationTestAdapter()
	a.states = []string{"applied", "failed"}
	s := &MigrationStore{}
	apply := migrationTestPlan(t, s, a)
	reply, err := s.Apply(context.Background(), a, apply)
	if err != nil || reply.Outcome.State != "partiallyApplied" || reply.Draft == nil || !reply.Outcome.ReconciliationRequired || reply.Outcome.Steps[0].Statements[0].State != "applied" || reply.Outcome.Steps[1].Statements[0].State != "failed" {
		t.Fatalf("lost partial evidence: %#v %v", reply.Outcome, err)
	}
	if _, err = s.Apply(context.Background(), a, apply); err == nil || a.calls != 2 {
		t.Fatal("retained migration replayed")
	}
	if _, err = s.Preview(context.Background(), a, migrationTestDraft()); err == nil {
		t.Fatal("new preview bypassed reconciliation")
	}
	observed, err := s.Reconcile(context.Background(), a)
	if err != nil || len(observed.Observed) != 2 || observed.Outcome.ReconciliationRequired || observed.Draft == nil {
		t.Fatal("reconciliation lost intent or was implicit")
	}
}
func TestMigrationUnknownStopsWithoutObservationOrReplay(t *testing.T) {
	a := migrationTestAdapter()
	a.states = []string{"unknown"}
	s := &MigrationStore{}
	apply := migrationTestPlan(t, s, a)
	loads := a.loads
	r, err := s.Apply(context.Background(), a, apply)
	if err != nil || r.Outcome.State != "outcomeUnknown" || a.calls != 1 || a.loads-loads != 2 || r.Outcome.Steps[1].State != "notStarted" {
		t.Fatal("unknown execution was observed, retried or advanced")
	}
	s.Close()
	if _, err = s.Preview(context.Background(), a, migrationTestDraft()); err == nil {
		t.Fatal("Close erased the reconciliation barrier")
	}
}
func TestMigrationStaleOtherObjectAndChangedDigestNeverDispatch(t *testing.T) {
	a := migrationTestAdapter()
	s := &MigrationStore{}
	apply := migrationTestPlan(t, s, a)
	changed := apply
	changed.Digest = Fingerprint("changed")
	if _, err := s.Apply(context.Background(), a, changed); err == nil {
		t.Fatal("changed whole-plan digest accepted")
	}
	b := a.db["fixture\x00b"]
	b.Fingerprint = Fingerprint("concurrent change")
	a.db["fixture\x00b"] = b
	r, err := s.Apply(context.Background(), a, apply)
	if err != nil || r.Outcome.State != "failed" || a.calls != 0 {
		t.Fatal("stale external guard dispatched DDL")
	}
}
func TestMigrationCancelAndGuardedExport(t *testing.T) {
	a := migrationTestAdapter()
	s := &MigrationStore{}
	apply := migrationTestPlan(t, s, a)
	r, err := s.Export(apply)
	if err != nil || !strings.Contains(r.Export.SQL, "MANUAL") || r.Export.Draft.Version != 1 {
		t.Fatal("manual SQL or portable intent missing")
	}
	raw, _ := json.Marshal(r.Export.Draft)
	for _, key := range []string{"authorization", "password", "planId", "fingerprint", "sql"} {
		if strings.Contains(string(raw), `"`+key+`"`) {
			t.Fatal("portable intent contains execution authority")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	r, err = s.Apply(ctx, a, apply)
	if err != nil || r.Outcome.State != "cancelled" || a.calls != 0 {
		t.Fatal("cancelled migration dispatched")
	}
}
func TestMigrationCycleAndNativeRepairSemantics(t *testing.T) {
	d := migrationTestDraft()
	d.Objects[1].After = []string{"later"}
	a := migrationTestAdapter()
	if _, err := (&MigrationStore{}).Preview(context.Background(), a, d); err == nil {
		t.Fatal("cyclic graph accepted")
	}
	b := migrationTestBaseline("owner")
	parent := Target{Schema: "fixture", Table: "parent"}
	fk := sc.NewConstraint(sc.Ref{Kind: "constraint", Schema: "fixture", Table: "owner", Name: "selected"}, "f")
	fk.Match = sc.Known("s")
	fk.Target = sc.Known(sc.Ref{Kind: "table", Schema: parent.Schema, Name: parent.Table})
	b.Facts.Table.Constraints.Items = []sc.Constraint{fk}
	b.Keys = []Key{{Kind: "foreign", Name: "selected", Supported: true, Reference: &parent}}
	if _, err := migrationRepairKey(b, "selected"); err != nil {
		t.Fatal(err)
	}
	b.Facts.Table.Constraints.Items[0].Deferrable = sc.Known(true)
	if _, err := migrationRepairKey(b, "selected"); err == nil {
		t.Fatal("repair erased deferred semantics")
	}
}

func TestMigrationPreviewWireOmitsAbsentConsequencesAndPreservesDisclosures(t *testing.T) {
	s := &MigrationStore{}
	reply, err := s.Preview(context.Background(), migrationTestAdapter(), migrationTestDraft())
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(reply)
	if err != nil {
		t.Fatal(err)
	}
	var wire struct {
		Plan struct {
			Steps []map[string]json.RawMessage `json:"steps"`
		} `json:"plan"`
	}
	if err := json.Unmarshal(raw, &wire); err != nil || len(wire.Plan.Steps) != 2 {
		t.Fatal("preview execution groups were not encoded", err)
	}
	for _, step := range wire.Plan.Steps {
		if _, present := step["consequences"]; present {
			t.Fatal("absent optional consequences must be omitted, not encoded as null")
		}
		for _, key := range []string{"sql", "before", "after", "risks"} {
			var values []json.RawMessage
			if len(step[key]) == 0 || step[key][0] != '[' || json.Unmarshal(step[key], &values) != nil {
				t.Fatalf("required migration array %s was not encoded as an array", key)
			}
		}
	}
	var value any
	if err := json.Unmarshal(raw, &value); err != nil {
		t.Fatal(err)
	}
	var requireNonNull func(any)
	requireNonNull = func(value any) {
		switch value := value.(type) {
		case nil:
			t.Fatal("normal preview emitted explicit null rejected by the paired strict native decoder")
		case map[string]any:
			for _, child := range value {
				requireNonNull(child)
			}
		case []any:
			for _, child := range value {
				requireNonNull(child)
			}
		}
	}
	requireNonNull(value)
	// Actual disclosure content must survive the same optional wire boundary.
	reply.Plan.Steps[0].Consequences = []Consequence{{Kind: "locking", Object: "fixture.a", Message: "Synthetic lock disclosure"}}
	raw, err = json.Marshal(reply)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &wire); err != nil {
		t.Fatal(err)
	}
	var consequences []Consequence
	if json.Unmarshal(wire.Plan.Steps[0]["consequences"], &consequences) != nil || len(consequences) != 1 || consequences[0].Message != "Synthetic lock disclosure" {
		t.Fatal("reviewed consequences were lost at the optional wire boundary")
	}
}
