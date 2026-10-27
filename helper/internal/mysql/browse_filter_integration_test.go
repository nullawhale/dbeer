package mysql

import (
	"context"
	"fmt"
	"reflect"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestMySQLBrowseNestedFiltersLive(t *testing.T) {
	session := integrationSession(t)
	schema := integrationSettings(t).Database
	name := fmt.Sprintf("dbeer_browse_tree_%x", session.connectionID)
	qualified := QuoteIdentifier(schema) + "." + QuoteIdentifier(name)
	t.Cleanup(func() {
		session.Execute(context.Background(), protocol.Command{SQL: "DROP TABLE IF EXISTS " + qualified})
	})
	run(t, session, "CREATE TABLE "+qualified+" (id int PRIMARY KEY, n decimal(40,20), txt text, nullable text, b varbinary(20)) ENGINE=InnoDB")
	run(t, session, "INSERT INTO "+qualified+" VALUES (1,9007199254740993.000000000000000001,'',NULL,UNHEX('00ff')),(2,0,'NULL','present',UNHEX('00ff')),(3,9007199254740993.000000000000000000,'x',NULL,NULL),(4,9007199254740993.000000000000000002,'x','present',NULL),(5,9007199254740993.000000000000000002,'x',NULL,NULL)")
	exact, text, binary := "9007199254740993.000000000000000001", "NULL", "AP8="
	leaf := func(column, operator string, value *string) protocol.CatalogFilterExpression {
		return protocol.CatalogFilterExpression{Kind: "condition", Condition: &protocol.CatalogFilter{Column: column, Operator: operator, Value: value}}
	}
	expression := protocol.CatalogFilterExpression{Kind: "and", Children: []protocol.CatalogFilterExpression{
		{Kind: "or", Children: []protocol.CatalogFilterExpression{leaf("n", "gte", &exact), leaf("txt", "eq", &text)}},
		{Kind: "or", Children: []protocol.CatalogFilterExpression{leaf("nullable", "isNull", nil), leaf("b", "eq", &binary)}},
	}}
	request := protocol.CatalogRequest{Kind: "browse", Schema: schema, Object: name, ObjectKind: "table", FilterExpression: &expression,
		Sort: []protocol.CatalogSort{{Column: "n", Direction: "desc"}, {Column: "id", Direction: "desc"}}}
	response := catalogRequest(t, session, request)
	if len(response.Rows) != 3 || *response.Rows[0][0] != "5" || *response.Rows[1][0] != "1" || *response.Rows[2][0] != "2" {
		t.Fatal("nested browse changed exact comparisons, grouping, or compound sort")
	}
	rerun := run(t, session, response.SQL)
	if response.SQL == "" || !reflect.DeepEqual(rerun.Rows, response.Rows) {
		t.Fatal("browse source changed loaded rows")
	}
	request.Page = 1
	if next := catalogRequest(t, session, request); len(next.Rows) != 0 {
		t.Fatal("nested browse page bounds changed")
	}
}

func TestMySQLBrowseRepeatedUIFixtureRetainsOwnedMetadata(t *testing.T) {
	session := integrationSession(t)
	schema := integrationSettings(t).Database
	name := fmt.Sprintf("dbeer_browse_ui_metadata_%x", session.connectionID)
	qualified := QuoteIdentifier(schema) + "." + QuoteIdentifier(name)
	t.Cleanup(func() {
		session.Execute(context.Background(), protocol.Command{SQL: "DROP TABLE IF EXISTS " + qualified})
	})
	run(t, session, "CREATE TABLE "+qualified+" (`tenant` int, `rank` int, `id` int PRIMARY KEY, `label` text, `nullable` text) ENGINE=InnoDB")
	run(t, session, "INSERT INTO "+qualified+" VALUES (1,1,1,'alpha',NULL),(1,1,2,'beta',''),(1,2,3,'alpha','NULL'),(1,2,4,'beta','v'),(1,3,5,'alpha','v'),(2,1,6,'gamma',NULL),(2,2,7,'alpha',''),(2,3,8,'beta','NULL')")
	leaf := func(column, operation, value string) protocol.CatalogFilterExpression {
		return protocol.CatalogFilterExpression{Kind: "condition", Condition: &protocol.CatalogFilter{Column: column, Operator: operation, Value: &value}}
	}
	for iteration := 0; iteration < 64; iteration++ {
		plain := protocol.CatalogRequest{Kind: "browse", Schema: schema, Object: name, ObjectKind: "table"}
		if rows := catalogRequest(t, session, plain).Rows; len(rows) != 8 {
			t.Fatal("plain fixture browsing changed after metadata buffer reuse")
		}
		for _, limit := range []string{"2", "3"} {
			expression := protocol.CatalogFilterExpression{Kind: "and", Children: []protocol.CatalogFilterExpression{
				leaf("tenant", "eq", "1"),
				{Kind: "or", Children: []protocol.CatalogFilterExpression{leaf("label", "eq", "alpha"), leaf("rank", "gte", limit)}},
			}}
			request := plain
			request.FilterExpression = &expression
			request.Sort = []protocol.CatalogSort{{Column: "rank", Direction: "desc"}, {Column: "id", Direction: "asc"}}
			response := catalogRequest(t, session, request)
			var ids []string
			for _, row := range response.Rows {
				if len(row) < 3 || row[2] == nil {
					t.Fatal("browse metadata no longer identifies the source id")
				}
				ids = append(ids, *row[2])
			}
			want := []string{"5", "3", "4", "1"}
			if limit == "3" {
				want = []string{"5", "3", "1"}
			}
			if !reflect.DeepEqual(ids, want) {
				t.Fatalf("repeated grouped browse changed rows after metadata reuse (iteration %d)", iteration)
			}
			if rerun := run(t, session, response.SQL); !reflect.DeepEqual(rerun.Rows, response.Rows) {
				t.Fatal("source replay changed rows after metadata reuse")
			}
		}
	}
}
