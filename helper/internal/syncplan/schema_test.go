package syncplan

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"unicode/utf8"

	sc "dbeer/helper/internal/schemacompare"
)

func schemaFixture(engine string) sc.Report {
	return sc.Report{Summary: sc.Summary{Engine: engine, ModelDigest: strings.Repeat("a", 64), Mappings: sc.Mappings{Schemas: []sc.NamePair{{Source: "src", Target: "dst"}}, Tables: []sc.TablePair{}, Types: []sc.ObjectPair{}}}, Source: sc.Capture{}, Target: sc.Capture{}}
}
func testSchemaRender(_ context.Context, op SchemaOperation) (string, string, error) {
	return "CREATE " + op.Ref.Kind + " " + op.Ref.Name + ";", "", nil
}

func TestSchemaTypedMappingAndImmutableExpression(t *testing.T) {
	report := schemaFixture("postgresql")
	ref := sc.Ref{Kind: "column", Schema: "src", Table: "items", Name: "old"}
	report.Summary.Mappings.Tables = []sc.TablePair{{Source: sc.QualifiedName{Schema: "src", Name: "items"}, Target: sc.QualifiedName{Schema: "dst", Name: "renamed"}, Columns: []sc.NamePair{{Source: "old", Target: "new"}}, Constraints: []sc.NamePair{}, Indexes: []sc.NamePair{}}}
	expression := "src.items.old + 'src.items.old'"
	report.Source.Tables = []sc.Table{{Ref: sc.Ref{Kind: "table", Schema: "src", Name: "items"}, Columns: sc.Complete([]sc.Column{{Ref: ref, Default: sc.Known(sc.Default{Kind: "expression", Expression: &sc.Expression{Text: expression, Dependencies: sc.Complete([]sc.Ref{ref})}})}}), Dependencies: sc.Complete[sc.Dependency](nil)}}
	report.Differences = []sc.Difference{{SourceRef: &ref, Kind: "sourceOnly", Property: "tables.columns"}}
	original := report.Source.Tables[0].Columns.Items[0]
	plan, err := Schema(context.Background(), report, func(_ context.Context, op SchemaOperation) (string, string, error) {
		if op.Ref.Name != "new" || op.Ref.Table != "renamed" || op.Ref.Schema != "dst" {
			t.Fatal("typed reference not mapped")
		}
		col, _ := SchemaColumn(op.Source, op.Ref)
		if col.Default.Value.Expression.Text != expression || col.Default.Value.Expression.Dependencies.Items[0] != op.Ref {
			t.Fatal("expression text rewritten or typed dependency lost")
		}
		return "", "Expression review required.", nil
	})
	if err != nil || len(plan.Steps) != 1 || !plan.Steps[0].Manual || !reflect.DeepEqual(original, report.Source.Tables[0].Columns.Items[0]) {
		t.Fatal("mapping mutated capture or lost manual work", err)
	}
}

func TestSchemaCreationUnitsAndForeignKeyOrder(t *testing.T) {
	report := schemaFixture("postgresql")
	parent := sc.Ref{Kind: "table", Schema: "src", Name: "z_parent"}
	child := sc.Ref{Kind: "table", Schema: "src", Name: "a_child"}
	pkRef := sc.Ref{Kind: "constraint", Schema: "src", Table: parent.Name, Name: "parent_pk"}
	fkRef := sc.Ref{Kind: "constraint", Schema: "src", Table: child.Name, Name: "child_fk"}
	pk := sc.NewConstraint(pkRef, "p")
	fk := sc.NewConstraint(fkRef, "f")
	fk.Target = sc.Known(parent)
	indexRef := sc.Ref{Kind: "index", Schema: "src", Table: parent.Name, Name: "parent_pk_index"}
	pk.BackingIndex = sc.Known(indexRef)
	report.Source.Tables = []sc.Table{
		{Ref: child, Constraints: sc.Complete([]sc.Constraint{fk}), Indexes: sc.Complete[sc.Index](nil), Dependencies: sc.Complete([]sc.Dependency{{From: child, To: fkRef, State: "observed"}, {From: fkRef, To: parent, State: "observed"}})},
		{Ref: parent, Constraints: sc.Complete([]sc.Constraint{pk}), Indexes: sc.Complete([]sc.Index{{Ref: indexRef, Constraint: sc.Known(pkRef)}}), Dependencies: sc.Complete([]sc.Dependency{{From: parent, To: pkRef, State: "observed"}, {From: pkRef, To: indexRef, State: "observed"}})},
	}
	report.Differences = []sc.Difference{{SourceRef: &child, Kind: "sourceOnly"}, {SourceRef: &parent, Kind: "sourceOnly"}}
	plan, err := Schema(context.Background(), report, testSchemaRender)
	if err != nil || len(plan.Steps) != 4 {
		t.Fatal("creation units/cycle", err, plan)
	}
	pkID := ""
	fkIndex := -1
	for i, s := range plan.Steps {
		if s.Manual || !s.Selected {
			t.Fatal("supported dependency made manual", s)
		}
		if strings.Contains(s.Title, "parent_pk") {
			pkID = s.ID
		}
		if strings.Contains(s.Title, "child_fk") {
			fkIndex = i
		}
	}
	if pkID == "" || fkIndex < 0 {
		t.Fatal("constraints missing")
	}
	found := false
	for _, dep := range plan.Steps[fkIndex].DependsOn {
		if dep == pkID {
			found = true
		}
	}
	if !found {
		t.Fatal("foreign key does not depend on referenced key")
	}
}

func TestSchemaMySQLOrdinalDependenciesAndManualPropagation(t *testing.T) {
	report := schemaFixture("mysql")
	table := sc.Ref{Kind: "table", Schema: "src", Name: "items"}
	a := sc.Ref{Kind: "column", Schema: "src", Table: table.Name, Name: "z_first"}
	b := sc.Ref{Kind: "column", Schema: "src", Table: table.Name, Name: "a_second"}
	report.Source.Tables = []sc.Table{{Ref: table, Columns: sc.Complete([]sc.Column{{Ref: a, Ordinal: sc.Known(0)}, {Ref: b, Ordinal: sc.Known(1)}}), Dependencies: sc.Complete[sc.Dependency](nil)}}
	report.Differences = []sc.Difference{{SourceRef: &b, Kind: "sourceOnly"}, {SourceRef: &a, Kind: "sourceOnly"}}
	plan, err := Schema(context.Background(), report, func(ctx context.Context, op SchemaOperation) (string, string, error) {
		if op.Ref.Name == a.Name {
			return "", "Unsupported first column.", nil
		}
		return testSchemaRender(ctx, op)
	})
	if err != nil || len(plan.Steps) != 2 || !plan.Steps[0].Manual || !plan.Steps[1].Manual || len(plan.Steps[1].DependsOn) != 1 || plan.Steps[1].DependsOn[0] != plan.Steps[0].ID {
		t.Fatal("ordinal closure lost", err, plan)
	}
}

func TestSchemaExistingPrecedingColumnDoesNotRequireItsManualAlteration(t *testing.T) {
	report := schemaFixture("mysql")
	table := sc.Ref{Kind: "table", Schema: "src", Name: "items"}
	existing := sc.Ref{Kind: "column", Schema: "src", Table: table.Name, Name: "existing"}
	added := sc.Ref{Kind: "column", Schema: "src", Table: table.Name, Name: "added"}
	targetExisting := mappedRef(existing, report.Summary.Mappings)
	report.Source.Tables = []sc.Table{{Ref: table, Columns: sc.Complete([]sc.Column{{Ref: existing, Ordinal: sc.Known(0)}, {Ref: added, Ordinal: sc.Known(1)}}), Dependencies: sc.Complete[sc.Dependency](nil)}}
	report.Target.Tables = []sc.Table{{Ref: mappedRef(table, report.Summary.Mappings), Columns: sc.Complete([]sc.Column{{Ref: targetExisting, Ordinal: sc.Known(0)}}), Dependencies: sc.Complete[sc.Dependency](nil)}}
	report.Differences = []sc.Difference{{SourceRef: &existing, TargetRef: &targetExisting, Kind: "changed"}, {SourceRef: &added, Kind: "sourceOnly"}}
	plan, err := Schema(context.Background(), report, func(ctx context.Context, op SchemaOperation) (string, string, error) {
		if op.Ref.Name == existing.Name {
			return "", "Independent alteration requires manual SQL.", nil
		}
		return testSchemaRender(ctx, op)
	})
	if err != nil || len(plan.Steps) != 2 {
		t.Fatal("independent ordinal fixture unavailable", err)
	}
	found := false
	for _, step := range plan.Steps {
		if strings.Contains(step.Title, ".added") {
			found = true
			if step.Manual || !step.Selected || len(step.DependsOn) != 0 {
				t.Fatal("addition incorrectly depends on existing-column alteration")
			}
		}
	}
	if !found {
		t.Fatal("independent addition missing")
	}
}

func TestSchemaLimitsCancellationAndConservativeRemoval(t *testing.T) {
	report := schemaFixture("postgresql")
	ref := sc.Ref{Kind: "table", Schema: "dst", Name: "removed"}
	report.Differences = []sc.Difference{{TargetRef: &ref, Kind: "targetOnly"}}
	plan, err := Schema(context.Background(), report, testSchemaRender)
	if err != nil || !plan.Steps[0].Manual || !plan.Steps[0].Destructive || plan.Steps[0].Selected {
		t.Fatal("unsafe removal", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err = Schema(ctx, report, testSchemaRender); !errors.Is(err, context.Canceled) {
		t.Fatal("cancel ignored", err)
	}
	report.Differences = nil
	for i := 0; i <= MaxSteps; i++ {
		r := sc.Ref{Kind: "table", Schema: "src", Name: fmt.Sprint(i)}
		report.Differences = append(report.Differences, sc.Difference{SourceRef: &r, Kind: "sourceOnly"})
	}
	if _, err = Schema(context.Background(), report, testSchemaRender); !errors.Is(err, ErrLimit) {
		t.Fatal("step limit ignored", err)
	}
}

func TestSchemaManualExistingTypeAndExternalDependencyBlockAutomaticSQL(t *testing.T) {
	for _, external := range []bool{false, true} {
		report := schemaFixture("postgresql")
		table := sc.Ref{Kind: "table", Schema: "src", Name: "items"}
		column := sc.Ref{Kind: "column", Schema: "src", Table: table.Name, Name: "new"}
		dependency := sc.Ref{Kind: "type", Schema: "src", Name: "mood"}
		if external {
			dependency = sc.Ref{Kind: "collation", Schema: "src", Name: "custom_collation"}
		}
		report.Source.Tables = []sc.Table{{Ref: table, Columns: sc.Complete([]sc.Column{{Ref: column}}), Dependencies: sc.Complete([]sc.Dependency{{From: column, To: dependency, State: "observed"}})}}
		report.Differences = []sc.Difference{{SourceRef: &column, Kind: "sourceOnly"}}
		if !external {
			targetType := mappedRef(dependency, report.Summary.Mappings)
			report.Differences = append(report.Differences, sc.Difference{SourceRef: &dependency, TargetRef: &targetType, Kind: "changed"})
		}
		plan, err := Schema(context.Background(), report, func(ctx context.Context, op SchemaOperation) (string, string, error) {
			if op.Ref.Kind == "type" {
				return "", "Enum modification requires manual work.", nil
			}
			return testSchemaRender(ctx, op)
		})
		if err != nil {
			t.Fatal(err)
		}
		for _, step := range plan.Steps {
			if !step.Manual || step.Selected || step.SQL != "" {
				t.Fatalf("unavailable dependency became automatic: external=%v step=%+v", external, step)
			}
		}
	}
}

func TestSchemaMemberTitlesIdentifyOwningTablesAndBoundUnicode(t *testing.T) {
	report := schemaFixture("postgresql")
	first := sc.Ref{Kind: "column", Schema: "src", Table: "orders", Name: "id"}
	second := sc.Ref{Kind: "column", Schema: "src", Table: "users", Name: "id"}
	report.Differences = []sc.Difference{{SourceRef: &first, Kind: "sourceOnly"}, {SourceRef: &second, Kind: "sourceOnly"}}
	plan, err := Schema(context.Background(), report, testSchemaRender)
	if err != nil || len(plan.Steps) != 2 {
		t.Fatal("member plan unavailable", err)
	}
	titles := map[string]bool{}
	for _, step := range plan.Steps {
		titles[step.Title] = true
	}
	if !titles["Create column dst.orders.id"] || !titles["Create column dst.users.id"] {
		t.Fatal("member titles omit table ownership")
	}
	long := sc.Ref{Kind: "column", Schema: strings.Repeat("表", 700), Table: strings.Repeat("\"", 700), Name: strings.Repeat("鍵", 700)}
	report.Differences = []sc.Difference{{SourceRef: &long, Kind: "sourceOnly"}}
	plan, err = Schema(context.Background(), report, testSchemaRender)
	if err != nil || len(plan.Steps) != 1 || len(plan.Steps[0].Title) > 4096 || !utf8.ValidString(plan.Steps[0].Title) || !strings.Contains(plan.Steps[0].Title, "…") {
		t.Fatal("schema title not bounded valid UTF-8", err)
	}
}
