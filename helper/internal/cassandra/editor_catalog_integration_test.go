package cassandra_test

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/sqlcomplete"
)

func TestCassandraLiveEditorColumnTypes(t *testing.T) {
	connection := liveConnection(t)
	s := liveOpen(t, connection)
	keyspace := `"` + strings.ReplaceAll(connection.Database, `"`, `""`) + `"`
	const tableName = "live_editor_types"
	const typeName = "live_editor_record"
	fixturesRemoved := false
	t.Cleanup(func() {
		if fixturesRemoved {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		for _, statement := range []string{"DROP TABLE IF EXISTS " + keyspace + "." + tableName, "DROP TYPE IF EXISTS " + keyspace + "." + typeName} {
			_ = s.Execute(ctx, protocol.Command{Type: "execute", RequestID: "editor-type-cleanup", SQL: statement})
		}
	})
	liveSQL(t, s, "CREATE TYPE "+keyspace+"."+typeName+" (label text, count int)")
	liveSQL(t, s, "CREATE TABLE "+keyspace+"."+tableName+" (id int PRIMARY KEY, amount decimal, tags frozen<list<text>>, properties map<text,bigint>, details frozen<"+typeName+">)")
	metadata := liveSQL(t, s, "SELECT type FROM system_schema.columns WHERE keyspace_name = '"+strings.ReplaceAll(connection.Database, "'", "''")+"' AND table_name = '"+tableName+"' AND column_name = 'details'")
	storedDetailsType := liveValue(t, metadata, "type")
	if storedDetailsType == nil {
		t.Fatal("native metadata omitted the fixture's user-defined type")
	}

	relations := map[string]sqlcomplete.Relation{}
	for page := 0; page < 100; page++ {
		response := liveCatalog(t, s, protocol.CatalogRequest{Kind: "completion", Schema: connection.Database, Page: page})
		if response.Type != "query.result" {
			t.Fatalf("Cassandra editor catalog failed: category=%s", response.Category)
		}
		for _, row := range response.Rows {
			if len(row) != len(response.Columns) {
				t.Fatal("completion column and value counts differ")
			}
			record := map[string]string{}
			for i, column := range response.Columns {
				if row[i] != nil {
					record[column.Name] = *row[i]
				}
			}
			if record["schema"] != connection.Database || (record["name"] != tableName && record["name"] != typeName) {
				continue
			}
			if _, duplicate := relations[record["name"]]; duplicate {
				t.Fatal("completion repeated an editor fixture object")
			}
			relation := sqlcomplete.Relation{Schema: record["schema"], Name: record["name"], Kind: record["kind"]}
			if json.Unmarshal([]byte(record["columns"]), &relation.Columns) != nil || json.Unmarshal([]byte(record["columnTypes"]), &relation.ColumnTypes) != nil {
				t.Fatal("completion lost structured column types")
			}
			if len(relation.Columns) != len(relation.ColumnTypes) {
				t.Fatal("completion types do not match available columns")
			}
			for _, name := range relation.Columns {
				if relation.ColumnTypes[name] == "" {
					t.Fatal("completion omitted a native column type")
				}
			}
			relations[relation.Name] = relation
		}
		if len(response.Rows) < 200 {
			break
		}
	}
	table, ok := relations[tableName]
	if !ok || table.Kind != "table" || len(table.Columns) != 5 {
		t.Fatal("completion omitted the editor table fixture")
	}
	for name, expected := range map[string]string{"id": "int", "amount": "decimal", "tags": "frozen<list<text>>", "properties": "map<text,bigint>"} {
		if strings.ReplaceAll(table.ColumnTypes[name], " ", "") != expected {
			t.Fatalf("completion changed the native type for column %s", name)
		}
	}
	detailsType := strings.NewReplacer(" ", "", `"`, "").Replace(table.ColumnTypes["details"])
	if table.ColumnTypes["details"] != *storedDetailsType || (detailsType != "frozen<"+typeName+">" && detailsType != "frozen<"+connection.Database+"."+typeName+">") {
		t.Fatal("completion lost the frozen user-defined type identity")
	}
	udt, ok := relations[typeName]
	if !ok || udt.Kind != "type" || !reflect.DeepEqual(udt.ColumnTypes, map[string]string{"label": "text", "count": "int"}) {
		t.Fatal("completion lost native user-defined field types")
	}
	liveSQL(t, s, "DROP TABLE "+keyspace+"."+tableName)
	liveSQL(t, s, "DROP TYPE "+keyspace+"."+typeName)
	fixturesRemoved = true
	s.Close()
	// Editor information must use only its cached metadata after the fixture and
	// the live session no longer exist.
	source := "SELECT amount FROM " + keyspace + "." + tableName
	analysis := sqlcomplete.AnalyzeEditor(source, strings.Index(source, "amount")+1, sqlcomplete.Context{Engine: "cassandra", Keyspace: connection.Database, Catalog: []sqlcomplete.Relation{table}})
	if len(analysis.Definitions) != 1 || !strings.Contains(analysis.Definitions[0].Detail, "decimal") {
		t.Fatal("live Cassandra column type did not reach editor information")
	}
}
