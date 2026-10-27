package postgres

import (
	"context"
	"strings"
	"testing"

	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/syncplan"
)

func TestSynchronizationPostgresTypedCreatesAndConservativeAlters(t *testing.T) {
	column := definitionColumn(`odd"column`, definitionBuiltin("int4", sc.TypeModifiers{}))
	table := definitionTable(column)
	capture := sc.Capture{Tables: []sc.Table{table}}
	sql, reason, err := RenderSynchronizationSchema(context.Background(), syncplan.SchemaOperation{Action: "create", Ref: table.Ref, Source: capture})
	if err != nil || reason != "" || !strings.Contains(sql, `CREATE TABLE "public"."items"`) || !strings.Contains(sql, `"odd""column" integer`) {
		t.Fatal("typed table create", sql, reason, err)
	}
	changed := column
	changed.Nullable = sc.Known(false)
	desired := definitionTable(changed)
	sql, reason, err = RenderSynchronizationSchema(context.Background(), syncplan.SchemaOperation{Action: "alter", Ref: column.Ref, Source: sc.Capture{Tables: []sc.Table{desired}}, Target: capture})
	if err != nil || reason != "" || !strings.Contains(sql, `ALTER COLUMN "odd""column" SET NOT NULL;`) {
		t.Fatal("nullability alter", sql, reason, err)
	}
	changed.Type = sc.Known(definitionBuiltin("text", sc.TypeModifiers{}))
	desired = definitionTable(changed)
	sql, reason, err = RenderSynchronizationSchema(context.Background(), syncplan.SchemaOperation{Action: "alter", Ref: column.Ref, Source: sc.Capture{Tables: []sc.Table{desired}}, Target: capture})
	if err != nil || reason == "" || sql != "" {
		t.Fatal("unsafe type conversion", sql, reason, err)
	}
	expr := definitionExpression("nextval('private.sequence'::regclass)")
	column.Default = sc.Known(sc.Default{Kind: "expression", Expression: &expr})
	table = definitionTable(column)
	sql, reason, err = RenderSynchronizationSchema(context.Background(), syncplan.SchemaOperation{Action: "create", Ref: table.Ref, Source: sc.Capture{Tables: []sc.Table{table}}})
	if err != nil || reason == "" || sql != "" {
		t.Fatal("expression became executable", sql, reason, err)
	}
}

func TestSynchronizationPostgresFromImmutableComparison(t *testing.T) {
	column := definitionColumn("value", definitionBuiltin("text", sc.TypeModifiers{}))
	table := definitionTable(column)
	pk := sc.NewConstraint(sc.Ref{Kind: "constraint", Schema: table.Ref.Schema, Table: table.Ref.Name, Name: "items_pk"}, "p")
	pk.Columns = sc.Complete([]sc.Ref{column.Ref})
	table.Constraints = sc.Complete([]sc.Constraint{pk})
	collector := sc.NewCollector(context.Background(), sc.DefaultLimits())
	_ = collector.Table(table)
	capture := collector.Capture
	capture.Context = sc.CaptureContext{Engine: "postgresql", Visibility: "complete", EngineContext: sc.Known([]sc.Option{})}
	capture.Inventories = []sc.Inventory{{Schema: "public", Existence: "present", Tables: sc.Complete([]sc.Ref{table.Ref}), Types: sc.Complete[sc.Ref](nil)}}
	target := sc.Capture{Context: capture.Context, Inventories: []sc.Inventory{{Schema: "public", Existence: "present", Tables: sc.Complete[sc.Ref](nil), Types: sc.Complete[sc.Ref](nil)}}}
	result, err := sc.Build(context.Background(), t.TempDir(), capture, target, sc.Mappings{Schemas: []sc.NamePair{{Source: "public", Target: "public"}}, Tables: []sc.TablePair{}, Types: []sc.ObjectPair{}})
	if err != nil {
		t.Fatal(err)
	}
	defer result.Close()
	plan, err := syncplan.Schema(context.Background(), result.Report, RenderSynchronizationSchema)
	if err != nil || len(plan.Steps) != 2 || !plan.Steps[0].Selected || !plan.Steps[1].Selected || !strings.Contains(plan.Steps[0].SQL, "CREATE TABLE") || !strings.Contains(plan.Steps[1].SQL, "PRIMARY KEY") || len(plan.Steps[1].DependsOn) != 1 {
		t.Fatal("table/constraint plan", plan, err)
	}
}

func TestSynchronizationPostgresAppendedColumnsAndIndexDependencies(t *testing.T) {
	initial := definitionColumn("original", definitionBuiltin("int4", sc.TypeModifiers{}))
	initial.Ordinal = sc.Known(0)
	first := definitionColumn("z_first", definitionBuiltin("int4", sc.TypeModifiers{}))
	first.Ordinal = sc.Known(1)
	second := definitionColumn("a_second", definitionBuiltin("int4", sc.TypeModifiers{}))
	second.Ordinal = sc.Known(2)
	before, after := definitionTable(initial), definitionTable(initial, first, second)
	after.Indexes = sc.Complete([]sc.Index{definitionIndex("new_index", definitionIndexKey(second.Ref.Name))})
	captureContext := sc.CaptureContext{Engine: "postgresql", Visibility: "complete", EngineContext: sc.Known([]sc.Option{})}
	capture := func(table sc.Table) sc.Capture {
		c := sc.NewCollector(context.Background(), sc.DefaultLimits())
		if err := c.Table(table); err != nil {
			t.Fatal(err)
		}
		out := c.Capture
		out.Context = captureContext
		out.Inventories = []sc.Inventory{{Schema: "public", Existence: "present", Tables: sc.Complete([]sc.Ref{table.Ref}), Types: sc.Complete[sc.Ref](nil)}}
		return out
	}
	result, err := sc.Build(context.Background(), t.TempDir(), capture(after), capture(before), sc.Mappings{Schemas: []sc.NamePair{{Source: "public", Target: "public"}}, Tables: []sc.TablePair{}, Types: []sc.ObjectPair{}})
	if err != nil {
		t.Fatal(err)
	}
	defer result.Close()
	plan, err := syncplan.Schema(context.Background(), result.Report, RenderSynchronizationSchema)
	if err != nil || len(plan.Steps) != 3 {
		t.Fatal("append plan", err, plan)
	}
	firstID, secondID := "", ""
	for _, step := range plan.Steps {
		if step.Manual || !step.Selected {
			t.Fatal("supported append became manual", step)
		}
		if strings.Contains(step.Title, first.Ref.Name) {
			firstID = step.ID
		}
		if strings.Contains(step.Title, second.Ref.Name) {
			secondID = step.ID
			if len(step.DependsOn) != 1 || step.DependsOn[0] != firstID {
				t.Fatal("second append lacks first prerequisite")
			}
		}
		if strings.Contains(step.Title, "new_index") {
			found := false
			for _, dep := range step.DependsOn {
				if dep == secondID {
					found = true
				}
			}
			if !found {
				t.Fatal("index lacks new column prerequisite")
			}
		}
	}
}

func TestSynchronizationPostgresAppendAllowsIndependentPrefixPropertyChanges(t *testing.T) {
	note := definitionColumn("note", definitionBuiltin("text", sc.TypeModifiers{}))
	note.Ordinal = sc.Known(0)
	changed := note
	changed.Nullable = sc.Known(false)
	revision := definitionColumn("revision", definitionBuiltin("int4", sc.TypeModifiers{}))
	revision.Ordinal = sc.Known(1)
	capture := func(table sc.Table) sc.Capture {
		collector := sc.NewCollector(context.Background(), sc.DefaultLimits())
		if err := collector.Table(table); err != nil {
			t.Fatal(err)
		}
		out := collector.Capture
		out.Context = sc.CaptureContext{Engine: "postgresql", Visibility: "complete", EngineContext: sc.Known([]sc.Option{})}
		out.Inventories = []sc.Inventory{{Schema: "public", Existence: "present", Tables: sc.Complete([]sc.Ref{table.Ref}), Types: sc.Complete[sc.Ref](nil)}}
		return out
	}
	source := capture(definitionTable(changed, revision))
	target := capture(definitionTable(note))
	result, err := sc.Build(context.Background(), t.TempDir(), source, target, sc.Mappings{Schemas: []sc.NamePair{{Source: "public", Target: "public"}}, Tables: []sc.TablePair{}, Types: []sc.ObjectPair{}})
	if err != nil {
		t.Fatal(err)
	}
	defer result.Close()
	plan, err := syncplan.Schema(context.Background(), result.Report, RenderSynchronizationSchema)
	if err != nil || len(plan.Steps) != 2 {
		t.Fatal("independent prefix change prevented append", err)
	}
	addition, alteration := false, false
	for _, step := range plan.Steps {
		if step.Manual || step.SQL == "" {
			t.Fatal("supported prefix change made operation manual")
		}
		if strings.Contains(step.SQL, `ADD COLUMN "revision" integer;`) {
			addition = true
			if !step.Selected || len(step.DependsOn) != 0 {
				t.Fatal("independent append depends on an existing column alteration")
			}
		}
		alteration = alteration || strings.Contains(step.SQL, `ALTER COLUMN "note" SET NOT NULL;`)
	}
	if !addition || !alteration {
		t.Fatal("plan omitted append or separate supported alteration")
	}
	// An actual insertion/reorder still cannot become an ADD-at-end statement.
	reordered := changed
	reordered.Ordinal = sc.Known(1)
	revision.Ordinal = sc.Known(0)
	_, reason, err := RenderSynchronizationSchema(context.Background(), syncplan.SchemaOperation{Action: "create", Ref: revision.Ref, Source: capture(definitionTable(revision, reordered)), Target: target})
	if err != nil || reason == "" {
		t.Fatal("inserted column ordinal became an automatic append")
	}
}
