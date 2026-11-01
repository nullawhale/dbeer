package tableedit

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"strings"
	"testing"
)

func transitionFixture(engine string) Baseline {
	typ := ExpectedNewType(engine, DataType{Kind: "integer"})
	c := sc.Column{Ref: sc.Ref{Kind: "column", Schema: "public", Table: "child", Name: "value"}, Ordinal: sc.Known(0), Type: sc.Known(typ), Nullable: sc.Known(true), Default: sc.Known(sc.Default{Kind: "none"}), Generated: sc.Known(sc.Generated{Kind: "none"}), Identity: sc.Known(sc.Identity{Kind: "none"}), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Visible: sc.Known(true), Comment: sc.Known(""), OnUpdate: sc.Absent[sc.Expression]()}
	b := Baseline{Engine: engine, Target: Target{Schema: "public", Table: "child"}, Scope: "scope", Identity: "identity", Guard: "guard", Fingerprint: Fingerprint("fixture"), Columns: []ObservedColumn{{Name: "value", NativeType: "int", Nullable: true}}, Facts: &Facts{Proof: true, Table: sc.Table{Columns: sc.Complete([]sc.Column{c}), Constraints: sc.Complete[sc.Constraint](nil), Indexes: sc.Complete[sc.Index](nil)}, Dependents: map[string][]string{}}}
	Summarize(&b)
	return b
}
func TestTransitionRejectsConcurrentSignednessAndUnrelatedAttributeChanges(t *testing.T) {
	before := transitionFixture("mysql")
	before.Facts.Table.Columns.Items[0].Type.Value.Modifiers.Value.Unsigned = true
	p := int64(10)
	before.Facts.Table.Columns.Items[0].Type.Value.Modifiers.Value.Precision = &p
	want := DataType{Kind: "bigint"}
	condition := Condition{Operation: Operation{Kind: "changeColumn", Change: &ColumnChange{Name: "value", Type: &want}}}
	after := before
	after.Facts = cloneFacts(before.Facts)
	after.Facts.Table.Columns.Items[0].Type = sc.Known(ExpectedWidenType("mysql", *before.Facts.Table.Columns.Items[0].Type.Value, want))
	matches := func(sc.Column, Default) bool { return true }
	if !VerifyTransition(before, after, condition, matches) {
		t.Fatal("exact unsigned widening rejected")
	}
	after.Facts.Table.Columns.Items[0].Type.Value.Modifiers.Value.Unsigned = false
	if VerifyTransition(before, after, condition, matches) {
		t.Fatal("signedness drift accepted")
	}
	after.Facts = cloneFacts(before.Facts)
	after.Facts.Table.Columns.Items[0].Type = sc.Known(ExpectedWidenType("mysql", *before.Facts.Table.Columns.Items[0].Type.Value, want))
	after.Facts.Table.Columns.Items[0].Comment = sc.Known("unrelated change")
	if VerifyTransition(before, after, condition, matches) {
		t.Fatal("unrelated attributes blessed into intermediate baseline")
	}
}
func TestCompoundDraftValidatesForeignKeyAgainstFinalNullabilityAndType(t *testing.T) {
	for _, pk := range []bool{false, true} {
		source := transitionFixture("postgresql")
		target := transitionFixture("postgresql")
		target.Target.Table = "parent"
		target.Keys = []Key{{Name: "parent_key", Kind: "unique", Columns: []string{"value"}, Supported: true}}
		no := false
		d := Draft{Columns: []Column{}, Keys: []KeyEdit{{Action: "add", Kind: "foreign", Name: "fk", Columns: []string{"value"}, Reference: &target.Target, ReferenceColumns: []string{"value"}, OnUpdate: "NO ACTION", OnDelete: "SET NULL"}}}
		if pk {
			d.Keys = append([]KeyEdit{{Action: "add", Kind: "primary", Name: "pk", Columns: []string{"value"}}}, d.Keys...)
		} else {
			d.Changes = []ColumnChange{{Name: "value", Nullable: &no}}
		}
		if _, _, e := PlanOperations(source, d, "postgresql", func(Target) (Baseline, error) { return target, nil }); e == nil {
			t.Fatal("SET NULL approved against a planned NOT NULL column")
		}
	}
	source := transitionFixture("mysql")
	target := transitionFixture("mysql")
	target.Target.Table = "parent"
	want := DataType{Kind: "bigint"}
	target.Facts.Table.Columns.Items[0].Type = sc.Known(ExpectedWidenType("mysql", *target.Facts.Table.Columns.Items[0].Type.Value, want))
	target.Keys = []Key{{Name: "parent_key", Kind: "unique", Columns: []string{"value"}, Supported: true}}
	d := Draft{Columns: []Column{}, Changes: []ColumnChange{{Name: "value", Type: &want}}, Keys: []KeyEdit{{Action: "add", Kind: "foreign", Name: "fk", Columns: []string{"value"}, Reference: &target.Target, ReferenceColumns: []string{"value"}, OnUpdate: "NO ACTION", OnDelete: "RESTRICT"}}}
	if _, _, e := PlanOperations(source, d, "mysql", func(Target) (Baseline, error) { return target, nil }); e != nil {
		t.Fatal("foreign key did not use the planned widened type")
	}
}

type oversizedObservation struct{ fake }

func (f *oversizedObservation) StructureLoad(ctx context.Context, t Target) (Baseline, error) {
	b, e := f.fake.StructureLoad(ctx, t)
	if f.calls > 0 {
		b.Columns = []ObservedColumn{{Name: "value", NativeType: strings.Repeat("x", 4097)}}
	}
	return b, e
}
func TestOversizedObservationPreservesAcknowledgedDDL(t *testing.T) {
	s := &Store{}
	f := &oversizedObservation{fake: fake{state: "applied"}}
	b, e := s.Load(context.Background(), f, Target{Schema: "public", Table: "samples", Create: true})
	if e != nil {
		t.Fatal(e)
	}
	p, e := s.Preview(f, b.Baseline.ID, Draft{Columns: []Column{{Name: "value", Type: DataType{Kind: "integer"}, Nullable: true, Default: Default{Kind: "none"}}}})
	if e != nil {
		t.Fatal(e)
	}
	r, e := s.Apply(context.Background(), f, Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "apply"})
	if e != nil || r.Outcome.State != "applied" || r.Outcome.Observed != nil || r.Outcome.RefreshError == "" {
		t.Fatal("oversized observation erased acknowledgement or escaped its bound")
	}
}

func TestAddedColumnPreservationRejectsUnexpectedProperties(t *testing.T) {
	before := transitionFixture("mysql")
	newColumn := Column{Name: "added", Type: DataType{Kind: "integer"}, Nullable: true, Default: Default{Kind: "none"}}
	after := PlanningSource(before, Draft{Columns: []Column{newColumn}}, "mysql")
	after.Facts.Table.Columns.Items[1].Ordinal = sc.Known(1)
	condition := Condition{Operation: Operation{Kind: "addColumn", Column: &newColumn}}
	matches := func(sc.Column, Default) bool { return true }
	if !VerifyTransition(before, after, condition, matches) {
		t.Fatal("expected ordinary addition rejected")
	}
	for _, kind := range []string{"comment", "identity", "generated", "visible", "charset"} {
		changed := after
		changed.Facts = cloneFacts(after.Facts)
		c := &changed.Facts.Table.Columns.Items[1]
		switch kind {
		case "comment":
			c.Comment = sc.Known("unexpected")
		case "identity":
			c.Identity = sc.Known(sc.Identity{Kind: "autoIncrement"})
		case "generated":
			c.Generated = sc.Known(sc.Generated{Kind: "stored"})
		case "visible":
			c.Visible = sc.Known(false)
		case "charset":
			c.Charset = sc.Known("unexpected")
		}
		if VerifyTransition(before, changed, condition, matches) {
			t.Fatal("unexpected new-column property became an accepted intermediate baseline")
		}
	}
}
func TestMySQLNullableImplicitNullDefaultCanWiden(t *testing.T) {
	b := transitionFixture("mysql")
	b.Facts.Table.Columns.Items[0].Default = sc.Known(sc.Default{Kind: "sqlNull"})
	want := DataType{Kind: "bigint"}
	if e := CheckChange(b, ColumnChange{Name: "value", Type: &want}); e != nil {
		t.Fatal("nullable no-explicit-default column could not widen")
	}
	b.Facts.Table.Columns.Items[0].Default = sc.Known(sc.Default{Kind: "expression", Expression: &sc.Expression{Text: "synthetic"}})
	if e := CheckChange(b, ColumnChange{Name: "value", Type: &want}); e == nil {
		t.Fatal("expression default permitted unsupported widening")
	}
}
