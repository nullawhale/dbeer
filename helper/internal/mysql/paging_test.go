package mysql

import (
	"context"
	"fmt"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestMySQLBrowsePagingFiltersAndStableCompositeOrder(t *testing.T) {
	session := integrationSession(t)
	schema := integrationSettings(t).Database
	table := fmt.Sprintf("dbeer_page_%x", session.connectionID)
	quoted := QuoteIdentifier(schema) + "." + QuoteIdentifier(table)
	t.Cleanup(func() {
		session.Execute(context.Background(), protocol.Command{RequestID: "cleanup", SQL: "DROP TABLE IF EXISTS " + quoted})
	})
	run(t, session, "CREATE TABLE "+quoted+" (a INT,b INT,bucket INT,note VARCHAR(80),bytes VARBINARY(8),PRIMARY KEY(a,b)) ENGINE=InnoDB")
	run(t, session, "INSERT INTO "+quoted+" (a,b,bucket,note,bytes) WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<450) SELECT FLOOR((450-n)/3),MOD(450-n,3),1,IF(MOD(450-n,2)=0,NULL,'literal_%'' OR 1=1 --'),X'00FF80' FROM seq")
	request := protocol.CatalogRequest{Kind: "browse", Schema: schema, Object: table, ObjectKind: "table", Page: 1, Sort: []protocol.CatalogSort{{Column: "bucket", Direction: "desc"}}}
	response := catalogRequest(t, session, request)
	if len(response.Rows) != 200 || *response.Rows[0][0] != "66" || *response.Rows[0][1] != "2" {
		t.Fatal("second page ignored composite PK tie breakers")
	}
	request.Page = 2
	response = catalogRequest(t, session, request)
	if len(response.Rows) != 50 || *response.Rows[0][0] != "133" || *response.Rows[0][1] != "1" {
		t.Fatal("third page was not stable")
	}
	request.Page = 0
	for _, scenario := range []struct {
		filters []protocol.CatalogFilter
		count   int
	}{
		{[]protocol.CatalogFilter{{Column: "a", Operator: "gte", Value: text("148")}}, 6},
		{[]protocol.CatalogFilter{{Column: "a", Operator: "lt", Value: text("1")}}, 3},
		{[]protocol.CatalogFilter{{Column: "a", Operator: "lte", Value: text("0")}}, 3},
		{[]protocol.CatalogFilter{{Column: "a", Operator: "gt", Value: text("148")}}, 3},
		{[]protocol.CatalogFilter{{Column: "a", Operator: "eq", Value: text("149")}}, 3},
		{[]protocol.CatalogFilter{{Column: "a", Operator: "ne", Value: text("0")}, {Column: "a", Operator: "lt", Value: text("2")}}, 3},
		{[]protocol.CatalogFilter{{Column: "note", Operator: "eq", Value: text("' OR 1=1 --")}}, 0},
		{[]protocol.CatalogFilter{{Column: "note", Operator: "contains", Value: text("_%'")}}, 200},
		{[]protocol.CatalogFilter{{Column: "note", Operator: "isNull"}}, 200},
		{[]protocol.CatalogFilter{{Column: "note", Operator: "isNotNull"}}, 200},
		{[]protocol.CatalogFilter{{Column: "bytes", Operator: "eq", Value: text("AP+A")}}, 200},
	} {
		request.Filters = scenario.filters
		response = catalogRequest(t, session, request)
		if len(response.Rows) != scenario.count {
			t.Fatalf("filter %s returned %d rows", scenario.filters[0].Operator, len(response.Rows))
		}
	}
	request.Page, request.Filters = 1, []protocol.CatalogFilter{{Column: "note", Operator: "contains", Value: text("_%'")}}
	response = catalogRequest(t, session, request)
	if len(response.Rows) != 25 {
		t.Fatal("filter was not applied before server paging")
	}
	request.Page, request.Filters = 0, nil
	request.Sort = []protocol.CatalogSort{{Column: "a; DROP TABLE anything", Direction: "asc"}}
	invalid := session.Execute(context.Background(), protocol.Command{RequestID: "bad-sort", Catalog: &request})
	if invalid.Category != "validation" || !invalid.Connected {
		t.Fatal("unlisted sort column reached SQL")
	}
	request.Sort = nil
	request.Filters = []protocol.CatalogFilter{{Column: "note) OR 1=1 --", Operator: "eq", Value: text("x")}}
	invalid = session.Execute(context.Background(), protocol.Command{RequestID: "bad-filter", Catalog: &request})
	if invalid.Category != "validation" || !invalid.Connected {
		t.Fatal("unlisted filter column reached SQL")
	}
	run(t, session, "SELECT 1")
}
