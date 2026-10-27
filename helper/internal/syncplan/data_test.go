package syncplan

import (
	"context"
	"dbeer/helper/internal/resultcompare"
	tc "dbeer/helper/internal/tablecapture"
	"fmt"
	"strings"
	"testing"
	"unicode/utf8"
)

type dataRows struct {
	columns []resultcompare.Column
	rows    [][]*string
}

func (s *dataRows) Metadata() resultcompare.Metadata {
	return resultcompare.Metadata{Columns: s.columns, RowCount: int64(len(s.rows)), Complete: true}
}
func (s *dataRows) Close() error { return nil }
func (s *dataRows) Scan(ctx context.Context, f func(resultcompare.RowRef, []*string) error) error {
	for i, row := range s.rows {
		if e := ctx.Err(); e != nil {
			return e
		}
		if e := f(resultcompare.RowRef{Index: int64(i)}, row); e != nil {
			return e
		}
	}
	return nil
}
func (s *dataRows) ReadRow(ctx context.Context, r resultcompare.RowRef) ([]*string, error) {
	if e := ctx.Err(); e != nil {
		return nil, e
	}
	if r.Index < 0 || r.Index >= int64(len(s.rows)) {
		return nil, resultcompare.ErrReference
	}
	return s.rows[r.Index], nil
}
func dp(s string) *string { return &s }
func dataFixture(t *testing.T, left, right [][]*string) (DataInput, *resultcompare.Result) {
	t.Helper()
	cols := []resultcompare.Column{{Index: 0, Name: "id", Engine: "postgresql", NativeType: "int8"}, {Index: 1, Name: "value", Engine: "postgresql", NativeType: "text"}}
	r, e := resultcompare.Compare(context.Background(), &dataRows{cols, left}, &dataRows{cols, right}, resultcompare.Options{Mode: "key", Columns: []resultcompare.Mapping{{Left: 0, Right: 0, Key: true}, {Left: 1, Right: 1}}, ScratchDir: t.TempDir()})
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { _ = r.Close() })
	d := tc.Descriptor{Engine: "postgresql", Table: tc.Table{Schema: "public", Name: "fixture"}, Columns: []tc.Column{{Index: 0, Name: "id", NativeType: "int8", PrimaryKey: 1}, {Index: 1, Name: "value", NativeType: "text"}}}
	target := d
	target.Columns = append([]tc.Column{}, d.Columns...)
	out := tc.Outcome{FullOriginals: true, PartialReasons: []string{}}
	return DataInput{Source: DataSide{Descriptor: d, Outcome: out}, Target: DataSide{Descriptor: target, Outcome: out}, Mappings: []tc.Mapping{{Source: "id", Target: "id", Key: true}, {Source: "value", Target: "value"}}, Originals: "allColumns"}, r
}
func TestDataPlanUsesOriginalRowsDirectionAndSafeDefaults(t *testing.T) {
	in, r := dataFixture(t, [][]*string{{dp("1"), dp("source")}, {dp("2"), nil}}, [][]*string{{dp("1"), dp("target")}, {dp("3"), dp("NULL")}})
	ops := []DataOperation{}
	p, e := BuildData(context.Background(), in, r, strings.Repeat("a", 64), func(op DataOperation) (string, error) {
		ops = append(ops, op)
		return strings.ToUpper(op.Kind) + ";", nil
	})
	if e != nil || p.Validate() != nil || len(p.Steps) != 3 {
		t.Fatalf("plan failed: %v", e)
	}
	byKind := map[string]DataOperation{}
	for i, op := range ops {
		byKind[op.Kind] = op
		if p.Steps[i].Selected != (op.Kind == "insert") || p.Steps[i].Destructive != (op.Kind != "insert") {
			t.Fatal("unsafe default")
		}
	}
	if byKind["insert"].Source[1] != nil || *byKind["delete"].Target[1] != "NULL" || *byKind["update"].Source[1] != "source" || *byKind["update"].Target[1] != "target" {
		t.Fatal("source/target or exact originals were lost")
	}
}
func TestDataPlanBlocksPartialMissingOriginalsAndIncompletePK(t *testing.T) {
	for _, test := range []string{"partial", "originals", "key", "type", "unknown"} {
		t.Run(test, func(t *testing.T) {
			in, r := dataFixture(t, [][]*string{{dp("1"), dp("a")}}, [][]*string{{dp("1"), dp("b")}})
			switch test {
			case "partial":
				in.Source.Outcome.PartialReasons = []string{"readLimit"}
			case "originals":
				in.Originals = "selectedColumns"
			case "key":
				in.Target.Descriptor.Columns[1].PrimaryKey = 2
			case "type":
				in.Target.Descriptor.Columns[1].NativeType = "varchar"
			case "unknown":
				in.Target.Descriptor.Columns[1].ValueComparison = "unresolved"
			}
			called := false
			p, e := BuildData(context.Background(), in, r, strings.Repeat("a", 64), func(DataOperation) (string, error) { called = true; return "UPDATE;", nil })
			if e != nil || called || len(p.Steps) != 1 || !p.Steps[0].Manual || p.Steps[0].SQL != "" {
				t.Fatalf("unsafe plan: %v", e)
			}
		})
	}
}
func TestDataPlanBlocksAmbiguousKeysAndNeverPublishesSQLPrefixAtLimit(t *testing.T) {
	in, r := dataFixture(t, [][]*string{{dp("1"), dp("a")}, {dp("1"), dp("b")}}, [][]*string{})
	p, e := BuildData(context.Background(), in, r, strings.Repeat("a", 64), func(DataOperation) (string, error) { t.Fatal("ambiguous key reached renderer"); return "", nil })
	if e != nil || len(p.Steps) != 1 || !p.Steps[0].Manual {
		t.Fatal("ambiguous keys not blocked")
	}
	in, r = dataFixture(t, [][]*string{{dp("1"), dp("a")}, {dp("2"), dp("b")}}, [][]*string{})
	calls := 0
	p, e = BuildData(context.Background(), in, r, strings.Repeat("a", 64), func(DataOperation) (string, error) { calls++; return strings.Repeat("x", MaxBytes/2), nil })
	if e != nil || calls != 2 || len(p.Steps) != 1 || !p.Steps[0].Manual || p.Steps[0].SQL != "" {
		t.Fatal("limited plan published prefix")
	}
}
func TestDataPlanCancellationAndUnsupportedRow(t *testing.T) {
	in, r := dataFixture(t, [][]*string{{dp("1"), dp("a")}}, [][]*string{{dp("1"), dp("b")}})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, e := BuildData(ctx, in, r, strings.Repeat("a", 64), func(DataOperation) (string, error) { return "UPDATE;", nil }); e != context.Canceled {
		t.Fatal("cancel ignored")
	}
	p, e := BuildData(context.Background(), in, r, strings.Repeat("a", 64), func(DataOperation) (string, error) { return "", ErrInvalid })
	if e != nil || !p.Steps[0].Manual || p.Steps[0].Selected || p.Steps[0].Reason == "" {
		t.Fatal("unsupported row silently omitted")
	}
}

func selectiveDataFixture(t *testing.T, sourceColumns, targetColumns []tc.Column, mappings []tc.Mapping, sourceRows, targetRows [][]*string) (DataInput, *resultcompare.Result) {
	t.Helper()
	source := tc.Descriptor{Engine: "postgresql", Table: tc.Table{Schema: "public", Name: "source"}, Columns: sourceColumns}
	target := tc.Descriptor{Engine: "postgresql", Table: tc.Table{Schema: "public", Name: "target"}, Columns: targetColumns}
	metadata := func(columns []tc.Column) []resultcompare.Column {
		out := []resultcompare.Column{}
		for _, c := range columns {
			out = append(out, resultcompare.Column{Index: c.Index, Name: c.Name, Engine: "postgresql", NativeType: c.NativeType, Encoding: c.Encoding, TypeIdentity: "capture-v1:" + c.NativeType})
		}
		return out
	}
	columns := []resultcompare.Mapping{}
	for _, m := range mappings {
		x, y := -1, -1
		for i, c := range sourceColumns {
			if c.Name == m.Source {
				x = i
			}
		}
		for i, c := range targetColumns {
			if c.Name == m.Target {
				y = i
			}
		}
		columns = append(columns, resultcompare.Mapping{Left: x, Right: y, Key: m.Key})
	}
	r, e := resultcompare.Compare(context.Background(), &dataRows{metadata(sourceColumns), sourceRows}, &dataRows{metadata(targetColumns), targetRows}, resultcompare.Options{Mode: "key", Columns: columns, ScratchDir: t.TempDir()})
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { _ = r.Close() })
	out := tc.Outcome{FullOriginals: true, PartialReasons: []string{}}
	return DataInput{Source: DataSide{Descriptor: source, Outcome: out}, Target: DataSide{Descriptor: target, Outcome: out}, Mappings: mappings, Originals: "allColumns"}, r
}

func TestDataPlanSupportsExplicitNamesAndExcludedOriginalColumns(t *testing.T) {
	for _, scenario := range []string{"sourceExcluded", "targetExcluded", "renamed"} {
		t.Run(scenario, func(t *testing.T) {
			a := []tc.Column{{Index: 0, Name: "id", NativeType: "int8", PrimaryKey: 1}, {Index: 1, Name: "value", NativeType: "text"}}
			b := append([]tc.Column{}, a...)
			left, right := [][]*string{{dp("1"), dp("new")}}, [][]*string{{dp("1"), dp("old")}}
			mappings := []tc.Mapping{{Source: "id", Target: "id", Key: true}, {Source: "value", Target: "value"}}
			switch scenario {
			case "sourceExcluded":
				a = append(a, tc.Column{Index: 2, Name: "revision", NativeType: "int8"})
				left[0] = append(left[0], dp("7"))
				left = append(left, []*string{dp("2"), dp("insert"), dp("8")})
			case "targetExcluded":
				b = append(b, tc.Column{Index: 2, Name: "preserved", NativeType: "text"})
				right[0] = append(right[0], dp("full target original"))
			case "renamed":
				a[0].Name = "source_key"
				a[1].Name = "source_value"
				b[0].Name = "target_key"
				b[1].Name = "target_value"
				mappings = []tc.Mapping{{Source: "source_key", Target: "target_key", Key: true}, {Source: "source_value", Target: "target_value"}}
			}
			in, r := selectiveDataFixture(t, a, b, mappings, left, right)
			if r.Summary().SchemaDifferenceCount == 0 {
				t.Fatal("fixture must contain explicit schema differences")
			}
			calls := 0
			p, e := BuildData(context.Background(), in, r, strings.Repeat("a", 64), func(op DataOperation) (string, error) {
				calls++
				if op.Kind == "update" && scenario == "targetExcluded" && (len(op.Target) != 3 || *op.Target[2] != "full target original") {
					t.Fatal("excluded original missing from stale guard input")
				}
				if op.Kind == "insert" && (scenario != "sourceExcluded" || len(op.Source) != 3 || len(op.Descriptor.Columns) != 2) {
					t.Fatal("excluded source columns changed insert mapping")
				}
				return "SELECT 'reviewed draft';", nil
			})
			if e != nil || calls != len(p.Steps) || calls == 0 {
				t.Fatalf("selective plan rejected: %v", e)
			}
			hasExclusionWarning := false
			for _, warning := range p.Warnings {
				if strings.Contains(warning, "Only explicitly mapped columns are synchronized.") && strings.Contains(warning, "original-value guards") && strings.Contains(warning, "INSERT requires complete supported target values") {
					hasExclusionWarning = true
				}
			}
			if hasExclusionWarning != (scenario != "renamed") {
				t.Fatal("selective column scope was not disclosed accurately")
			}
			for _, step := range p.Steps {
				if step.Manual {
					t.Fatal("explicit mapping became unsupported")
				}
			}
		})
	}
}

func TestDataPlanKeepsUnmappedInsertColumnsManual(t *testing.T) {
	a := []tc.Column{{Index: 0, Name: "id", NativeType: "int8", PrimaryKey: 1}, {Index: 1, Name: "value", NativeType: "text"}}
	b := append(append([]tc.Column{}, a...), tc.Column{Index: 2, Name: "required_original", NativeType: "text"})
	in, r := selectiveDataFixture(t, a, b, []tc.Mapping{{Source: "id", Target: "id", Key: true}, {Source: "value", Target: "value"}}, [][]*string{{dp("2"), dp("insert")}}, [][]*string{})
	p, e := BuildData(context.Background(), in, r, strings.Repeat("a", 64), func(DataOperation) (string, error) {
		t.Fatal("missing target insert column reached SQL renderer")
		return "", nil
	})
	if e != nil || len(p.Steps) != 1 || !p.Steps[0].Manual || p.Steps[0].SQL != "" {
		t.Fatal("unmapped target insert values were invented")
	}
}

func TestDataPlanChecksMappedIdentitiesBeyondTruncatedSchemaExamples(t *testing.T) {
	for _, mismatch := range []bool{false, true} {
		a := []resultcompare.Column{{Index: 0, Name: "id", Engine: "postgresql", NativeType: "int8", TypeIdentity: "capture-v1:int8"}}
		ac := []tc.Column{{Index: 0, Name: "id", NativeType: "int8", PrimaryKey: 1}}
		left := []*string{dp("1")}
		for i := 0; i < 70; i++ {
			name := fmt.Sprintf("excluded_%d", i)
			a = append(a, resultcompare.Column{Index: i + 1, Name: name, Engine: "postgresql", NativeType: "text", TypeIdentity: "capture-v1:text"})
			ac = append(ac, tc.Column{Index: i + 1, Name: name, NativeType: "text"})
			left = append(left, dp("excluded"))
		}
		a = append(a, resultcompare.Column{Index: 71, Name: "value", Engine: "postgresql", NativeType: "text", TypeIdentity: "capture-v1:text"})
		ac = append(ac, tc.Column{Index: 71, Name: "value", NativeType: "text"})
		left = append(left, dp("new"))
		b := []resultcompare.Column{{Index: 0, Name: "id", Engine: "postgresql", NativeType: "int8", TypeIdentity: "capture-v1:int8"}, {Index: 1, Name: "value", Engine: "postgresql", NativeType: "text", TypeIdentity: "capture-v1:text"}}
		if mismatch {
			b[1].TypeIdentity = "capture-v1:different-definition"
		}
		r, e := resultcompare.Compare(context.Background(), &dataRows{a, [][]*string{left}}, &dataRows{b, [][]*string{{dp("1"), dp("old")}}}, resultcompare.Options{Mode: "key", Columns: []resultcompare.Mapping{{Left: 0, Right: 0, Key: true}, {Left: 71, Right: 1}}, ScratchDir: t.TempDir()})
		if e != nil {
			t.Fatal(e)
		}
		defer r.Close()
		if !r.Summary().SchemaDifferencesTruncated {
			t.Fatal("schema examples were not truncated")
		}
		out := tc.Outcome{FullOriginals: true, PartialReasons: []string{}}
		in := DataInput{Source: DataSide{Descriptor: tc.Descriptor{Engine: "postgresql", Table: tc.Table{Schema: "public", Name: "source"}, Columns: ac}, Outcome: out}, Target: DataSide{Descriptor: tc.Descriptor{Engine: "postgresql", Table: tc.Table{Schema: "public", Name: "target"}, Columns: []tc.Column{{Index: 0, Name: "id", NativeType: "int8", PrimaryKey: 1}, {Index: 1, Name: "value", NativeType: "text"}}}, Outcome: out}, Mappings: []tc.Mapping{{Source: "id", Target: "id", Key: true}, {Source: "value", Target: "value"}}, Originals: "allColumns"}
		called := false
		p, e := BuildData(context.Background(), in, r, strings.Repeat("a", 64), func(DataOperation) (string, error) { called = true; return "UPDATE;", nil })
		if e != nil || len(p.Steps) != 1 || called == mismatch || p.Steps[0].Manual != mismatch {
			t.Fatal("bounded schema examples hid mapped identity compatibility")
		}
	}
}

func TestDataPlanTitlesDistinguishSameActionRowsWithoutChangingSQL(t *testing.T) {
	in, result := dataFixture(t, [][]*string{{dp("9007199254740993"), dp("source one")}, {dp("9007199254740995"), dp("source two")}}, [][]*string{{dp("9007199254740993"), dp("target one")}, {dp("9007199254740995"), dp("target two")}})
	rendered := []string{}
	plan, err := BuildData(context.Background(), in, result, strings.Repeat("a", 64), func(op DataOperation) (string, error) {
		sql := "UPDATE target SET value='source' WHERE id=" + *op.Target[0] + ";"
		rendered = append(rendered, sql)
		return sql, nil
	})
	if err != nil || len(plan.Steps) != 2 {
		t.Fatal("data title fixture unavailable", err)
	}
	seen := map[string]bool{}
	for i, step := range plan.Steps {
		if seen[step.Title] || !strings.Contains(step.Title, "UPDATE target row public.fixture [id=\"") || (!strings.Contains(step.Title, "9007199254740993") && !strings.Contains(step.Title, "9007199254740995")) || step.SQL != rendered[i] {
			t.Fatal("same-action row title lost exact key or changed SQL")
		}
		seen[step.Title] = true
	}
}

func TestDataStepTitleUsesMappedSourceInsertAndTargetOriginalCompositeKey(t *testing.T) {
	descriptor := tc.Descriptor{Table: tc.Table{Schema: "target", Name: "rows"}, Columns: []tc.Column{{Index: 0, Name: "tenant", PrimaryKey: 2}, {Index: 1, Name: "id", PrimaryKey: 1}, {Index: 2, Name: "value"}}}
	op := DataOperation{Kind: "insert", Descriptor: descriptor, Mappings: []DataMapping{{SourceIndex: 1, TargetIndex: 0, Key: true}, {SourceIndex: 0, TargetIndex: 1, Key: true}, {SourceIndex: 2, TargetIndex: 2}}, Source: []*string{dp("9007199254740993"), dp("source tenant"), dp("source value")}, Target: []*string{dp("target tenant"), dp("9007199254740995"), dp("target value")}}
	title := dataStepTitle(op)
	if !strings.Contains(title, `[id="9007199254740993", tenant="source tenant"]`) || strings.Contains(title, "source value") || strings.Contains(title, "target tenant") {
		t.Fatal("insert title did not use mapped source keys")
	}
	for _, action := range []string{"update", "delete"} {
		op.Kind = action
		title = dataStepTitle(op)
		if !strings.Contains(title, `[id="9007199254740995", tenant="target tenant"]`) || strings.Contains(title, "source tenant") || strings.Contains(title, "target value") {
			t.Fatal("update/delete title did not use target original keys")
		}
	}
}

func TestDataStepTitleBinaryLongUnicodeCompositeKeysRemainBounded(t *testing.T) {
	descriptor := tc.Descriptor{Table: tc.Table{Schema: "public", Name: "rows"}, Columns: []tc.Column{{Index: 0, Name: "binary_key", Encoding: "base64", PrimaryKey: 1}, {Index: 1, Name: "unicode_key", PrimaryKey: 2}}}
	op := DataOperation{Kind: "delete", Descriptor: descriptor, Mappings: []DataMapping{{SourceIndex: 0, TargetIndex: 0, Key: true}, {SourceIndex: 1, TargetIndex: 1, Key: true}}, Target: []*string{dp("AAECA/8="), dp(strings.Repeat("界🍺", 10000))}}
	title := dataStepTitle(op)
	if len(title) > 4096 || !utf8.ValidString(title) || !strings.Contains(title, `binary_key=base64("AAECA/8=")`) || !strings.Contains(title, "unicode_key=") || !strings.Contains(title, "…") {
		t.Fatal("binary/composite title lost identity or bounds")
	}
	op.Target[1] = dp("NULL\n\x00tail")
	title = dataStepTitle(op)
	if strings.ContainsRune(title, 0) || strings.ContainsRune(title, '\n') || !strings.Contains(title, `unicode_key="NULL\n\x00tail"`) {
		t.Fatal("title failed to escape exact text value")
	}
}
