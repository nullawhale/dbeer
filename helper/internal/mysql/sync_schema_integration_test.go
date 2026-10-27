package mysql

import (
	"context"
	"fmt"
	"testing"

	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/syncplan"
)

func TestSynchronizationSchemaFromLiveCapture(t *testing.T) {
	session := integrationSession(t)
	settings := integrationSettings(t)
	ctx := context.Background()
	source := fmt.Sprintf("dbeer_sync_%x_source", session.connectionID)
	target := fmt.Sprintf("dbeer_sync_%x_target", session.connectionID)
	for _, name := range []string{source, target} {
		run(t, session, "DROP TABLE IF EXISTS "+QuoteIdentifier(name))
		defer run(t, session, "DROP TABLE IF EXISTS "+QuoteIdentifier(name))
	}
	run(t, session, "CREATE TABLE "+QuoteIdentifier(source)+" (id BIGINT NULL, amount DECIMAL(30,9) NULL DEFAULT 9007199254740993.123456789, title VARCHAR(255) NULL COMMENT 'source''s title', CONSTRAINT source_key UNIQUE(id), KEY title_idx(title(12) DESC)) ENGINE=InnoDB DEFAULT CHARACTER SET=utf8mb4 COLLATE=utf8mb4_bin")
	capture := func() sc.Capture {
		opened, e := Open(ctx, settings)
		if e != nil {
			t.Fatal("capture open failed")
		}
		defer opened.Close()
		reader := opened.(*Session)
		if e = reader.SetReadOnly(ctx, true); e != nil {
			t.Fatal("read-only setup failed")
		}
		collector := sc.NewCollector(ctx, sc.DefaultLimits())
		if e = reader.ReadSchema(ctx, sc.CaptureSpec{Schemas: []string{settings.Database}, Limits: sc.DefaultLimits()}, collector); e != nil {
			t.Fatalf("capture failed: %T", e)
		}
		return collector.Capture
	}
	all := capture()
	var original sc.Table
	found := false
	for _, table := range all.Tables {
		if table.Ref.Name == source {
			original, found = table, true
		}
	}
	if !found {
		t.Fatal("source table missing")
	}
	scope := func(c sc.Capture, table *sc.Table) sc.Capture {
		out := sc.Capture{Context: c.Context, Inventories: []sc.Inventory{{Schema: settings.Database, Existence: "present", Tables: sc.Complete[sc.Ref](nil), Types: sc.Complete[sc.Ref](nil)}}}
		if table != nil {
			out.Tables = []sc.Table{*table}
			out.Inventories[0].Tables = sc.Complete([]sc.Ref{table.Ref})
		}
		return out
	}
	left, right := scope(all, &original), scope(all, nil)
	mappings := sc.Mappings{Schemas: []sc.NamePair{{Source: settings.Database, Target: settings.Database}}, Tables: []sc.TablePair{{Source: sc.QualifiedName{Schema: settings.Database, Name: source}, Target: sc.QualifiedName{Schema: settings.Database, Name: target}, Columns: []sc.NamePair{}, Constraints: []sc.NamePair{}, Indexes: []sc.NamePair{}}}, Types: []sc.ObjectPair{}}
	result, err := sc.Build(ctx, t.TempDir(), left, right, mappings)
	if err != nil {
		t.Fatal(err)
	}
	defer result.Close()
	run(t, session, "DROP TABLE "+QuoteIdentifier(source))
	plan, err := syncplan.Schema(ctx, result.Report, RenderSynchronizationSchema)
	if err != nil {
		t.Fatal("plan failed", err)
	}
	for _, table := range capture().Tables {
		if table.Ref.Name == target {
			t.Fatal("planning changed target")
		}
	}
	if len(plan.Steps) != 3 {
		t.Fatalf("expected table, unique constraint and standalone index; steps=%d", len(plan.Steps))
	}
	for _, step := range plan.Steps {
		if step.Manual || !step.Selected {
			t.Fatalf("supported step unavailable: %s", step.Reason)
		}
		run(t, session, step.SQL)
	}
	created := capture()
	var recreated *sc.Table
	for i := range created.Tables {
		if created.Tables[i].Ref.Name == target {
			recreated = &created.Tables[i]
		}
	}
	if recreated == nil {
		t.Fatal("generated target missing")
	}
	compared, err := sc.Build(ctx, t.TempDir(), left, scope(created, recreated), mappings)
	if err != nil {
		t.Fatal(err)
	}
	defer compared.Close()
	if !compared.Report.Summary.FullEquality {
		for _, d := range compared.Report.Differences {
			t.Log(d.Property, d.Kind)
		}
		t.Fatal("executed plan did not preserve captured structure")
	}
}
