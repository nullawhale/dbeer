package schemacompare

import (
	"context"
	"reflect"
	"strings"
	"testing"
)

func fixtureDefinition(_ context.Context, c Capture, ref Ref) (Definition, error) {
	if len(c.Tables) == 1 {
		table := c.Tables[0]
		sql := "CREATE TABLE " + ref.Schema + "." + ref.Name + " (\n"
		for _, column := range table.Columns.Items {
			sql += "  " + column.Ref.Name + " text"
			if column.Nullable.Value != nil && !*column.Nullable.Value {
				sql += " NOT NULL"
			}
			if column.Default.Value != nil && column.Default.Value.Expression != nil {
				sql += " DEFAULT " + column.Default.Value.Expression.Text
			}
			sql += "\n"
		}
		return Definition{SQL: sql + ");\n"}, nil
	}
	if len(c.Types) == 1 {
		return Definition{SQL: "CREATE TYPE " + ref.Schema + "." + ref.Name + " AS ();\n"}, nil
	}
	return Definition{SQL: "-- unavailable\n", Limited: true}, nil
}
func TestDefinitionDiffMapsCopyWithoutRewritingExpressions(t *testing.T) {
	a, b := testCapture("a"), testCapture("b")
	a.Tables[0].Columns.Items[0].Default = Known(Default{Kind: "expression", Expression: &Expression{Text: "'a.orders.id'", Dependencies: Complete[Ref](nil)}})
	b.Tables[0].Columns.Items[0].Default = a.Tables[0].Columns.Items[0].Default
	b.Tables[0].Ref.Name = "renamed"
	b.Tables[0].Columns.Items[0].Ref.Table = "renamed"
	b.Tables[0].Columns.Items[0].Ref.Name = "key"
	b.Tables[0].Columns.Items[0].Nullable = Known(true)
	mappings := testMappings()
	mappings.Tables = []TablePair{{Source: QualifiedName{"a", "orders"}, Target: QualifiedName{"b", "renamed"}, Columns: []NamePair{{Source: "id", Target: "key"}}, Constraints: []NamePair{}, Indexes: []NamePair{}}}
	r := buildTest(t, a, b, mappings)
	original := copyDefinition(reflect.ValueOf(r.Report.Source)).Interface().(Capture)
	d, e := r.TextDiff(context.Background(), 0, fixtureDefinition)
	if e != nil || d.Status != "complete" {
		t.Fatal("SQL diff unavailable")
	}
	if d.Lines[0].Kind != "equal" || d.Lines[0].Source.Text != "CREATE TABLE b.renamed (" {
		t.Fatal("mapped identifiers produced false differences")
	}
	if !strings.Contains(d.Lines[1].Source.Text, "key") || !strings.Contains(d.Lines[1].Source.Text, "'a.orders.id'") {
		t.Fatal("typed mapping rewrote or lost an expression")
	}
	if !reflect.DeepEqual(r.Report.Source, original) {
		t.Fatal("definition rendering mutated frozen capture")
	}
}
func TestDefinitionDiffMissingMemberKeepsBothEnclosingDefinitions(t *testing.T) {
	for _, side := range []string{"added", "deleted"} {
		t.Run(side, func(t *testing.T) {
			a, b := testCapture("a"), testCapture("b")
			r := buildTest(t, a, b, testMappings())
			source, target := a.Tables[0].Columns.Items[0].Ref, b.Tables[0].Columns.Items[0].Ref
			difference := Difference{Index: 0, Kind: "changed"}
			if side == "added" {
				difference.TargetRef = &target
			} else {
				difference.SourceRef = &source
			}
			r.Report.Differences = []Difference{difference}
			d, e := r.TextDiff(context.Background(), 0, fixtureDefinition)
			if e != nil || d.Source.Kind != "text" || d.Target.Kind != "text" {
				t.Fatal("missing member hid existing parent table")
			}
			if d.Lines[0].Source == nil || d.Lines[0].Target == nil {
				t.Fatal("parent definition context missing")
			}
		})
	}
	// A genuinely missing whole table must still have an absent side.
	a, b := testCapture("a"), testCapture("b")
	a.Tables = nil
	r := buildTest(t, a, b, testMappings())
	r.Report.Differences = []Difference{{Index: 0, TargetRef: &b.Tables[0].Ref, Kind: "targetOnly"}}
	d, e := r.TextDiff(context.Background(), 0, fixtureDefinition)
	if e != nil || d.Source.Kind != "absent" || d.Target.Kind != "text" {
		t.Fatal("absent table was fabricated")
	}
	r.Report.Differences[0].Kind = "indeterminate"
	d, e = r.TextDiff(context.Background(), 0, fixtureDefinition)
	if e != nil || d.Status != "limited" || d.Source.Kind != "text" || !strings.Contains(d.Lines[0].Source.Text, "unavailable in captured metadata") {
		t.Fatal("unknown missing definition was presented as known absence")
	}
}
func TestDefinitionDiffIncompleteMetadataKeepsPreciseHighlights(t *testing.T) {
	a, b := testCapture("a"), testCapture("b")
	b.Tables[0].Columns.Items[0].Nullable = Known(true)
	r := buildTest(t, a, b, testMappings())
	render := func(ctx context.Context, c Capture, ref Ref) (Definition, error) {
		d, e := fixtureDefinition(ctx, c, ref)
		d.Limited = true
		return d, e
	}
	d, e := r.TextDiff(context.Background(), 0, render)
	if e != nil || d.Status != "limited" || d.Lines[0].Kind != "equal" {
		t.Fatal("incomplete metadata discarded line alignment")
	}
	if len(d.Lines[1].Source.Highlights) != 1 || d.Lines[1].Source.Highlights[0].Start == 0 {
		t.Fatal("incomplete metadata replaced precise word highlights")
	}
}
func TestDefinitionDiffMetadataOnlyAndCompositeAttribute(t *testing.T) {
	a, b := testCapture("a"), testCapture("b")
	a.Tables[0].Columns.Items[0].Comment = Known("before")
	b.Tables[0].Columns.Items[0].Comment = Known("after")
	r := buildTest(t, a, b, testMappings())
	d, e := r.TextDiff(context.Background(), 0, fixtureDefinition)
	if e != nil || d.Status != "limited" {
		t.Fatal("unrepresented metadata implied equal complete SQL")
	}
	found := false
	for _, line := range d.Lines {
		if line.Source != nil && strings.Contains(line.Source.Text, "This property is not represented in SQL") {
			found = true
		}
	}
	if !found {
		t.Fatal("missing metadata explanation")
	}
	ref := Ref{Kind: "type", Schema: "a", Name: "record"}
	capture := Capture{Types: []TypeDefinition{{Ref: ref}}}
	selected, root, ok := definitionRoot(capture, Ref{Kind: "column", Schema: "a", Table: "record", Name: "field"})
	if !ok || root != ref || len(selected.Types) != 1 {
		t.Fatal("composite attribute did not resolve to CREATE TYPE")
	}
}
func TestDefinitionWriterBoundsOutputAndNotes(t *testing.T) {
	w := DefinitionWriter{Context: context.Background()}
	for i := 0; i < 100; i++ {
		w.Note(strings.Repeat("x", 1000) + "\ntext")
	}
	w.Write(strings.Repeat("猫", 100000))
	result, e := w.Finish()
	if e != nil || !result.Limited || len(result.SQL) > 128<<10 || !strings.Contains(result.SQL, "猫") {
		t.Fatal("definition output limit failed")
	}
}
