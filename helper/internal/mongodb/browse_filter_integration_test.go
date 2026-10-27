package mongodb

import (
	"context"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
	"go.mongodb.org/mongo-driver/v2/bson"
)

func TestMongoDBBrowseNestedFiltersLiveAndCursorBinding(t *testing.T) {
	session := integrationSession(t)
	ctx := context.Background()
	var docs []any
	for i := 0; i < 205; i++ {
		doc := bson.D{{Key: "_id", Value: int32(i)}, {Key: "n", Value: int64(9007199254740993)}, {Key: "group", Value: int32(i % 2)}}
		if i%2 == 0 {
			doc = append(doc, bson.E{Key: "nullable", Value: nil})
		}
		docs = append(docs, doc)
	}
	if _, err := session.client.Database(session.database).Collection("items").InsertMany(ctx, docs); err != nil {
		t.Fatal("fixture creation failed")
	}
	exact, empty := `{"$numberLong":"9007199254740993"}`, `""`
	leaf := func(column, operator string, value *string) protocol.CatalogFilterExpression {
		return protocol.CatalogFilterExpression{Kind: "condition", Condition: &protocol.CatalogFilter{Column: column, Operator: operator, Value: value}}
	}
	expression := protocol.CatalogFilterExpression{Kind: "and", Children: []protocol.CatalogFilterExpression{
		leaf("n", "eq", &exact),
		{Kind: "or", Children: []protocol.CatalogFilterExpression{leaf("nullable", "isNull", nil), leaf("nullable", "ne", &empty)}},
	}}
	request := protocol.CatalogRequest{Kind: "browse", Schema: session.database, Object: "items", ObjectKind: "table", FilterExpression: &expression,
		Sort: []protocol.CatalogSort{{Column: "group", Direction: "asc"}, {Column: "_id", Direction: "desc"}}}
	first := session.Execute(ctx, protocol.Command{Type: "catalog", Catalog: &request})
	if first.Type != "query.result" || len(first.Rows) != 200 || first.NextCursor == "" || !strings.Contains(*first.Rows[0][0], `"_id":{"$numberInt":"204"}`) {
		t.Fatal("nested browse lost exact values, missing-field semantics, sort, or cursor")
	}
	request.Cursor = first.NextCursor
	second := session.Execute(ctx, protocol.Command{Type: "catalog", Catalog: &request})
	if second.Type != "query.result" || len(second.Rows) != 5 || second.NextCursor != "" {
		t.Fatal("nested browse cursor skipped or repeated documents")
	}
	request.Cursor = ""
	fresh := session.Execute(ctx, protocol.Command{Type: "catalog", Catalog: &request})
	if fresh.Type != "query.result" || fresh.NextCursor == "" {
		t.Fatal("fresh browse cursor unavailable")
	}
	request.Cursor = fresh.NextCursor
	changed := protocol.CatalogFilterExpression{Kind: "condition", Condition: &protocol.CatalogFilter{Column: "nullable", Operator: "isNull"}}
	request.FilterExpression = &changed
	if rejected := session.Execute(ctx, protocol.Command{Type: "catalog", Catalog: &request}); rejected.Type != "error" || rejected.Category != "cursor" {
		t.Fatal("cursor accepted for changed filter tree")
	}
	request.Cursor = ""
	nulls := session.Execute(ctx, protocol.Command{Type: "catalog", Catalog: &request})
	if nulls.Type != "query.result" || len(nulls.Rows) != 103 {
		t.Fatal("explicit BSON null matched missing fields")
	}
}
