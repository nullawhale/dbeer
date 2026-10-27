package postgres

import (
	"context"
	"os"
	"testing"
	"time"

	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/syncplan"
	"github.com/jackc/pgx/v5"
)

func TestSynchronizationSchemaFromLiveCapture(t *testing.T) {
	dsn := os.Getenv("DBEER_TEST_DSN")
	if dsn == "" {
		t.Skip("disposable PostgreSQL fixture required")
	}
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal("fixture open failed")
	}
	defer conn.Close(ctx)
	suffix := time.Now().Format("150405000000")
	source, target := "sync_source_"+suffix, "sync_target_"+suffix
	for _, schema := range []string{source, target} {
		q := pgx.Identifier{schema}.Sanitize()
		if _, err = conn.Exec(ctx, "CREATE SCHEMA "+q); err != nil {
			t.Fatal("schema fixture failed")
		}
		defer conn.Exec(ctx, "DROP SCHEMA "+q+" CASCADE")
	}
	q := pgx.Identifier{source}.Sanitize()
	if _, err = conn.Exec(ctx, "CREATE TABLE "+q+".parent(id bigint, CONSTRAINT parent_key UNIQUE(id)); CREATE TABLE "+q+".child(parent_id bigint, title text, CONSTRAINT child_fk FOREIGN KEY(parent_id) REFERENCES "+q+".parent(id)); CREATE INDEX child_title_idx ON "+q+".child(title)"); err != nil {
		t.Fatal("table fixture failed")
	}
	capture := func(schema string) sc.Capture {
		reader, e := pgx.Connect(ctx, dsn)
		if e != nil {
			t.Fatal("capture open failed")
		}
		defer reader.Close(ctx)
		session := &Session{conn: reader}
		if e = session.SetReadOnly(ctx, true); e != nil {
			t.Fatal("read-only setup failed")
		}
		collector := sc.NewCollector(ctx, sc.DefaultLimits())
		if e = session.ReadSchema(ctx, sc.CaptureSpec{Schemas: []string{schema}, Limits: sc.DefaultLimits()}, collector); e != nil {
			t.Fatalf("capture failed: %T", e)
		}
		return collector.Capture
	}
	left, right := capture(source), capture(target)
	mappings := sc.Mappings{Schemas: []sc.NamePair{{Source: source, Target: target}}, Tables: []sc.TablePair{}, Types: []sc.ObjectPair{}}
	result, err := sc.Build(ctx, t.TempDir(), left, right, mappings)
	if err != nil {
		t.Fatal(err)
	}
	defer result.Close()
	// Remove the original fixture before planning. A generator that secretly
	// queries either endpoint cannot reconstruct the retained source facts.
	if _, err = conn.Exec(ctx, "DROP SCHEMA "+q+" CASCADE"); err != nil {
		t.Fatal("source retirement failed")
	}
	plan, err := syncplan.Schema(ctx, result.Report, RenderSynchronizationSchema)
	if err != nil {
		t.Fatal("plan failed", err)
	}
	if len(capture(target).Tables) != 0 {
		t.Fatal("planning changed target")
	}
	if len(plan.Steps) != 5 {
		t.Fatalf("expected two tables, two constraints and index; steps=%d", len(plan.Steps))
	}
	for _, step := range plan.Steps {
		if step.Manual || !step.Selected {
			t.Fatalf("supported step unavailable: %s", step.Reason)
		}
		if _, err = conn.Exec(ctx, step.SQL); err != nil {
			t.Fatalf("target rejected generated %s (%T)", step.ID, err)
		}
	}
	compared, err := sc.Build(ctx, t.TempDir(), left, capture(target), mappings)
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
