package tableedit

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"strings"
	"testing"
)

func TestDestructiveVersionAndExclusiveIntent(t *testing.T) {
	no := false
	expr := "value::pg_catalog.int4"
	charset := "utf8mb4"
	typ := DataType{Kind: "integer"}
	for _, change := range []ColumnChange{{Name: "value", Drop: true}, {Name: "value", Type: &typ, UsingExpression: &expr}, {Name: "value", Unsigned: &no}, {Name: "value", Charset: &charset, Collation: &TypeReference{Name: "utf8mb4_bin"}}} {
		d := Draft{AuthoringVersion: 4, Columns: []Column{}, Changes: []ColumnChange{change}, AllowDestructive: true}
		if !d.Valid() || !d.Destructive() {
			t.Fatal("valid destructive intent rejected")
		}
		d.AuthoringVersion = 3
		if d.Valid() {
			t.Fatal("destructive intent admitted without version4")
		}
		d.AuthoringVersion = 4
		d.AllowDestructive = false
		if d.Valid() {
			t.Fatal("removal permission omitted")
		}
	}
	d := Draft{AuthoringVersion: 4, DropTable: true, Columns: []Column{}, AllowDestructive: true}
	if !d.Valid() {
		t.Fatal("table drop rejected")
	}
	d.RenameTable = &charset
	if d.Valid() {
		t.Fatal("drop mixed with rename")
	}
	for _, change := range []ColumnChange{{Name: "value", Drop: true, Type: &typ}, {Name: "value", UsingExpression: &expr}, {Name: "value", Unsigned: &no, RenameTo: &charset}, {Name: "value", Charset: &charset, Collation: &TypeReference{Name: ""}}} {
		if (Draft{AuthoringVersion: 4, Columns: []Column{}, Changes: []ColumnChange{change}, AllowDestructive: true}).Valid() {
			t.Fatal("mixed or incomplete intent admitted")
		}
	}
}
func TestConversionDependenciesAndNarrowingVersion(t *testing.T) {
	b := transitionFixture("postgresql")
	b.Attributes = map[string]map[string]any{"value": {"atttypid": "23", "attstorage": "p", "attcompression": ""}}
	b.Facts.TypeStorage = map[string]string{"integer": "p", "numeric": "m"}
	want := DataType{Kind: "numeric", Precision: 5, Scale: 2}
	change := ColumnChange{Name: "value", Type: &want}
	d := Draft{AuthoringVersion: 4, Columns: []Column{}, Changes: []ColumnChange{change}, AllowDestructive: true}
	if _, _, err := PlanOperations(b, d, b.Engine, nil); err != nil {
		t.Fatal(err)
	}
	d.AuthoringVersion = 3
	if _, _, err := PlanOperations(b, d, b.Engine, nil); err == nil {
		t.Fatal("legacy narrowing admitted")
	}
	d.AuthoringVersion = 4
	b.Facts.Dependents["value"] = []string{"view public.affected"}
	if _, _, err := PlanOperations(b, d, b.Engine, nil); err == nil || !strings.Contains(err.Error(), "public.affected") {
		t.Fatal("named dependency not reviewed")
	}
	b = transitionFixture("postgresql")
	b.Facts.Incoming = []Incoming{{Schema: "public", Table: "parent", Name: "incoming_fk", Columns: []string{"value"}}}
	if CheckConversion(b, change) == nil {
		t.Fatal("incoming reference admitted")
	}
}
func TestDropColumnAndTableDependencyProof(t *testing.T) {
	b := transitionFixture("postgresql")
	extra := b.Facts.Table.Columns.Items[0]
	extra.Ref.Name = "retained"
	b.Facts.Table.Columns.Items = append(b.Facts.Table.Columns.Items, extra)
	b.Columns = append(b.Columns, ObservedColumn{Name: "retained", NativeType: "int"})
	d := Draft{AuthoringVersion: 4, Columns: []Column{}, Changes: []ColumnChange{{Name: "value", Drop: true}}, AllowDestructive: true}
	if CheckDropColumn(b, d, "value") != nil {
		t.Fatal("independent drop rejected")
	}
	b.Indexes = []Index{{Name: "by_value", Columns: []string{"value"}, Supported: true}}
	if CheckDropColumn(b, d, "value") == nil {
		t.Fatal("implicit index loss admitted")
	}
	d.Indexes = []IndexEdit{{Action: "drop", Name: "by_value"}}
	if CheckDropColumn(b, d, "value") != nil {
		t.Fatal("explicit removal prerequisite rejected")
	}
	b.Facts.Proof = false
	if CheckDropTable(b) == nil {
		t.Fatal("incomplete drop proof admitted")
	}
	b.Facts.Proof = true
	b.Facts.Incoming = []Incoming{{Schema: "public", Table: "external_child", Name: "fk", Columns: []string{"value"}}}
	if CheckDropTable(b) == nil {
		t.Fatal("incoming FK drop admitted")
	}
}

type validationFake struct {
	fake
	reads int
	bad   bool
}

func (f *validationFake) StructurePrepare(_ context.Context, _ Baseline, d Draft) (Prepared, error) {
	sql := "SELECT count(*) FROM synthetic WHERE value < 0"
	return Prepared{SQL: []string{"synthetic DDL"}, Risks: []string{}, DroppedTarget: d.DropTable, ValidationChecks: []ValidationCheck{{ID: "range", Summary: "Count out-of-range values", SQL: &sql, Risks: []string{"Scans stored values after separate authorization."}}}}, nil
}
func (f *validationFake) StructureApplySteps(ctx context.Context, b Baseline, p Plan) []Execution {
	return []Execution{f.StructureApply(ctx, b, p.SQL)}
}
func (f *validationFake) StructureValidate(context.Context, Baseline, Plan) []ValidationResult {
	f.reads++
	count := "0"
	id := "range"
	if f.bad {
		id = "different"
	}
	return []ValidationResult{{ID: id, State: "passed", InvalidRows: &count}}
}
func TestSeparateValidationRetainsExactPlanAndNeverAuthorizesReplay(t *testing.T) {
	s := &Store{}
	f := &validationFake{fake: fake{state: "unknown"}}
	b, err := s.Load(context.Background(), f, Target{Schema: "fixture", Table: "sample"})
	if err != nil {
		t.Fatal(err)
	}
	p, err := s.Preview(f, b.Baseline.ID, Draft{AuthoringVersion: 4, DropTable: true, Columns: []Column{}, AllowDestructive: true})
	if err != nil || f.reads != 0 {
		t.Fatal("preview evaluated data")
	}
	request := Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "validation"}
	changed := request
	changed.Digest = Fingerprint("other")
	if _, err = s.Validate(context.Background(), f, changed); err == nil || f.reads != 0 {
		t.Fatal("changed exact plan validated")
	}
	r, err := s.Validate(context.Background(), f, request)
	if err != nil || r.Validation.State != "completed" || f.reads != 1 || f.calls != 0 {
		t.Fatal("validation did not retain read-only evidence")
	}
	if _, err = s.Resolve(request); err != nil {
		t.Fatal("validation consumed apply plan")
	}
	request.ExecutionID = "apply"
	r, err = s.Apply(context.Background(), f, request)
	if err != nil || r.Outcome.State != "outcomeUnknown" || r.Outcome.DroppedTarget {
		t.Fatal("unknown drop acknowledgement overstated")
	}
	if _, err = s.Apply(context.Background(), f, request); err == nil || f.calls != 1 {
		t.Fatal("unknown drop replayed")
	}
}
func TestValidationCancellationAndMalformedCountAreBounded(t *testing.T) {
	s := &Store{}
	f := &validationFake{bad: true}
	b, _ := s.Load(context.Background(), f, Target{Schema: "fixture", Table: "sample"})
	p, err := s.Preview(f, b.Baseline.ID, Draft{AuthoringVersion: 4, DropTable: true, Columns: []Column{}, AllowDestructive: true})
	if err != nil {
		t.Fatal(err)
	}
	a := Apply{PlanID: p.Plan.ID, Digest: p.Plan.Digest, ExecutionID: "validate"}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	r, err := s.Validate(ctx, f, a)
	if err != nil || r.Validation.State != "cancelled" || f.reads != 0 {
		t.Fatal("cancelled validation executed")
	}
	r, err = s.Validate(context.Background(), f, a)
	if err != nil || r.Validation.State != "failed" || r.Validation.Checks[0].ID != "range" {
		t.Fatal("malformed validation evidence admitted")
	}
}
func TestConversionAndDropTransitionPreserveUntouchedProperties(t *testing.T) {
	before := transitionFixture("mysql")
	want := DataType{Kind: "numeric", Precision: 8, Scale: 3}
	unsigned := true
	change := ColumnChange{Name: "value", Type: &want, Unsigned: &unsigned}
	after := before
	after.Facts = cloneFacts(before.Facts)
	after.Facts.Table.Columns.Items[0].Type = sc.Known(ExpectedChangedType("mysql", *before.Facts.Table.Columns.Items[0].Type.Value, change))
	c := Condition{Operation: Operation{Kind: "changeColumn", Change: &change}}
	match := func(sc.Column, Default) bool { return true }
	if !VerifyTransition(before, after, c, match) {
		t.Fatal("exact conversion transition rejected")
	}
	after.Facts.Table.Columns.Items[0].Comment = sc.Known("unreviewed")
	if VerifyTransition(before, after, c, match) {
		t.Fatal("unrelated property drift admitted")
	}
}
