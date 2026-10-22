package postgres

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"github.com/jackc/pgx/v5"
	"os"
	"testing"
	"time"
)

func TestSchemaCapturePortableTypesAndReadOnly(t *testing.T) {
	dsn := os.Getenv("DBEER_TEST_DSN")
	if dsn == "" {
		t.Skip("disposable PostgreSQL fixture required")
	}
	ctx := context.Background()
	conn, e := pgx.Connect(ctx, dsn)
	if e != nil {
		t.Fatal("fixture connection failed")
	}
	defer conn.Close(ctx)
	suffix := time.Now().Format("150405000000")
	a, b := "schema_a_"+suffix, "schema_b_"+suffix
	for _, schema := range []string{a, b} {
		q := pgx.Identifier{schema}.Sanitize()
		if _, e = conn.Exec(ctx, "CREATE SCHEMA "+q+"; CREATE TYPE "+q+".mood AS ENUM ('new','done'); CREATE TABLE "+q+".orders(id numeric(30,9) PRIMARY KEY,status "+q+".mood, note text DEFAULT '',twice numeric GENERATED ALWAYS AS (id * 2) STORED); CREATE INDEX note_idx ON "+q+".orders(note) INCLUDE(status)"); e != nil {
			t.Fatal("fixture creation failed")
		}
		defer conn.Exec(ctx, "DROP SCHEMA "+q+" CASCADE")
	}
	capture := func(schema string) sc.Capture {
		reader, e := pgx.Connect(ctx, dsn)
		if e != nil {
			t.Fatal("capture connection failed")
		}
		defer reader.Close(ctx)
		c := sc.NewCollector(ctx, sc.DefaultLimits())
		s := &Session{conn: reader}
		if e = s.ReadSchema(ctx, sc.CaptureSpec{Schemas: []string{schema}, Limits: sc.DefaultLimits()}, c); e != nil {
			t.Fatalf("capture failed: %T", e)
		}
		return c.Capture
	}
	left, right := capture(a), capture(b)
	m := sc.Mappings{Schemas: []sc.NamePair{{Source: a, Target: b}}, Tables: []sc.TablePair{}, Types: []sc.ObjectPair{}}
	result, e := sc.Build(ctx, t.TempDir(), left, right, m)
	if e != nil {
		t.Fatal(e)
	}
	defer result.Close()
	if !result.Report.Summary.FullEquality {
		for _, d := range result.Report.Differences {
			t.Log(d.Property, d.Kind)
		}
		t.Fatal("portable equal schemas did not match")
	}
	if _, e = conn.Exec(ctx, "ALTER TYPE "+pgx.Identifier{b}.Sanitize()+".mood ADD VALUE 'later'"); e != nil {
		t.Fatal("fixture alteration failed")
	}
	changed, e := sc.Build(ctx, t.TempDir(), left, capture(b), m)
	if e != nil {
		t.Fatal(e)
	}
	defer changed.Close()
	if changed.Report.Summary.FullEquality || changed.Report.Summary.DifferenceCount == 0 {
		t.Fatal("enum drift was missed")
	}
}

func TestSchemaCaptureDeniedMetadataNeverProvesEquality(t *testing.T) {
	dsn := os.Getenv("DBEER_TEST_DSN")
	if dsn == "" {
		t.Skip("disposable PostgreSQL fixture required")
	}
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal("fixture connection failed")
	}
	defer conn.Close(ctx)
	suffix := time.Now().Format("150405000000")
	schema, role := "schema_access_"+suffix, "schema_reader_"+suffix
	q, user := pgx.Identifier{schema}.Sanitize(), pgx.Identifier{role}.Sanitize()
	if _, err = conn.Exec(ctx, "CREATE SCHEMA "+q+"; CREATE TABLE "+q+".orders(id int PRIMARY KEY,note text); CREATE ROLE "+user+"; GRANT USAGE ON SCHEMA "+q+" TO "+user+"; GRANT SELECT ON "+q+".orders TO "+user); err != nil {
		t.Fatal("access fixture creation failed")
	}
	defer conn.Exec(ctx, "DROP SCHEMA "+q+" CASCADE; DROP ROLE "+user)
	capture := func() sc.Capture {
		reader, e := pgx.Connect(ctx, dsn)
		if e != nil {
			t.Fatal("reader open failed")
		}
		defer reader.Close(ctx)
		if _, e = reader.Exec(ctx, "SET ROLE "+user); e != nil {
			t.Fatal("reader role failed")
		}
		collector := sc.NewCollector(ctx, sc.DefaultLimits())
		if e = (&Session{conn: reader}).ReadSchema(ctx, sc.CaptureSpec{Schemas: []string{schema}, Limits: sc.DefaultLimits()}, collector); e != nil {
			t.Fatalf("access capture failed: %T", e)
		}
		return collector.Capture
	}
	m := sc.Mappings{Schemas: []sc.NamePair{{Source: schema, Target: schema}}, Tables: []sc.TablePair{}, Types: []sc.ObjectPair{}}
	allowed := capture()
	hasPK := false
	for _, table := range allowed.Tables {
		for _, constraint := range table.Constraints.Items {
			if constraint.Kind.Value != nil && *constraint.Kind.Value == "p" {
				hasPK = true
			}
		}
	}
	if len(allowed.Tables) != 1 || !hasPK {
		t.Fatal("SELECT-only role lost catalog constraints")
	}
	if _, err = conn.Exec(ctx, "REVOKE ALL ON SCHEMA "+q+" FROM "+user+"; REVOKE ALL ON "+q+".orders FROM "+user); err != nil {
		t.Fatal("fixture revoke failed")
	}
	denied := capture()
	result, e := sc.Build(ctx, t.TempDir(), denied, capture(), m)
	if e != nil {
		t.Fatal(e)
	}
	defer result.Close()
	if result.Report.Summary.FullEquality || result.Report.Summary.Complete || result.Report.Summary.IssueCount == 0 {
		t.Fatal("matching denied access established equality")
	}
}
