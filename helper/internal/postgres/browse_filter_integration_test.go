package postgres

import (
	"context"
	"os"
	"reflect"
	"testing"

	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
)

func TestPostgresBrowseNestedFiltersLive(t *testing.T) {
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
	// Temporary metadata and data are scoped to this owned connection.
	if _, err = conn.Exec(ctx, `CREATE TEMP TABLE browse_tree(id int PRIMARY KEY, n numeric(40,20), txt text, nullable text, b bytea);
INSERT INTO browse_tree VALUES
(1,9007199254740993.000000000000000001,'',NULL,decode('00ff','hex')),
(2,0,'NULL','present',decode('00ff','hex')),
(3,9007199254740993.000000000000000000,'x',NULL,NULL),
(4,9007199254740993.000000000000000002,'x','present',NULL),
(5,9007199254740993.000000000000000002,'x',NULL,NULL)`); err != nil {
		t.Fatal("fixture creation failed")
	}
	var schema string
	if conn.QueryRow(ctx, `SELECT nspname FROM pg_namespace WHERE oid=pg_my_temp_schema()`).Scan(&schema) != nil {
		t.Fatal("fixture schema unavailable")
	}
	exact, text, binary := "9007199254740993.000000000000000001", "NULL", "AP8="
	leaf := func(column, operator string, value *string) protocol.CatalogFilterExpression {
		return protocol.CatalogFilterExpression{Kind: "condition", Condition: &protocol.CatalogFilter{Column: column, Operator: operator, Value: value}}
	}
	expression := protocol.CatalogFilterExpression{Kind: "and", Children: []protocol.CatalogFilterExpression{
		{Kind: "or", Children: []protocol.CatalogFilterExpression{leaf("n", "gte", &exact), leaf("txt", "eq", &text)}},
		{Kind: "or", Children: []protocol.CatalogFilterExpression{leaf("nullable", "isNull", nil), leaf("b", "eq", &binary)}},
	}}
	request := protocol.CatalogRequest{Kind: "browse", Schema: schema, Object: "browse_tree", ObjectKind: "table", FilterExpression: &expression,
		Sort: []protocol.CatalogSort{{Column: "n", Direction: "desc"}, {Column: "id", Direction: "desc"}}}
	response := catalog(ctx, conn, protocol.Command{Type: "catalog", Catalog: &request})
	if response.Type != "query.result" || len(response.Rows) != 3 || *response.Rows[0][0] != "5" || *response.Rows[1][0] != "1" || *response.Rows[2][0] != "2" {
		t.Fatal("nested browse changed exact comparisons, grouping, or compound sort")
	}
	rerun := execute(ctx, conn, protocol.Command{Type: "execute", SQL: response.SQL})
	if response.SQL == "" || rerun.Type != "query.result" || !reflect.DeepEqual(rerun.Rows, response.Rows) {
		t.Fatal("browse source changed loaded rows")
	}
	request.Page = 1
	if next := catalog(ctx, conn, protocol.Command{Type: "catalog", Catalog: &request}); next.Type != "query.result" || len(next.Rows) != 0 {
		t.Fatal("nested browse page bounds changed")
	}
}
