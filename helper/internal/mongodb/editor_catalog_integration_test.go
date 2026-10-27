package mongodb

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/sqlcomplete"
	"go.mongodb.org/mongo-driver/v2/bson"
)

func TestMongoDBIntegrationCompletionTypesAndOfflineEditorInformation(t *testing.T) {
	s := integrationSession(t)
	ctx := context.Background()
	database := s.client.Database(s.database)
	docs := []any{
		bson.D{{Key: "_id", Value: int32(1)}, {Key: "mixed", Value: int32(7)},
			{Key: "nested", Value: bson.D{{Key: "amount", Value: int64(9007199254740993)}}}, {Key: "nullable", Value: nil}},
		bson.D{{Key: "_id", Value: int32(2)}, {Key: "mixed", Value: "seven"},
			{Key: "nested", Value: bson.D{{Key: "amount", Value: "exact text"}}}},
	}
	if _, err := database.Collection("items").InsertMany(ctx, docs); err != nil {
		t.Fatal("completion fixture insert failed")
	}
	if err := database.CreateView(ctx, "items_view", "items", bson.A{}); err != nil {
		t.Fatal("completion view fixture failed")
	}
	if err := database.CreateCollection(ctx, "empty"); err != nil {
		t.Fatal("completion empty collection fixture failed")
	}
	metadata := s.Execute(ctx, protocol.Command{Type: "catalog", Catalog: &protocol.CatalogRequest{Kind: "completion", Schema: s.database}})
	if metadata.Type != "query.result" || len(metadata.ResultSets) != 1 || len(metadata.Rows) != 3 || len(metadata.Columns) != 7 || metadata.Columns[6].Name != "columnTypes" {
		t.Fatal("completion did not return the collection/view native type contract")
	}
	if !strings.Contains(metadata.ResultSets[0].DisplayNotice, "sampled") {
		t.Fatal("completion lost the sampled metadata notice")
	}
	wantTypes := map[string]string{"_id": "32-bit integer", "mixed": "32-bit integer | string", "nested": "embedded document", "nested.amount": "64-bit integer | string", "nullable": "null"}
	var catalog []sqlcomplete.Relation
	seen := map[string]bool{}
	for _, row := range metadata.Rows {
		if len(row) != 7 || row[0] == nil || row[1] == nil || row[2] == nil || row[3] == nil || row[6] == nil {
			t.Fatal("completion metadata has missing typed fields")
		}
		name := *row[0]
		if seen[name] || *row[2] != s.database {
			t.Fatal("completion repeated or misrouted a collection")
		}
		seen[name] = true
		var columns []string
		var columnTypes map[string]string
		if json.Unmarshal([]byte(*row[3]), &columns) != nil || json.Unmarshal([]byte(*row[6]), &columnTypes) != nil {
			t.Fatal("completion columns or type map are invalid JSON")
		}
		if len(columns) != len(columnTypes) {
			t.Fatal("completion columns and sampled type keys diverged")
		}
		for _, column := range columns {
			if _, exists := columnTypes[column]; !exists {
				t.Fatal("completion type is not attached to its exact field path")
			}
		}
		switch name {
		case "empty":
			if *row[1] != "table" || len(columns) != 0 || len(columnTypes) != 0 {
				t.Fatal("empty collection invented sampled fields or types")
			}
		case "items", "items_view":
			if !reflect.DeepEqual(columnTypes, wantTypes) || (*row[1] == "view") != (name == "items_view") {
				t.Fatal("collection/view completion lost observed BSON unions, paths or kind")
			}
		default:
			t.Fatal("completion included an unexpected namespace")
		}
		catalog = append(catalog, sqlcomplete.Relation{Schema: *row[2], Name: name, Kind: *row[1], Columns: columns, ColumnTypes: columnTypes})
	}
	// Remove the live fixture and disconnect before requesting editor information.
	// Cached sample descriptions must not need another database read.
	if err := database.Drop(ctx); err != nil {
		t.Fatal("completion fixture cleanup failed")
	}
	s.Close()
	source := `{"collection":"items","find":{"nested.amount":1},"sort":{"nested.amount":1}}`
	analysis := sqlcomplete.AnalyzeEditor(source, strings.Index(source, "nested.amount")+1, sqlcomplete.Context{Engine: "mongodb", Catalog: catalog})
	if len(analysis.Definitions) != 1 || len(analysis.References) != 2 {
		t.Fatal("offline editor information lost sampled field routing or usages")
	}
	definition := analysis.Definitions[0]
	if definition.Schema != s.database || definition.Name != "items" || !strings.Contains(definition.Detail, "64-bit integer | string") || !strings.Contains(definition.Detail, "Samples are not a schema") {
		t.Fatal("offline editor information lost native union types or sample warning")
	}
}
