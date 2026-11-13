package postgres

import (
	"context"
	"fmt"
	"os"
	"reflect"
	"testing"
	"time"

	"dbeer/helper/internal/catalogmetadata"
	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
)

func TestPostgresRelationshipDiscoveryCrossSchemaCompositeSelfAndVisibility(t *testing.T) {
	dsn := os.Getenv("DBEER_TEST_DSN")
	if dsn == "" {
		t.Skip("disposable PostgreSQL fixture required")
	}
	ctx, stop := context.WithTimeout(context.Background(), 40*time.Second)
	defer stop()
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal("relationship fixture connection failed")
	}
	defer conn.Close(context.Background())
	suffix := fmt.Sprint(time.Now().UnixNano())
	first, second, role := "rel_first_"+suffix, "rel_second_"+suffix, "rel_reader_"+suffix
	schema := func(name string) string { return pgx.Identifier{name}.Sanitize() }
	table := func(namespace, name string) string { return pgx.Identifier{namespace, name}.Sanitize() }
	exec := func(sql string) {
		t.Helper()
		if _, err := conn.Exec(ctx, sql); err != nil {
			t.Fatal("relationship fixture command failed")
		}
	}
	exec("CREATE SCHEMA " + schema(first) + "; CREATE SCHEMA " + schema(second))
	defer func() {
		cleanup, done := context.WithTimeout(context.Background(), 5*time.Second)
		defer done()
		conn.Exec(cleanup, "RESET ROLE; DROP SCHEMA IF EXISTS "+schema(first)+" CASCADE; DROP SCHEMA IF EXISTS "+schema(second)+" CASCADE; DROP ROLE IF EXISTS "+schema(role))
	}()
	parent := table(first, "Parent")
	exec("CREATE TABLE " + parent + `("Tenant" numeric(40,20),"Key" bytea,"PrevTenant" numeric(40,20),"PrevKey" bytea,PRIMARY KEY("Tenant","Key"),CONSTRAINT same_fk FOREIGN KEY("PrevTenant","PrevKey") REFERENCES ` + parent + `("Tenant","Key"))`)
	for _, namespace := range []string{first, second} {
		exec("CREATE TABLE " + table(namespace, "Child") + `("Id" int PRIMARY KEY,"TenantRef" numeric(40,20),"KeyRef" bytea,CONSTRAINT same_fk FOREIGN KEY("TenantRef","KeyRef") REFERENCES ` + parent + `("Tenant","Key"))`)
	}
	exec("CREATE TABLE " + table(second, "Hidden") + `(a numeric(40,20),b bytea,CONSTRAINT same_fk FOREIGN KEY(a,b) REFERENCES ` + parent + `("Tenant","Key"))`)
	exec("CREATE TABLE " + table(first, "Empty") + "(id integer PRIMARY KEY)")
	exec("INSERT INTO " + parent + `("Tenant","Key") VALUES(9007199254740993.000000000000000001,decode('00ff80','hex')),(9007199254740993.000000000000000002,decode('00ff80','hex')),(9007199254740993.000000000000000001,decode('00ff81','hex'))`)
	exec("INSERT INTO " + table(second, "Child") + ` VALUES(1,9007199254740993.000000000000000001,decode('00ff80','hex')),(2,9007199254740993.000000000000000002,decode('00ff80','hex')),(3,9007199254740993.000000000000000001,decode('00ff81','hex')),(4,NULL,NULL)`)
	s := &Session{conn: conn}
	var store catalogmetadata.Store
	defer store.Close()
	page := func(selector protocol.CatalogRequest) ([]map[string]string, string) {
		t.Helper()
		var rows []map[string]string
		c := protocol.Command{Type: "catalog.page", CatalogMetadata: &protocol.CatalogMetadataRequest{Selectors: []protocol.CatalogRequest{selector}, PageSize: 1}}
		capture, state := "", ""
		for {
			reply, err := store.Execute(ctx, s, c)
			if err != nil || !reply.Valid() {
				t.Fatal("relationship metadata capture failed")
			}
			p := reply.Collections[0]
			if capture != "" && capture != p.CaptureID {
				t.Fatal("relationship capture identity changed")
			}
			capture, state = p.CaptureID, p.State
			for _, row := range p.Rows {
				record := map[string]string{}
				for i, value := range row {
					if value != nil {
						record[p.Columns[i].Name] = *value
					}
				}
				rows = append(rows, record)
			}
			if selector.Kind == "foreignKeys" && len(p.Rows)%2 != 0 {
				t.Fatal("incoming composite constraint was split across pages")
			}
			c.CatalogMetadata.Cursor = p.NextCursor
			if p.NextCursor == "" {
				break
			}
		}
		_, err := store.Execute(ctx, s, protocol.Command{Type: "catalog.close", CatalogMetadata: &protocol.CatalogMetadataRequest{CaptureIDs: []string{capture}}})
		if err != nil {
			t.Fatal("relationship metadata capture did not close")
		}
		return rows, state
	}
	incoming := protocol.CatalogRequest{Kind: "referencingTables", Schema: first, Object: "Parent", ObjectKind: "table"}
	rows, state := page(incoming)
	expected := []map[string]string{{"schema": first, "name": "Child", "kind": "table"}, {"schema": first, "name": "Parent", "kind": "table"}, {"schema": second, "name": "Child", "kind": "table"}, {"schema": second, "name": "Hidden", "kind": "table"}}
	if state != "complete" || !reflect.DeepEqual(rows, expected) {
		t.Fatal("cross-schema incoming sources, self-reference, or same constraint names were conflated")
	}
	for _, source := range rows {
		keys, keyState := page(protocol.CatalogRequest{Kind: "foreignKeys", Schema: source["schema"], Object: source["name"], ObjectKind: "table"})
		if keyState != "complete" || len(keys) != 2 || keys[0]["name"] != "same_fk" || keys[0]["targetSchema"] != first || keys[0]["targetTable"] != "Parent" || keys[0]["targetColumn"] != "Tenant" || keys[1]["targetColumn"] != "Key" {
			t.Fatal("source-scoped composite metadata was incomplete")
		}
	}
	exact, binary := "9007199254740993.000000000000000001", "AP+A"
	browse := protocol.CatalogRequest{Kind: "browse", Schema: second, Object: "Child", ObjectKind: "table", Filters: []protocol.CatalogFilter{{Column: "TenantRef", Operator: "eq", Value: &exact}, {Column: "KeyRef", Operator: "eq", Value: &binary}}}
	filtered := catalog(ctx, conn, protocol.Command{Type: "catalog", Catalog: &browse})
	if filtered.Type != "query.result" || len(filtered.Rows) != 1 || *filtered.Rows[0][0] != "1" {
		t.Fatal("parent-to-child filters changed exact numeric or binary values")
	}
	empty, emptyState := page(protocol.CatalogRequest{Kind: "referencingTables", Schema: first, Object: "Empty", ObjectKind: "table"})
	if emptyState != "complete" || len(empty) != 0 {
		t.Fatal("unreferenced target did not produce a complete empty observation")
	}
	exec("CREATE ROLE " + schema(role) + "; GRANT USAGE ON SCHEMA " + schema(first) + "," + schema(second) + " TO " + schema(role) + "; GRANT SELECT ON " + parent + "," + table(first, "Child") + "," + table(second, "Child") + " TO " + schema(role) + "; SET ROLE " + schema(role))
	visible, visibleState := page(incoming)
	if visibleState != "complete" || !reflect.DeepEqual(visible, expected[:3]) {
		t.Fatal("incoming discovery exposed an inaccessible source or discarded visible cross-schema sources")
	}
	_, denied := page(protocol.CatalogRequest{Kind: "referencingTables", Schema: first, Object: "Empty", ObjectKind: "table"})
	if denied != "unavailable" {
		t.Fatal("denied target became a complete empty incoming observation")
	}
	exec("RESET ROLE; REVOKE ALL ON " + parent + " FROM " + schema(role) + "; SET ROLE " + schema(role))
	_, denied = page(incoming)
	if denied != "unavailable" {
		t.Fatal("revoked target metadata remained complete")
	}
}
