package session_test

import (
	"context"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
)

// Prepared for final integration only. Reads use the isolated catalog service;
// fixture creation uses the observer and never borrows a SQL document session.
func TestPostgresTypedTableBrowsePagesFiltersAndMissingObject(t *testing.T) {
	h := newPGHarness(t)
	schema := fmt.Sprintf("dbeer_browse_%d", time.Now().UnixNano())
	table := "quoted \" table';--"
	qualified := pgx.Identifier{schema, table}.Sanitize()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	exec := func(sql string) {
		t.Helper()
		if _, err := h.observer.Exec(ctx, sql); err != nil {
			t.Fatal("cannot prepare browse fixture")
		}
	}
	exec("CREATE SCHEMA " + pgx.Identifier{schema}.Sanitize())
	t.Cleanup(func() {
		h.manager.Close()
		cleanup, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_, _ = h.observer.Exec(cleanup, "DROP SCHEMA IF EXISTS "+pgx.Identifier{schema}.Sanitize()+" CASCADE")
	})
	exec("CREATE TABLE " + qualified + " (id int, part int, n numeric(65,30), txt text, b bytea, nullable text, special text, rounded_n decimal(10,2) DEFAULT 1.23, PRIMARY KEY(id,part))")
	exec("INSERT INTO " + qualified + " (id,part,n,txt,b,nullable,special) SELECT 1,n,9007199254740993.000000000000000001,'needle%_'' OR 1=1 --',decode('00ff','hex'),NULL,CASE WHEN n=1 THEN '' WHEN n=2 THEN 'NULL' ELSE 'value' END FROM generate_series(1,201)n")
	exec("UPDATE " + qualified + " SET n=9007199254740993.000000000000000002 WHERE part=201")
	service, sql, source := h.connect(), h.connect(), h.connect()
	h.query(sql, "BEGIN", "transaction")
	assertSource := func(response protocol.Response) {
		t.Helper()
		if response.SQL == "" {
			t.Fatal("browse omitted its executed read statement")
		}
		rerun := h.query(source, response.SQL, "idle")
		if !reflect.DeepEqual(rerun.Rows, response.Rows) || !reflect.DeepEqual(rerun.Columns, response.Columns) {
			t.Fatal("rerunning source SQL changed the loaded browse page")
		}
	}
	request := protocol.CatalogRequest{Kind: "browse", Schema: schema, Object: table, ObjectKind: "table", Sort: []protocol.CatalogSort{{Column: "txt", Direction: "asc"}}}
	first := h.catalog(service, request)
	if first.Type != "query.result" || len(first.Rows) != 200 || catalogText(t, first, 0, "part") != "1" || catalogText(t, first, 199, "part") != "200" {
		t.Fatal("browse did not retain PK tie-break order and fixed page size")
	}
	assertSource(first)
	request.Page = 1
	second := h.catalog(service, request)
	if len(second.Rows) != 1 || catalogText(t, second, 0, "part") != "201" {
		t.Fatal("201st row did not belong to the next page")
	}
	assertSource(second)
	request.Page = 0
	cases := []struct {
		column, operator, value string
		count                   int
	}{
		{"part", "eq", "2", 1}, {"part", "ne", "2", 200}, {"part", "lt", "2", 1}, {"part", "lte", "2", 2}, {"part", "gt", "200", 1}, {"part", "gte", "200", 2},
		{"txt", "contains", "%_' OR 1=1 --", 200}, {"nullable", "isNull", "", 200}, {"txt", "isNotNull", "", 200},
		{"n", "eq", "9007199254740993.000000000000000001", 200}, {"n", "eq", "9007199254740993.000000000000000002", 1}, {"n", "gt", "9007199254740993.000000000000000001", 1},
		{"part", "eq", "2.000000000000000001", 0}, {"part", "lt", "2.000000000000000001", 2}, {"part", "gt", "200.999999999999999999", 1}, {"part", "eq", "9223372036854775808", 0},
		{"rounded_n", "lt", "1.234", 200}, {"rounded_n", "eq", "1.234", 0}, {"n", "eq", "0", 0}, {"txt", "eq", "x' OR 1=1 --", 0},
		{"special", "eq", "", 1}, {"special", "eq", "NULL", 1}, {"b", "eq", "AP8=", 200},
	}
	for _, item := range cases {
		value := item.value
		filter := protocol.CatalogFilter{Column: item.column, Operator: item.operator, Value: &value}
		if item.operator == "isNull" || item.operator == "isNotNull" {
			filter.Value = nil
		}
		request.Filters = []protocol.CatalogFilter{filter}
		response := h.catalog(service, request)
		assertSource(response)
		if response.Type != "query.result" || len(response.Rows) != item.count {
			t.Fatalf("typed browse %s/%s returned %s with %d rows; want query.result with %d rows", item.column, item.operator, response.Type, len(response.Rows), item.count)
		}
	}
	limit := "200"
	request.Filters = []protocol.CatalogFilter{{Column: "part", Operator: "lte", Value: &limit}}
	request.Page = 1
	if response := h.catalog(service, request); response.Type != "query.result" || len(response.Rows) != 0 {
		t.Fatal("an exactly full page must permit a legitimate empty following page")
	}
	request.Page = 0
	for _, value := range []string{"%%%", "A"} {
		request.Filters = []protocol.CatalogFilter{{Column: "b", Operator: "eq", Value: &value}}
		if response := h.catalog(service, request); response.Type != "error" || !response.Connected {
			t.Fatal("invalid binary value did not remain a known browse failure")
		}
	}
	exec("UPDATE " + qualified + " SET b=decode('','hex') WHERE part=1")
	empty := ""
	request.Filters = []protocol.CatalogFilter{{Column: "b", Operator: "eq", Value: &empty}}
	if response := h.catalog(service, request); response.Type != "query.result" || len(response.Rows) != 1 {
		t.Fatal("empty binary was treated as NULL or missing")
	}
	view := pgx.Identifier{schema, "readonly view"}.Sanitize()
	exec("CREATE VIEW " + view + " AS SELECT * FROM " + qualified)
	request.Object = "readonly view"
	request.ObjectKind = "view"
	request.Filters = nil
	if response := h.catalog(service, request); response.Type != "query.result" || !strings.Contains(response.DisplayNotice, "No stable page order") {
		t.Fatal("view browse omitted its unstable order notice")
	}
	request.Object = table
	request.ObjectKind = "table"
	exec("DROP VIEW " + view)
	exec("DROP TABLE " + qualified)
	if response := h.catalog(service, request); response.Type != "error" {
		t.Fatal("missing table became an empty successful page")
	}
	if response := h.query(sql, "SELECT 1", "transaction"); response.TransactionStatus != "transaction" {
		t.Fatal("service browsing changed the SQL document transaction")
	}
	h.query(sql, "ROLLBACK", "idle")
}
