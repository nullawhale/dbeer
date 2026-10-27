package postgres

import (
	"context"
	"dbeer/helper/internal/comparisonjob"
	"dbeer/helper/internal/resultcompare"
	"dbeer/helper/internal/syncplan"
	tc "dbeer/helper/internal/tablecapture"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func pgSynchronizationInput(t *testing.T, reader *Session, table tc.Table) (syncplan.DataSide, resultcompare.Source) {
	t.Helper()
	ctx := context.Background()
	d, e := reader.DescribeTable(ctx, table)
	if e != nil {
		t.Fatalf("describe failed (%T)", e)
	}
	w, e := tc.NewWriter(t.TempDir(), d.Columns, d.Engine, &tc.Budget{Limit: 16 << 20})
	if e != nil {
		t.Fatal("capture storage failed")
	}
	defer w.Close()
	names := []string{}
	for _, c := range d.Columns {
		names = append(names, c.Name)
	}
	_, out, e := reader.CaptureTable(ctx, tc.Spec{Table: table, DescriptorDigest: d.Digest, Columns: names, Keys: []string{"id"}, ReadLimit: 100}, w)
	if e != nil {
		t.Fatalf("capture failed (%T)", e)
	}
	out.FullOriginals = true
	a, e := w.Publish(ctx, out)
	if e != nil {
		t.Fatal("capture publication failed")
	}
	source := comparisonjob.FromArtifact(a)
	t.Cleanup(func() { _ = source.Close() })
	return syncplan.DataSide{Descriptor: d, Outcome: out, Filters: []tc.Filter{}}, source
}

func TestDataSynchronizationPostgresLiveExactRoundTripAndStaleGuards(t *testing.T) {
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
	schema := "sync_data_" + time.Now().Format("150405000000")
	q := pgx.Identifier{schema}.Sanitize()
	ddl := "CREATE SCHEMA " + q + "; CREATE TABLE " + q + ".source(id bigint PRIMARY KEY,amount numeric(40,20),note text,bytes bytea,moment timestamptz,approx double precision,code char(5)); CREATE TABLE " + q + ".target(LIKE " + q + ".source INCLUDING ALL)"
	if _, e = conn.Exec(ctx, ddl); e != nil {
		t.Fatal("fixture creation failed")
	}
	defer conn.Exec(ctx, "DROP SCHEMA "+q+" CASCADE")
	if _, e = conn.Exec(ctx, "INSERT INTO "+q+".source VALUES (1,9007199254740993.12345678901234567890,'',decode('00ff80','hex'),'2026-10-27 12:34:56.123456+00','-0'::float8,'abc'),(2,1.00,'NULL',decode('','hex'),'2020-02-29 00:00:00+00',1.2345678901234567,'xyz'); INSERT INTO "+q+".target VALUES(1,1.00,'old',decode('ff','hex'),'2020-01-01 00:00:00+00',0,'abc'),(3,NULL,NULL,NULL,NULL,NULL,'del')"); e != nil {
		t.Fatal("fixture population failed")
	}
	read, e := pgx.Connect(ctx, dsn)
	if e != nil {
		t.Fatal("capture connection failed")
	}
	reader := &Session{conn: read}
	defer reader.Close()
	left, a := pgSynchronizationInput(t, reader, tc.Table{Schema: schema, Name: "source"})
	right, b := pgSynchronizationInput(t, reader, tc.Table{Schema: schema, Name: "target"})
	mappings := []tc.Mapping{}
	compared := []resultcompare.Mapping{}
	for i, c := range left.Descriptor.Columns {
		mappings = append(mappings, tc.Mapping{Source: c.Name, Target: c.Name, Key: i == 0})
		compared = append(compared, resultcompare.Mapping{Left: i, Right: i, Key: i == 0})
	}
	r, e := resultcompare.Compare(ctx, a, b, resultcompare.Options{Mode: "key", Columns: compared, ScratchDir: t.TempDir()})
	if e != nil {
		t.Fatal("comparison failed")
	}
	defer r.Close()
	p, e := syncplan.BuildData(ctx, syncplan.DataInput{Source: left, Target: right, Mappings: mappings, Originals: "allColumns"}, r, strings.Repeat("a", 64), RenderDataSynchronization)
	if e != nil || len(p.Steps) != 3 {
		t.Fatalf("plan generation failed (%T)", e)
	}
	var update, remove string
	for _, step := range p.Steps {
		if step.Manual {
			t.Fatal("supported captured row unexpectedly requires manual SQL")
		}
		if strings.HasPrefix(step.SQL, "UPDATE") {
			update = step.SQL
		}
		if strings.HasPrefix(step.SQL, "DELETE") {
			remove = step.SQL
		}
	}
	if update == "" || remove == "" {
		t.Fatal("plan direction incorrect")
	}
	if _, e = conn.Exec(ctx, "UPDATE "+q+".target SET note='concurrent' WHERE id=1"); e != nil {
		t.Fatal("concurrent fixture edit failed")
	}
	if tag, e := conn.Exec(ctx, update); e != nil || tag.RowsAffected() != 0 {
		t.Fatal("stale original update was not skipped")
	}
	if _, e = conn.Exec(ctx, "UPDATE "+q+".target SET note='old' WHERE id=1"); e != nil {
		t.Fatal("fixture reset failed")
	}
	if _, e = conn.Exec(ctx, "UPDATE "+q+".target SET note='concurrent' WHERE id=3"); e != nil {
		t.Fatal("concurrent delete fixture edit failed")
	}
	if tag, e := conn.Exec(ctx, remove); e != nil || tag.RowsAffected() != 0 {
		t.Fatal("stale original delete was not skipped")
	}
	if _, e = conn.Exec(ctx, "UPDATE "+q+".target SET note=NULL WHERE id=3; SET timezone='Pacific/Honolulu'; SET datestyle='SQL, DMY'; SET extra_float_digits=-3"); e != nil {
		t.Fatal("writer context setup failed")
	}
	for _, step := range p.Steps {
		if _, e = conn.Exec(ctx, step.SQL); e != nil {
			t.Fatalf("generated SQL rejected (%T)", e)
		}
	}
	_, final := pgSynchronizationInput(t, reader, tc.Table{Schema: schema, Name: "target"})
	expected, actual := [][]*string{}, [][]*string{}
	if e = a.Scan(ctx, func(_ resultcompare.RowRef, row []*string) error { expected = append(expected, row); return nil }); e != nil {
		t.Fatal("source artifact unavailable")
	}
	if e = final.Scan(ctx, func(_ resultcompare.RowRef, row []*string) error { actual = append(actual, row); return nil }); e != nil {
		t.Fatal("final capture unavailable")
	}
	if !reflect.DeepEqual(expected, actual) {
		t.Fatal("generated SQL changed exact stored values")
	}
}
