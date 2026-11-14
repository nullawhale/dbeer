package mysql

import (
	"context"
	"fmt"
	"os"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/catalogmetadata"
	"dbeer/helper/internal/protocol"
)

func TestMySQLRelationshipDiscoveryCompositeSelfAndCrossSchemaVisibility(t *testing.T) {
	s := integrationSession(t)
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
	defer cancel()
	database := integrationSettings(t).Database
	first, second := os.Getenv("DBEER_R27_MYSQL_SOURCE_SCHEMA"), os.Getenv("DBEER_R27_MYSQL_TARGET_SCHEMA")
	crossSchema := first != "" && second != "" && first != second
	if !crossSchema {
		first, second = database, database
	}
	prefix := fmt.Sprintf("rel_%d_", time.Now().UnixNano())
	quote := func(value string) string { return "`" + strings.ReplaceAll(value, "`", "``") + "`" }
	table := func(schema, name string) string { return quote(schema) + "." + quote(prefix+name) }
	parent := table(first, "Parent")
	cleanup := []string{table(first, "Child"), parent, table(first, "Empty")}
	if crossSchema {
		cleanup = append([]string{table(second, "Child")}, cleanup...)
	}
	t.Cleanup(func() {
		for _, name := range cleanup {
			s.Execute(context.Background(), protocol.Command{SQL: "DROP TABLE IF EXISTS " + name})
		}
	})
	// MySQL permits the same constraint name in different schemas. The source
	// table remains part of the identity even when both names are identical.
	selfKey, childKey := quote(prefix+"self_fk"), quote(prefix+"same_fk")
	run(t, s, "CREATE TABLE "+parent+"(Tenant DECIMAL(40,20),`Key` VARBINARY(3),PrevTenant DECIMAL(40,20),PrevKey VARBINARY(3),PRIMARY KEY(Tenant,`Key`),CONSTRAINT "+selfKey+" FOREIGN KEY(PrevTenant,PrevKey) REFERENCES "+parent+"(Tenant,`Key`)) ENGINE=InnoDB")
	schemas := []string{first}
	if crossSchema {
		schemas = append(schemas, second)
	}
	for _, schema := range schemas {
		run(t, s, "CREATE TABLE "+table(schema, "Child")+"(Id INT PRIMARY KEY,TenantRef DECIMAL(40,20),KeyRef VARBINARY(3),CONSTRAINT "+childKey+" FOREIGN KEY(TenantRef,KeyRef) REFERENCES "+parent+"(Tenant,`Key`)) ENGINE=InnoDB")
	}
	run(t, s, "CREATE TABLE "+table(first, "Empty")+"(id INTEGER PRIMARY KEY) ENGINE=InnoDB")
	caseSensitive := run(t, s, "SELECT @@lower_case_table_names")
	separateCase := len(caseSensitive.Rows) == 1 && caseSensitive.Rows[0][0] != nil && *caseSensitive.Rows[0][0] == "0"
	canonicalName := func(name string) string {
		if len(caseSensitive.Rows) == 1 && caseSensitive.Rows[0][0] != nil && *caseSensitive.Rows[0][0] == "1" {
			return strings.ToLower(prefix + name)
		}
		return prefix + name
	}
	if separateCase {
		cleanup = append([]string{table(first, "child"), table(first, "parent")}, cleanup...)
		run(t, s, "CREATE TABLE "+table(first, "parent")+"(id INTEGER PRIMARY KEY) ENGINE=InnoDB")
		run(t, s, "CREATE TABLE "+table(first, "child")+"(id INTEGER PRIMARY KEY,parent_id INTEGER,CONSTRAINT "+quote(prefix+"lower_fk")+" FOREIGN KEY(parent_id) REFERENCES "+table(first, "parent")+"(id)) ENGINE=InnoDB")
	}
	run(t, s, "INSERT INTO "+parent+"(Tenant,`Key`) VALUES(9007199254740993.000000000000000001,X'00ff80'),(9007199254740993.000000000000000002,X'00ff80'),(9007199254740993.000000000000000001,X'00ff81')")
	run(t, s, "INSERT INTO "+table(second, "Child")+" VALUES(1,9007199254740993.000000000000000001,X'00ff80'),(2,9007199254740993.000000000000000002,X'00ff80'),(3,9007199254740993.000000000000000001,X'00ff81'),(4,NULL,NULL)")
	var store catalogmetadata.Store
	defer store.Close()
	pages := func(selector protocol.CatalogRequest) ([]map[string]string, string) {
		t.Helper()
		var rows []map[string]string
		c := protocol.Command{Type: "catalog.page", CatalogMetadata: &protocol.CatalogMetadataRequest{Selectors: []protocol.CatalogRequest{selector}, PageSize: 1}}
		capture, state := "", ""
		for {
			reply, err := store.Execute(ctx, s, c)
			if err != nil || !reply.Valid() {
				t.Fatal("MySQL relationship metadata capture failed")
			}
			page := reply.Collections[0]
			if selector.Kind == "referencingTables" && page.State != "unavailable" && page.State != "stale" {
				expectedName := selector.Object
				if len(caseSensitive.Rows) == 1 && caseSensitive.Rows[0][0] != nil && *caseSensitive.Rows[0][0] == "1" {
					expectedName = strings.ToLower(expectedName)
				}
				if page.Target == nil || page.Target.Schema != selector.Schema || page.Target.Name != expectedName {
					t.Fatal("canonical MySQL target proof is missing or changed")
				}
			}
			if capture != "" && capture != page.CaptureID {
				t.Fatal("MySQL relationship capture identity changed")
			}
			capture, state = page.CaptureID, page.State
			for _, row := range page.Rows {
				record := map[string]string{}
				for i, value := range row {
					if value != nil {
						record[page.Columns[i].Name] = *value
					}
				}
				rows = append(rows, record)
			}
			if selector.Kind == "foreignKeys" && len(page.Rows)%2 != 0 {
				t.Fatal("MySQL composite FK split across metadata pages")
			}
			c.CatalogMetadata.Cursor = page.NextCursor
			if page.NextCursor == "" {
				break
			}
		}
		if _, err := store.Execute(ctx, s, protocol.Command{Type: "catalog.close", CatalogMetadata: &protocol.CatalogMetadataRequest{CaptureIDs: []string{capture}}}); err != nil {
			t.Fatal("MySQL relationship capture did not close")
		}
		return rows, state
	}
	incoming := protocol.CatalogRequest{Kind: "referencingTables", Schema: first, Object: prefix + "Parent", ObjectKind: "table"}
	rows, state := pages(incoming)
	expected := []map[string]string{{"schema": first, "name": canonicalName("Child"), "kind": "table"}, {"schema": first, "name": canonicalName("Parent"), "kind": "table"}}
	if crossSchema {
		expected = append(expected, map[string]string{"schema": second, "name": canonicalName("Child"), "kind": "table"})
	}
	sort.Slice(expected, func(i, j int) bool {
		if expected[i]["schema"] != expected[j]["schema"] {
			return expected[i]["schema"] < expected[j]["schema"]
		}
		return expected[i]["name"] < expected[j]["name"]
	})
	if state != "complete" || !reflect.DeepEqual(rows, expected) {
		t.Fatal("MySQL incoming source identities, self-reference, or cross-schema constraints were conflated")
	}
	if separateCase {
		lower, lowerState := pages(protocol.CatalogRequest{Kind: "referencingTables", Schema: first, Object: prefix + "parent", ObjectKind: "table"})
		if lowerState != "complete" || len(lower) != 1 || lower[0]["name"] != prefix+"child" {
			t.Fatal("MySQL incoming target comparison merged case-distinct table identifiers")
		}
	}
	alias, aliasState := pages(protocol.CatalogRequest{Kind: "referencingTables", Schema: first, Object: strings.ToUpper(prefix + "Parent"), ObjectKind: "table"})
	if separateCase {
		if aliasState != "unavailable" || len(alias) != 0 {
			t.Fatal("a missing case-sensitive target was silently retargeted")
		}
	} else if aliasState != "complete" || !reflect.DeepEqual(alias, expected) {
		t.Fatal("a valid case-insensitive target alias lost its canonical proof")
	}
	legacy := s.Execute(ctx, protocol.Command{Type: "catalog", Catalog: &incoming})
	if legacy.Type != "query.result" || len(legacy.Rows) != len(expected) {
		t.Fatal("MySQL legacy incoming catalog disagreed with paged discovery")
	}
	for _, source := range rows {
		keys, keyState := pages(protocol.CatalogRequest{Kind: "foreignKeys", Schema: source["schema"], Object: source["name"], ObjectKind: "table"})
		if keyState != "complete" || len(keys) != 2 || keys[0]["targetSchema"] != first || keys[0]["targetTable"] != canonicalName("Parent") || keys[0]["targetColumn"] != "Tenant" || keys[1]["targetColumn"] != "Key" {
			t.Fatal("MySQL source-scoped composite mapping was incomplete")
		}
		if source["name"] == canonicalName("Child") && keys[0]["name"] != prefix+"same_fk" {
			t.Fatal("MySQL cross-schema same-name constraint was lost")
		}
	}
	exact, binary := "9007199254740993.000000000000000001", "AP+A"
	browse := protocol.CatalogRequest{Kind: "browse", Schema: second, Object: prefix + "Child", ObjectKind: "table", Filters: []protocol.CatalogFilter{{Column: "TenantRef", Operator: "eq", Value: &exact}, {Column: "KeyRef", Operator: "eq", Value: &binary}}}
	filtered := s.Execute(ctx, protocol.Command{Type: "catalog", Catalog: &browse})
	if filtered.Type != "query.result" || len(filtered.Rows) != 1 || *filtered.Rows[0][0] != "1" {
		t.Fatal("MySQL parent-to-child filters changed exact numeric or binary values")
	}
	empty, emptyState := pages(protocol.CatalogRequest{Kind: "referencingTables", Schema: first, Object: prefix + "Empty", ObjectKind: "table"})
	if emptyState != "complete" || len(empty) != 0 {
		t.Fatal("MySQL unreferenced target did not produce a complete empty observation")
	}
	for _, selector := range []protocol.CatalogRequest{{Kind: "referencingTables", Schema: "mysql", Object: "user", ObjectKind: "table"}, {Kind: "referencingTables", Schema: first, Object: prefix + "Missing", ObjectKind: "table"}} {
		_, denied := pages(selector)
		if denied != "unavailable" {
			t.Fatal("MySQL denied or missing target became complete empty incoming metadata")
		}
	}
}
