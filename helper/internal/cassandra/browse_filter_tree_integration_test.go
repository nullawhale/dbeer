package cassandra_test

import (
	"fmt"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestCassandraLiveBrowseFilterTree(t *testing.T) {
	s := liveOpen(t, liveConnection(t))
	liveSQL(t, s, "CREATE TABLE dbeer.live_filter_tree (bucket int,id int,revision int,value text,PRIMARY KEY(bucket,id,revision))")
	for start := 0; start < 205; start += 100 {
		var sql strings.Builder
		sql.WriteString("BEGIN UNLOGGED BATCH ")
		for i := start; i < start+100 && i < 205; i++ {
			fmt.Fprintf(&sql, "INSERT INTO dbeer.live_filter_tree (bucket,id,revision,value) VALUES (1,%d,0,'exact');", i)
		}
		sql.WriteString("APPLY BATCH;")
		liveSQL(t, s, sql.String())
	}
	condition := func(column, operator, value string) protocol.CatalogFilterExpression {
		return protocol.CatalogFilterExpression{Kind: "condition", Condition: &protocol.CatalogFilter{Column: column, Operator: operator, Value: &value}}
	}
	tree := protocol.CatalogFilterExpression{Kind: "and", Children: []protocol.CatalogFilterExpression{
		condition("bucket", "eq", "1"),
		{Kind: "and", Children: []protocol.CatalogFilterExpression{condition("id", "gte", "200")}},
	}}
	request := protocol.CatalogRequest{Kind: "browse", Schema: "dbeer", Object: "live_filter_tree", ObjectKind: "table", FilterExpression: &tree,
		Sort: []protocol.CatalogSort{{Column: "id", Direction: "desc"}, {Column: "revision", Direction: "desc"}}}
	filtered := liveCatalog(t, s, request)
	if filtered.Type != "query.result" || len(filtered.Rows) != 5 || filtered.NextCursor != "" || !strings.HasSuffix(filtered.SQL, `ORDER BY "id" DESC, "revision" DESC`) {
		t.Fatalf("nested AND browse failed: category=%s rows=%d", filtered.Category, len(filtered.Rows))
	}
	if got := liveSQL(t, s, filtered.SQL); len(got.Rows) != len(filtered.Rows) {
		t.Fatal("nested AND source CQL changed the filtered result")
	}
	tree.Kind = "or"
	if rejected := liveCatalog(t, s, request); rejected.Category != "unsupported" || len(rejected.Rows) != 0 {
		t.Fatal("Cassandra OR group was not rejected")
	}
	tree.Kind = "and"
	tree.Children[1].Children[0] = condition("id", "gte", "0")
	request.Sort = nil
	first := liveCatalog(t, s, request)
	if first.Type != "query.result" || len(first.Rows) != 200 || first.NextCursor == "" {
		t.Fatal("nested AND browse did not retain sequential pagination")
	}
	request.Cursor = first.NextCursor
	tree.Children[1].Children[0] = condition("id", "gte", "1")
	if changed := liveCatalog(t, s, request); changed.Category != "cursor" {
		t.Fatal("changed AND predicate reused an old Cassandra cursor")
	}
}
