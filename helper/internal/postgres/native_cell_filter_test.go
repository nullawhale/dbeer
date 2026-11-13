package postgres

import (
	"context"
	"encoding/json"
	"os"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
)

func nativePGFilter(column, kind, value, engine, native string) protocol.CatalogFilter {
	return protocol.CatalogFilter{Column: column, Operator: "eq", NativeValue: &protocol.NativeCellFilterValue{Cell: protocol.CellValue{Kind: kind, Value: &value}, SourceEngine: engine, SourceType: native, SQLiteStorage: "text"}}
}

func TestPostgresNativeCellFilterPlanKeepsTypesAndBoundOperands(t *testing.T) {
	request := protocol.CatalogRequest{Schema: "public", Object: "typed", Filters: []protocol.CatalogFilter{
		nativePGFilter("n", "text", "9007199254740993.000000000000000001", "postgresql", "numeric(40,20)"),
		nativePGFilter("b", "binary", "AP8=", "mysql", "varbinary(2)"),
		nativePGFilter("txt", "text", "NULL", "postgresql", "untrusted'); SELECT --"),
	}}
	plan, err := buildBrowsePlan(request, []browseColumn{{name: "n", numeric: true, baseOID: 1700}, {name: "b", binary: true, baseOID: 17}, {name: "txt", baseOID: 25}})
	if err != nil || !strings.Contains(plan.statement, `"n" = $1::numeric AND "b" = $2 AND "txt" = $3`) || strings.Contains(plan.sourceSQL, "untrusted") {
		t.Fatal("native filter did not use trusted metadata and bound operands")
	}
	want := [][]byte{[]byte("9007199254740993.000000000000000001"), []byte(`\x00ff`), []byte("NULL")}
	if !reflect.DeepEqual(plan.values, want) {
		t.Fatal("native filter changed exact numeric, binary, or text bytes")
	}
	request.Filters = []protocol.CatalogFilter{nativePGFilter("n", "sqliteReal", "3fb999999999999a", "sqlite", "ANY")}
	plan, err = buildBrowsePlan(request, []browseColumn{{name: "n", numeric: true, baseOID: 1700}})
	if err != nil || string(plan.values[0]) != "0.1000000000000000055511151231257827021181583404541015625" {
		t.Fatal("SQLite REAL lost its full IEEE decimal")
	}
	for _, test := range []struct {
		filter protocol.CatalogFilter
		column browseColumn
	}{
		{nativePGFilter("v", "text", "AP8=", "postgresql", "text"), browseColumn{name: "v", binary: true, baseOID: 17}},
		{nativePGFilter("v", "binary", "AP8=", "mysql", "blob"), browseColumn{name: "v", baseOID: 25}},
		{nativePGFilter("v", "sqliteText", "YQBi", "sqlite", "ANY"), browseColumn{name: "v", baseOID: 25}},
		{nativePGFilter("v", "sqliteText", "/w==", "sqlite", "ANY"), browseColumn{name: "v", baseOID: 25}},
		{nativePGFilter("v", "text", "0.1", "postgresql", "numeric"), browseColumn{name: "v", numeric: true, baseOID: 701}},
		{nativePGFilter("v", "text", "1e999999999", "postgresql", "numeric"), browseColumn{name: "v", numeric: true, baseOID: 1700}},
		{nativePGFilter("v", "text", "κόσμος", "postgresql", "text"), browseColumn{name: "v", baseOID: 25, encodingUnsafe: true}},
		{nativePGFilter("v", "binary", "AP8=", "mysql", "blob"), browseColumn{name: "v", binary: true, baseOID: 17, encodingUnsafe: true}},
	} {
		request.Filters = []protocol.CatalogFilter{test.filter}
		if _, err := buildBrowsePlan(request, []browseColumn{test.column}); err == nil {
			t.Fatal("lossy or mismatched native operand reached query execution")
		}
	}
}

func TestPostgresNativeCellFiltersLive(t *testing.T) {
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
	if _, err = conn.Exec(ctx, `CREATE DOMAIN pg_temp.native_bytes AS bytea;
CREATE DOMAIN pg_temp.native_number AS numeric(40,20);
CREATE TEMP TABLE native_filters(id int PRIMARY KEY,n pg_temp.native_number,txt text,b pg_temp.native_bytes);
INSERT INTO native_filters VALUES
(1,9007199254740993.000000000000000001,'',decode('00ff','hex')),
(2,0,'NULL',decode('00ff','hex')),
(3,9007199254740993.000000000000000002,'é',decode('01','hex'))`); err != nil {
		t.Fatal("native filter fixture creation failed")
	}
	var schema string
	if conn.QueryRow(ctx, `SELECT nspname FROM pg_namespace WHERE oid=pg_my_temp_schema()`).Scan(&schema) != nil {
		t.Fatal("fixture schema unavailable")
	}
	leaf := func(f protocol.CatalogFilter) protocol.CatalogFilterExpression {
		return protocol.CatalogFilterExpression{Kind: "condition", Condition: &f}
	}
	expr := protocol.CatalogFilterExpression{Kind: "and", Children: []protocol.CatalogFilterExpression{
		{Kind: "or", Children: []protocol.CatalogFilterExpression{leaf(nativePGFilter("n", "text", "9007199254740993.000000000000000001", "mysql", "decimal(40,20)")), leaf(nativePGFilter("txt", "text", "NULL", "postgresql", "text"))}},
		leaf(nativePGFilter("b", "binary", "AP8=", "postgresql", "bytea")),
	}}
	request := protocol.CatalogRequest{Kind: "browse", Schema: schema, Object: "native_filters", ObjectKind: "table", FilterExpression: &expr}
	response := catalog(ctx, conn, protocol.Command{Type: "catalog", Catalog: &request})
	if response.Type != "query.result" || len(response.Rows) != 2 || *response.Rows[0][0] != "1" || *response.Rows[1][0] != "2" {
		t.Fatal("native grouped filters changed exact numeric or bytea-domain comparison")
	}
	rerun := execute(ctx, conn, protocol.Command{Type: "execute", SQL: response.SQL})
	if response.SQL == "" || rerun.Type != "query.result" || !reflect.DeepEqual(response.Rows, rerun.Rows) {
		t.Fatal("native filter source SQL changed returned rows")
	}
	request.FilterExpression = nil
	for _, f := range []protocol.CatalogFilter{nativePGFilter("txt", "text", "", "mysql", "varchar(10)"), nativePGFilter("n", "text", "9007199254740993.000000000000000001", "postgresql", "numeric(40,20)")} {
		request.Filters = []protocol.CatalogFilter{f}
		response = catalog(ctx, conn, protocol.Command{Type: "catalog", Catalog: &request})
		if response.Type != "query.result" || len(response.Rows) != 1 || *response.Rows[0][0] != "1" {
			t.Fatal("native exact/empty operand matched incorrectly")
		}
	}
	request.Filters = []protocol.CatalogFilter{nativePGFilter("b", "text", "AP8=", "postgresql", "text")}
	if r := catalog(ctx, conn, protocol.Command{Type: "catalog", Catalog: &request}); r.Type != "error" {
		t.Fatal("bytea-domain accepted a text operand")
	}
	var count int
	if conn.QueryRow(ctx, `SELECT count(*) FROM native_filters`).Scan(&count) != nil || count != 3 {
		t.Fatal("native browse mutated fixture")
	}
}

func TestPostgresNativeCellFiltersLiveEncodingBeforeAccess(t *testing.T) {
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
	schema, shadowSchema := "native_é_"+strconv.Itoa(int(conn.PgConn().PID())), "native_Ã©_"+strconv.Itoa(int(conn.PgConn().PID()))
	table, shadowTable, column, shadowColumn := "typed_é", "typed_Ã©", "b_é", "b_Ã©"
	target, shadow := pgx.Identifier{schema, table}.Sanitize(), pgx.Identifier{shadowSchema, shadowTable}.Sanitize()
	defer func() {
		conn.Exec(ctx, "SET client_encoding='UTF8'")
		conn.Exec(ctx, "DROP SCHEMA IF EXISTS "+pgx.Identifier{schema}.Sanitize()+" CASCADE")
		conn.Exec(ctx, "DROP SCHEMA IF EXISTS "+pgx.Identifier{shadowSchema}.Sanitize()+" CASCADE")
	}()
	for _, statement := range []string{
		"CREATE SCHEMA " + pgx.Identifier{schema}.Sanitize(), "CREATE SCHEMA " + pgx.Identifier{shadowSchema}.Sanitize(),
		"CREATE TABLE " + target + "(id INT PRIMARY KEY," + pgx.Identifier{column}.Sanitize() + " BYTEA,txt TEXT)",
		"CREATE TABLE " + shadow + "(id INT PRIMARY KEY," + pgx.Identifier{shadowColumn}.Sanitize() + " BYTEA,txt TEXT)",
		"INSERT INTO " + target + " VALUES(1,decode('00ff','hex'),'é 🌍')",
		"INSERT INTO " + shadow + " VALUES(2,decode('00ff','hex'),'wrong-target')",
	} {
		if _, err := conn.Exec(ctx, statement); err != nil {
			t.Fatal("Unicode encoding fixture creation failed")
		}
	}
	request := protocol.CatalogRequest{Kind: "browse", Schema: schema, Object: table, ObjectKind: "table", Filters: []protocol.CatalogFilter{nativePGFilter(column, "binary", "AP8=", "mysql", "blob")}}
	response := catalog(ctx, conn, protocol.Command{Type: "catalog", Catalog: &request})
	if response.Type != "query.result" || len(response.Rows) != 1 || *response.Rows[0][0] != "1" || *response.Rows[0][2] != "é 🌍" || response.Columns[1].Name != column {
		t.Fatal("UTF8 native binary browse changed Unicode target or text")
	}
	if _, err := conn.Exec(ctx, "SET client_encoding='LATIN1'"); err != nil {
		t.Fatal("fixture encoding change failed")
	}
	before := conn.PgConn().ParameterStatus("client_encoding")
	if before != "LATIN1" {
		t.Fatal("fixture encoding did not reach the server")
	}
	for _, missing := range []bool{false, true} {
		rejected := request
		if missing {
			rejected.Schema += "_missing"
		}
		sink := &nativePGEncodingSink{}
		raw, err := json.Marshal(map[string]any{"type": "catalog", "requestId": "native-pg-r", "sessionId": "native-pg-s", "queryId": "native-pg-q", "catalog": rejected})
		if err != nil {
			t.Fatal("native raw request fixture encoding failed")
		}
		command, err := protocol.ParseCommand(raw)
		if err != nil {
			t.Fatal("valid native raw catalog request rejected")
		}
		response := catalogWithSink(ctx, conn, command, sink)
		if response.Type != "error" || response.Category != "validation" || response.Message != nativePostgresEncodingMessage || len(response.Rows) != 0 || len(response.Columns) != 0 || response.SQL != "" || sink.calls != 0 {
			t.Fatal("unsafe binary native request reached access checks, target output, or shadow object")
		}
		if conn.PgConn().ParameterStatus("client_encoding") != before {
			t.Fatal("native rejection changed connection encoding")
		}
	}
}

type nativePGEncodingSink struct{ calls int }

func (s *nativePGEncodingSink) Begin(int, []protocol.Column) error { s.calls++; return nil }
func (s *nativePGEncodingSink) Row(int, []*string) error           { s.calls++; return nil }
func (s *nativePGEncodingSink) End(int, protocol.ResultSet) error  { s.calls++; return nil }
