package postgres

import (
	"context"
	"strings"
	"testing"

	"dbeer/helper/internal/comparisonjob"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/resultartifact"
	"dbeer/helper/internal/resultcompare"
	sc "dbeer/helper/internal/schemacompare"
	tc "dbeer/helper/internal/tablecapture"
	"github.com/jackc/pgx/v5"
)

type storageTestSink struct {
	columns []protocol.Column
	rows    [][]*string
	summary protocol.ResultSet
}

func (s *storageTestSink) Begin(_ int, c []protocol.Column) error { s.columns = c; return nil }
func (s *storageTestSink) Row(_ int, r []*string) error           { s.rows = append(s.rows, r); return nil }
func (s *storageTestSink) End(_ int, r protocol.ResultSet) error  { s.summary = r; return nil }

func TestBrowseStorageTokensProtectLossyCustomTypes(t *testing.T) {
	f := newChangeFixture(t)
	f.exec("CREATE TYPE " + f.table("lossy") + ";CREATE FUNCTION " + f.table("lossy_in") + "(cstring) RETURNS " + f.table("lossy") + " AS 'int4in' LANGUAGE internal IMMUTABLE STRICT;CREATE FUNCTION " + f.table("lossy_out") + "(" + f.table("lossy") + ") RETURNS cstring AS 'boolout' LANGUAGE internal IMMUTABLE STRICT;CREATE TYPE " + f.table("lossy") + " (INPUT=" + f.table("lossy_in") + ",OUTPUT=" + f.table("lossy_out") + ",INTERNALLENGTH=4,PASSEDBYVALUE,ALIGNMENT=int4,STORAGE=plain);CREATE TABLE " + f.table("records") + "(id integer PRIMARY KEY,value " + f.table("lossy") + ",note text);INSERT INTO " + f.table("records") + " VALUES(1,'1','original');CREATE VIEW " + f.table("view") + " AS SELECT * FROM " + f.table("records"))
	browse := func(name string) (protocol.Response, *storageTestSink) {
		t.Helper()
		sink := &storageTestSink{}
		r := catalogWithSink(context.Background(), f.conn, protocol.Command{Type: "catalog", Catalog: &protocol.CatalogRequest{Kind: "browse", Schema: f.schema, Object: name, ObjectKind: "table"}}, sink)
		if r.Type != "query.result" || len(r.Columns) != 3 || len(r.Rows) != 1 || len(sink.columns) != 3 || len(sink.rows) != 1 || len(sink.rows[0]) != 3 {
			t.Fatal("browse storage projection leaked or failed")
		}
		return r, sink
	}
	captureData := func() resultartifact.Artifact {
		t.Helper()
		ctx := context.Background()
		reader := &Session{conn: f.observer}
		descriptor, e := reader.DescribeTable(ctx, tc.Table{Schema: f.schema, Name: "records"})
		if e != nil || descriptor.Columns[1].ValueComparison != "unresolved" {
			t.Fatal("lossy type advertised exact data comparison", e)
		}
		writer, e := tc.NewWriter(t.TempDir(), descriptor.Columns, "postgresql", &tc.Budget{Limit: 64 << 20})
		if e != nil {
			t.Fatal(e)
		}
		_, out, e := reader.CaptureTable(ctx, tc.Spec{Table: descriptor.Table, DescriptorDigest: descriptor.Digest, Columns: []string{"id", "value", "note"}, Keys: []string{"id"}, ReadLimit: 10}, writer)
		if e != nil {
			t.Fatal("lossy data capture failed", e)
		}
		artifact, e := writer.Publish(ctx, out)
		if e != nil {
			t.Fatal(e)
		}
		t.Cleanup(func() { artifact.Close() })
		return artifact
	}
	capturedBefore := captureData()
	before, sink := browse("records")
	if !strings.HasPrefix(before.Columns[1].TypeIdentity, "unresolved:") {
		t.Fatal("lossy query type advertised exact value equality")
	}

	if len(before.StorageTokens) != 1 || !validPostgresStorageToken(before.StorageTokens[0]) || len(sink.summary.StorageTokens) != 1 || sink.summary.StorageTokens[0] != before.StorageTokens[0] {
		t.Fatal("browse did not retain its bounded row token")
	}
	if strings.Contains(before.SQL, postgresStorageAlias) || strings.Contains(before.SQL, "xmin") {
		t.Fatal("storage projection leaked into user SQL")
	}
	original := f.snapshot("records", "id=1")
	request := f.request("records", protocol.RowChange{Kind: "update", Original: original, Values: []protocol.ColumnAssignment{changeAssign("note", changeText("changed"))}})
	if r := changes(context.Background(), f.conn, protocol.Command{Type: "changes.preview", Changes: &request}); r.Category != "validation" {
		t.Fatal("lossy custom type accepted legacy text-only conflict detection")
	}
	request.Changes[0].StorageToken = before.StorageTokens[0]
	f.exec("UPDATE " + f.table("records") + " SET value='2' WHERE id=1")
	after, _ := browse("records")
	capturedAfter := captureData()
	compared, e := resultcompare.Compare(context.Background(), comparisonjob.FromArtifact(capturedBefore), comparisonjob.FromArtifact(capturedAfter), resultcompare.Options{Mode: "rowOrder", ScratchDir: t.TempDir(), Columns: []resultcompare.Mapping{{Left: 0, Right: 0}, {Left: 1, Right: 1}, {Left: 2, Right: 2}}})
	if e != nil {
		t.Fatal(e)
	}
	defer compared.Close()
	if summary := compared.Summary(); summary.FullEquality || summary.EqualRows != 0 || summary.UncertainRows != 1 {
		t.Fatalf("same-text lossy capture falsely established equality: %#v", summary)
	}

	if *before.Rows[0][1] != *after.Rows[0][1] || before.StorageTokens[0] == after.StorageTokens[0] {
		t.Fatal("lossy output fixture did not retain equal text with a changed row version")
	}
	if r := f.apply(request); r.Category != "conflict" || f.scalar("SELECT note FROM "+f.table("records")) != "original" {
		t.Fatal("same-text custom value mutation bypassed optimistic protection")
	}
	request.Changes[0].StorageToken = after.StorageTokens[0]
	if r := f.apply(request); r.Type != "query.result" || f.scalar("SELECT note FROM "+f.table("records")) != "changed" {
		t.Fatal("fresh row token did not enable arbitrary custom type editing")
	}
	view, _ := browse("view")
	if len(view.StorageTokens) != 0 {
		t.Fatal("view exposed a fabricated physical row token")
	}
	normal := execute(context.Background(), f.conn, protocol.Command{Type: "execute", SQL: "SELECT 'visible'::text AS " + `"` + postgresStorageAlias + `"`})
	if len(normal.Columns) != 1 || len(normal.Rows) != 1 || *normal.Rows[0][0] != "visible" || len(normal.StorageTokens) != 0 {
		t.Fatal("normal SQL was mistaken for a trusted storage projection")
	}
}

func TestQueryTypeStatementsSurviveDeallocateAndDiscardAll(t *testing.T) {
	f := newChangeFixture(t)
	f.exec("CREATE TYPE " + f.table("mood") + " AS ENUM ('x')")
	sql := "SELECT 'x'::" + f.table("mood")
	for _, utility := range []string{"DEALLOCATE ALL", "DISCARD ALL"} {
		if r := execute(context.Background(), f.conn, protocol.Command{Type: "execute", SQL: sql}); r.Type != "query.result" {
			t.Fatal("initial typed result failed")
		}
		if r := execute(context.Background(), f.conn, protocol.Command{Type: "execute", SQL: utility}); r.Type != "query.result" || f.conn.IsClosed() {
			t.Fatal("utility statement closed its own owning connection")
		}
		if r := execute(context.Background(), f.conn, protocol.Command{Type: "execute", SQL: sql}); r.Type != "query.result" || f.conn.IsClosed() {
			t.Fatalf("metadata statement cache did not recover after %s: category=%s SQLSTATE=%s", utility, r.Category, r.SQLState)
		}
	}
}

func TestQueryTypeMetadataIgnoresUserSearchPathShadows(t *testing.T) {
	f := newChangeFixture(t)
	f.exec("CREATE TYPE " + f.table("mood") + " AS ENUM ('x');CREATE TABLE " + f.table("pg_type") + "(unrelated text);CREATE FUNCTION " + f.table("format_type") + "(oid,integer) RETURNS text LANGUAGE sql IMMUTABLE AS 'SELECT ''shadow function''::text'")
	ctx := context.Background()
	if _, e := f.conn.Exec(ctx, "SET search_path="+pgx.Identifier{f.schema}.Sanitize()+",pg_catalog"); e != nil {
		t.Fatal("explicit user search path failed")
	}
	r := execute(ctx, f.conn, protocol.Command{Type: "execute", SQL: "SELECT 'x'::" + f.table("mood")})
	if r.Type != "query.result" || len(r.Columns) != 1 || r.Columns[0].TypeIdentity == "" {
		t.Fatalf("catalog type lookup followed user schema shadow: category=%s SQLSTATE=%s", r.Category, r.SQLState)
	}
	collector := sc.NewCollector(ctx, sc.DefaultLimits())
	capture := &schemaCapture{ctx: ctx, tx: f.conn, sink: collector, spec: sc.CaptureSpec{Limits: sc.DefaultLimits()}, types: map[string]sc.TypeUse{}, loading: map[string]bool{}, sequences: map[string]bool{}}
	use, e := capture.modifiers("26", definitionBuiltin("oid", sc.TypeModifiers{}), 42, 0)
	if e != nil || use.Modifiers.Value == nil || use.Modifiers.Value.SQL == nil || strings.Contains(*use.Modifiers.Value.SQL, "shadow") {
		t.Fatal("type formatting followed user function shadow")
	}
	var path string
	if e = f.conn.QueryRow(ctx, "SELECT pg_catalog.current_setting('search_path')").Scan(&path); e != nil || !strings.Contains(path, f.schema) {
		t.Fatal("metadata changed owning connection search path")
	}
}
