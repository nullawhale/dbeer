package postgres

import (
	"context"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/resultcompare"
	tc "dbeer/helper/internal/tablecapture"
	"github.com/jackc/pgx/v5"
)

type queryObservedSource struct{ response protocol.Response }

func (s queryObservedSource) Metadata() resultcompare.Metadata {
	columns := make([]resultcompare.Column, len(s.response.Columns))
	for i, c := range s.response.Columns {
		columns[i] = resultcompare.Column{Index: i, Name: c.Name, Engine: c.Engine, NativeType: c.NativeType, TypeIdentity: c.TypeIdentity, Encoding: c.Encoding}
	}
	return resultcompare.Metadata{Columns: columns, RowCount: int64(len(s.response.Rows)), Complete: !s.response.Truncated}
}
func (s queryObservedSource) Scan(ctx context.Context, visit func(resultcompare.RowRef, []*string) error) error {
	for i, row := range s.response.Rows {
		if e := ctx.Err(); e != nil {
			return e
		}
		if e := visit(resultcompare.RowRef{Index: int64(i)}, row); e != nil {
			return e
		}
	}
	return nil
}
func (s queryObservedSource) ReadRow(ctx context.Context, ref resultcompare.RowRef) ([]*string, error) {
	if e := ctx.Err(); e != nil {
		return nil, e
	}
	if ref.Index < 0 || ref.Index >= int64(len(s.response.Rows)) {
		return nil, resultcompare.ErrReference
	}
	return s.response.Rows[ref.Index], nil
}
func (s queryObservedSource) Close() error { return nil }

func assertQueryOutputUncertain(t *testing.T, left, right protocol.Response) {
	t.Helper()
	if left.Type != "query.result" || right.Type != "query.result" || len(left.Columns) == 0 || len(left.Columns) != len(right.Columns) || len(left.Rows) != 1 || len(right.Rows) != 1 {
		t.Fatal("output fixture query failed")
	}
	mappings := make([]resultcompare.Mapping, len(left.Columns))
	for i := range mappings {
		if !strings.HasPrefix(left.Columns[i].TypeIdentity, "unresolved:") || !strings.HasPrefix(right.Columns[i].TypeIdentity, "unresolved:") {
			t.Fatalf("contextual output column %d advertised exact equality", i)
		}
		mappings[i] = resultcompare.Mapping{Left: i, Right: i}
	}
	compared, e := resultcompare.Compare(context.Background(), queryObservedSource{left}, queryObservedSource{right}, resultcompare.Options{Mode: "rowOrder", Columns: mappings, ScratchDir: t.TempDir()})
	if e != nil {
		t.Fatal(e)
	}
	defer compared.Close()
	if s := compared.Summary(); s.FullEquality || s.EqualRows != 0 || s.UncertainRows != 1 {
		t.Fatalf("contextual output established exact value equality: %#v", s)
	}
}

func TestQueryDateStyleCollisionAndNestedTypesRemainUncertain(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	f.exec("CREATE TYPE " + f.table("dated") + " AS (value date)")
	run := func(style, lower, upper string) protocol.Response {
		t.Helper()
		if _, e := f.conn.Exec(ctx, "SET DateStyle="+postgresTextLiteral(style)); e != nil {
			t.Fatal("date style fixture failed")
		}
		sql := "SELECT DATE '" + lower + "' AS value,ARRAY[DATE '" + lower + "'] AS values,ROW(DATE '" + lower + "')::" + f.table("dated") + " AS record,daterange(DATE '" + lower + "',DATE '" + upper + "','[)') AS span,datemultirange(daterange(DATE '" + lower + "',DATE '" + upper + "','[)')) AS spans"
		r := execute(ctx, f.conn, protocol.Command{Type: "execute", SQL: sql})
		var after string
		if e := f.conn.QueryRow(ctx, "SELECT pg_catalog.current_setting('DateStyle')").Scan(&after); e != nil || after != style {
			t.Fatal("query metadata changed caller date style")
		}
		return r
	}
	left := run("SQL, MDY", "2026-04-05", "2026-04-06")
	right := run("SQL, DMY", "2026-05-04", "2026-06-04")
	if left.Type != "query.result" || right.Type != "query.result" {
		t.Fatal("date result unavailable")
	}
	for i := range left.Rows[0] {
		if *left.Rows[0][i] != *right.Rows[0][i] {
			t.Fatalf("date collision fixture did not reproduce for column %d", i)
		}
	}
	assertQueryOutputUncertain(t, left, right)
}

func TestQueryRoundedFloatAndGeometricOutputRemainUncertain(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	f.exec("CREATE TYPE " + f.table("floating") + " AS (value double precision);CREATE TYPE " + f.table("float_span") + " AS RANGE(subtype=double precision)")
	if _, e := f.conn.Exec(ctx, "SET extra_float_digits=-3"); e != nil {
		t.Fatal("float output fixture failed")
	}
	run := func(value string) protocol.Response {
		t.Helper()
		return execute(ctx, f.conn, protocol.Command{Type: "execute", SQL: "SELECT '" + value + "'::float8 AS value,ARRAY['" + value + "'::float8] AS values,point('" + value + "'::float8,1) AS point,ROW('" + value + "'::float8)::" + f.table("floating") + " AS record," + f.table("float_span") + "('" + value + "'::float8,2,'[)') AS span"})
	}
	left, right := run("1.234567890123456"), run("1.234567890123457")
	if left.Type != "query.result" || right.Type != "query.result" || *left.Rows[0][0] != *right.Rows[0][0] || *left.Rows[0][1] != *right.Rows[0][1] {
		t.Fatal("rounded floating point collision did not reproduce")
	}
	assertQueryOutputUncertain(t, left, right)
	var digits string
	if e := f.conn.QueryRow(ctx, "SELECT pg_catalog.current_setting('extra_float_digits')").Scan(&digits); e != nil || digits != "-3" {
		t.Fatal("query metadata changed caller float precision")
	}
}

func TestQueryContextualObjectReferencesRemainUncertain(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	other := f.schema + "_other"
	f.exec("CREATE SCHEMA " + pgx.Identifier{other}.Sanitize() + ";CREATE TABLE " + f.table("target") + "(value integer);CREATE TABLE " + pgx.Identifier{other, "target"}.Sanitize() + "(value integer);CREATE TYPE " + f.table("reference") + " AS (value regclass)")
	t.Cleanup(func() {
		f.observer.Exec(context.Background(), "DROP SCHEMA "+pgx.Identifier{other}.Sanitize()+" CASCADE")
	})
	run := func(schema string) protocol.Response {
		t.Helper()
		if _, e := f.conn.Exec(ctx, "SET search_path="+pgx.Identifier{schema}.Sanitize()+",pg_catalog"); e != nil {
			t.Fatal("reference output fixture failed")
		}
		return execute(ctx, f.conn, protocol.Command{Type: "execute", SQL: "SELECT 'target'::regclass AS value,ARRAY['target'::regclass] AS values,ROW('target'::regclass)::" + f.table("reference") + " AS record"})
	}
	left, right := run(f.schema), run(other)
	if left.Type != "query.result" || right.Type != "query.result" || *left.Rows[0][0] != *right.Rows[0][0] {
		t.Fatal("contextual object reference collision did not reproduce")
	}
	assertQueryOutputUncertain(t, left, right)
}

func TestQueryMoneyAndTimeOutputRetainsSettingsAndUncertainty(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	sql := "SELECT 1::money AS amount,ARRAY[1::money] AS amounts,TIMESTAMPTZ '2026-10-23 01:02:03+00' AS changed,INTERVAL '1 month 2 days' AS duration"
	left := execute(ctx, f.conn, protocol.Command{Type: "execute", SQL: sql})
	right := execute(ctx, f.conn, protocol.Command{Type: "execute", SQL: sql})
	assertQueryOutputUncertain(t, left, right)
}

func TestOutputSensitiveLegacyEditsRequireRowStorageToken(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	f.exec("CREATE TABLE " + f.table("dated") + "(id integer PRIMARY KEY,value date,note text);INSERT INTO " + f.table("dated") + " VALUES(1,DATE '2026-04-05','original')")
	if _, e := f.conn.Exec(ctx, "SET DateStyle='SQL, MDY'"); e != nil {
		t.Fatal("date style fixture failed")
	}
	before := execute(ctx, f.conn, protocol.Command{Type: "execute", SQL: "SELECT * FROM " + f.table("dated")})
	original := make([]protocol.CellValue, len(before.Rows[0]))
	for i, v := range before.Rows[0] {
		original[i] = protocol.CellValue{Kind: "text", Value: v}
	}
	request := f.request("dated", protocol.RowChange{Kind: "update", Original: original, Values: []protocol.ColumnAssignment{changeAssign("note", changeText("changed"))}})
	if r := changes(ctx, f.conn, protocol.Command{Type: "changes.preview", Changes: &request}); r.Category != "validation" {
		t.Fatal("legacy date text silently advertised safe optimistic comparison")
	}
	browsed := catalog(ctx, f.conn, protocol.Command{Type: "catalog", Catalog: &protocol.CatalogRequest{Kind: "browse", Schema: f.schema, Object: "dated", ObjectKind: "table"}})
	if len(browsed.StorageTokens) != 1 {
		t.Fatal("fresh browse row token missing")
	}
	request.Changes[0].StorageToken = browsed.StorageTokens[0]
	if r := f.apply(request); r.Type != "query.result" {
		t.Fatal("row token did not permit date row editing")
	}
}

func TestQueryCanChangeRenderingInsideExecuteWithoutProvingEquality(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	if _, e := f.conn.Exec(ctx, "SET DateStyle='ISO, MDY'"); e != nil {
		t.Fatal("initial date style failed")
	}
	r := execute(ctx, f.conn, protocol.Command{Type: "execute", SQL: "SELECT pg_catalog.set_config('DateStyle','SQL, DMY',false),DATE '2026-05-04' AS value"})
	if r.Type != "query.result" || len(r.Rows) != 1 || *r.Rows[0][1] != "04/05/2026" || !strings.HasPrefix(r.Columns[1].TypeIdentity, "unresolved:") {
		t.Fatal("caller SQL rendering mutation advertised preflight canonical equality")
	}
	var style string
	if e := f.conn.QueryRow(ctx, "SELECT pg_catalog.current_setting('DateStyle')").Scan(&style); e != nil || style != "SQL, DMY" {
		t.Fatal("metadata overrode a rendering change made by caller SQL")
	}
}

func TestNormalizedTableCaptureRetainsExactDateAndFloatComparison(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	f.exec("CREATE TABLE " + f.table("normalized") + "(id integer PRIMARY KEY,day date,value double precision);INSERT INTO " + f.table("normalized") + " VALUES(1,DATE '2026-04-05',1.234567890123456)")
	if _, e := f.conn.Exec(ctx, "SET DateStyle='SQL, DMY';SET extra_float_digits=-3"); e != nil {
		t.Fatal("caller rendering fixture failed")
	}
	reader := &Session{conn: f.conn}
	descriptor, e := reader.DescribeTable(ctx, tc.Table{Schema: f.schema, Name: "normalized"})
	if e != nil {
		t.Fatal("normalized table description failed", e)
	}
	for _, c := range descriptor.Columns {
		if c.ValueComparison != "" {
			t.Fatal("normalized table output lost its proven value identity")
		}
	}
	sink := &dataTestSink{}
	if _, _, e = reader.CaptureTable(ctx, tc.Spec{Table: descriptor.Table, DescriptorDigest: descriptor.Digest, Columns: []string{"id", "day", "value"}, Keys: []string{"id"}, ReadLimit: 10}, sink); e != nil {
		t.Fatal("normalized table capture failed", e)
	}
	if len(sink.rows) != 1 || *sink.rows[0][1] != "2026-04-05" || *sink.rows[0][2] != "1.234567890123456" {
		t.Fatal("normalized capture inherited lossy caller rendering")
	}
	var style, digits string
	if e = f.conn.QueryRow(ctx, "SELECT pg_catalog.current_setting('DateStyle'),pg_catalog.current_setting('extra_float_digits')").Scan(&style, &digits); e != nil || style != "SQL, DMY" || digits != "-3" {
		t.Fatal("table capture changed persistent caller rendering settings")
	}
}
