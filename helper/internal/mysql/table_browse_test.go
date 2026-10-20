package mysql

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

// Prepared for final integration; the existing runner supplies only disposable databases.
func TestMySQLTypedTableBrowsePagesFiltersAndUnstableViewOrder(t *testing.T) {
	service := integrationSession(t)
	sql := integrationSession(t)
	schema := integrationSettings(t).Database
	name := fmt.Sprintf("dbeer_browse_%x_`quoted", service.connectionID)
	view := name + "_view"
	qualified := QuoteIdentifier(schema) + "." + QuoteIdentifier(name)
	viewName := QuoteIdentifier(schema) + "." + QuoteIdentifier(view)
	t.Cleanup(func() {
		service.Execute(context.Background(), protocol.Command{RequestID: "cleanup-view", SQL: "DROP VIEW IF EXISTS " + viewName})
		service.Execute(context.Background(), protocol.Command{RequestID: "cleanup-table", SQL: "DROP TABLE IF EXISTS " + qualified})
	})
	run(t, service, "CREATE TABLE "+qualified+" (id int, part int, n decimal(65,30), txt text, b varbinary(20), nullable text, special text, rounded_n decimal(10,2) DEFAULT 1.23, PRIMARY KEY(id,part)) ENGINE=InnoDB")
	run(t, service, "INSERT INTO "+qualified+" (id,part,n,txt,b,nullable,special) WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<201) SELECT 1,n,9007199254740993.000000000000000001,'needle%_'' OR 1=1 --',UNHEX('00ff'),NULL,CASE WHEN n=1 THEN '' WHEN n=2 THEN 'NULL' ELSE 'value' END FROM seq")
	run(t, service, "UPDATE "+qualified+" SET n=9007199254740993.000000000000000002 WHERE part=201")
	run(t, sql, "START TRANSACTION READ ONLY")
	request := protocol.CatalogRequest{Kind: "browse", Schema: schema, Object: name, ObjectKind: "table", Sort: []protocol.CatalogSort{{Column: "txt", Direction: "asc"}}}
	first := catalogRequest(t, service, request)
	if len(first.Rows) != 200 || *first.Rows[0][1] != "1" || *first.Rows[199][1] != "200" {
		t.Fatal("browse did not retain PK tie-break order and fixed page size")
	}
	request.Page = 1
	second := catalogRequest(t, service, request)
	if len(second.Rows) != 1 || *second.Rows[0][1] != "201" {
		t.Fatal("201st row did not belong to the next page")
	}
	request.Page = 0
	cases := []struct {
		column, operator, value string
		count                   int
	}{
		{"part", "eq", "2", 1}, {"part", "ne", "2", 200}, {"part", "lt", "2", 1}, {"part", "lte", "2", 2}, {"part", "gt", "200", 1}, {"part", "gte", "200", 2},
		{"txt", "contains", "%_' OR 1=1 --", 200}, {"nullable", "isNull", "", 200}, {"txt", "isNotNull", "", 200},
		{"n", "eq", "9007199254740993.000000000000000001", 200}, {"n", "eq", "9007199254740993.000000000000000002", 1}, {"n", "gt", "9007199254740993.000000000000000001", 1}, {"part", "eq", "2.000000000000000001", 0}, {"rounded_n", "lt", "1.234", 200}, {"rounded_n", "eq", "1.234", 0}, {"n", "eq", "0", 0}, {"txt", "eq", "x' OR 1=1 --", 0},
		{"special", "eq", "", 1}, {"special", "eq", "NULL", 1}, {"b", "eq", "AP8=", 200},
	}
	for _, item := range cases {
		value := item.value
		filter := protocol.CatalogFilter{Column: item.column, Operator: item.operator, Value: &value}
		if item.operator == "isNull" || item.operator == "isNotNull" {
			filter.Value = nil
		}
		request.Filters = []protocol.CatalogFilter{filter}
		if response := catalogRequest(t, service, request); len(response.Rows) != item.count {
			t.Fatalf("typed browse operator %s failed", item.operator)
		}
	}
	limit := "200"
	request.Filters = []protocol.CatalogFilter{{Column: "part", Operator: "lte", Value: &limit}}
	request.Page = 1
	if response := catalogRequest(t, service, request); len(response.Rows) != 0 {
		t.Fatal("exactly full page did not permit empty following page")
	}
	request.Page = 0
	for _, value := range []string{"%%%", "A"} {
		request.Filters = []protocol.CatalogFilter{{Column: "b", Operator: "eq", Value: &value}}
		response := service.Execute(context.Background(), protocol.Command{Type: "catalog", RequestID: "binary-invalid", SessionID: "browse", QueryID: "binary-q", Catalog: &request})
		if response.Type != "error" || !response.Connected {
			t.Fatal("invalid binary did not remain a known failure")
		}
	}
	run(t, service, "UPDATE "+qualified+" SET b=UNHEX('') WHERE part=1")
	empty := ""
	request.Filters = []protocol.CatalogFilter{{Column: "b", Operator: "eq", Value: &empty}}
	if response := catalogRequest(t, service, request); len(response.Rows) != 1 {
		t.Fatal("empty binary was treated as NULL or missing")
	}
	run(t, service, "CREATE VIEW "+viewName+" AS SELECT * FROM "+qualified)
	request.Object = view
	request.ObjectKind = "view"
	request.Filters = nil
	if response := catalogRequest(t, service, request); !strings.Contains(response.DisplayNotice, "No stable page order") {
		t.Fatal("view browse omitted unstable order notice")
	}
	if response := run(t, sql, "SELECT 1"); response.TransactionStatus != "transaction" {
		t.Fatal("service browse changed SQL document transaction")
	}
	run(t, sql, "ROLLBACK")
}
