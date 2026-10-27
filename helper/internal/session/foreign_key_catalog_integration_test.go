package session_test

import (
	"context"
	"fmt"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
)

func TestPostgresForeignKeyCatalogCompositeOrderAndDeniedTarget(t *testing.T) {
	h := newPGHarness(t)
	schema := fmt.Sprintf("dbeer_fk_%d", time.Now().UnixNano())
	role := fmt.Sprintf("dbeer_fk_reader_%d", time.Now().UnixNano())
	source, target, constraint := `child "Ω`, `parent 'quoted`, `foreign "key`
	qualified := func(name string) string { return pgx.Identifier{schema, name}.Sanitize() }
	column := func(name string) string { return pgx.Identifier{name}.Sanitize() }
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	exec := func(sql string) {
		t.Helper()
		if _, err := h.observer.Exec(ctx, sql); err != nil {
			t.Fatal("cannot create disposable foreign key catalog fixture")
		}
	}
	exec("CREATE SCHEMA " + column(schema))
	t.Cleanup(func() {
		h.manager.Close()
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_, _ = h.observer.Exec(cleanupCtx, "DROP SCHEMA IF EXISTS "+column(schema)+" CASCADE")
		_, _ = h.observer.Exec(cleanupCtx, "DROP ROLE IF EXISTS "+column(role))
	})
	exec("CREATE TABLE " + qualified(target) + " (" + column("key z") + " integer, " + column("key a") + " text, PRIMARY KEY (" + column("key a") + "," + column("key z") + "))")
	exec("CREATE TABLE " + qualified(source) + " (" + column("child z") + " integer, " + column("child a") + " text, CONSTRAINT " + column(constraint) + " FOREIGN KEY (" + column("child a") + "," + column("child z") + ") REFERENCES " + qualified(target) + " (" + column("key a") + "," + column("key z") + "))")
	exec("CREATE ROLE " + column(role))
	exec("GRANT USAGE ON SCHEMA " + column(schema) + " TO " + column(role))
	exec("GRANT SELECT ON " + qualified(source) + " TO " + column(role))
	service := h.connect()
	h.query(service, "SET ROLE "+column(role), "idle")
	request := protocol.CatalogRequest{Kind: "foreignKeys", Schema: schema, Object: source, ObjectKind: "table"}
	assertPairs := func(response protocol.Response) {
		t.Helper()
		if response.Type != "query.result" || response.Truncated || len(response.Rows) != 2 {
			t.Fatal("visible composite foreign key metadata was unavailable")
		}
		for index, pair := range [][2]string{{"child a", "key a"}, {"child z", "key z"}} {
			if catalogText(t, response, index, "name") != constraint || catalogText(t, response, index, "targetSchema") != schema || catalogText(t, response, index, "targetTable") != target || catalogText(t, response, index, "sourceColumn") != pair[0] || catalogText(t, response, index, "targetColumn") != pair[1] || catalogText(t, response, index, "position") != fmt.Sprint(index+1) {
				t.Fatal("foreign key lost paired identifiers or constraint order")
			}
		}
	}
	assertPairs(h.catalog(service, request))
	denied := h.catalog(service, protocol.CatalogRequest{Kind: "browse", Schema: schema, Object: target, ObjectKind: "table"})
	if denied.Type != "error" || denied.SQLState != "42501" || !denied.Connected || denied.Message != "Catalog information is unavailable or access was denied." {
		t.Fatal("inaccessible foreign key target did not fail explicitly")
	}
	assertPairs(h.catalog(service, request))
	exec("REVOKE SELECT ON " + qualified(source) + " FROM " + column(role))
	denied = h.catalog(service, request)
	if denied.Type != "error" || denied.SQLState != "42501" || !denied.Connected {
		t.Fatal("inaccessible source metadata was silently presented as no foreign keys")
	}
	h.query(service, "RESET ROLE", "idle")
	view := "source view"
	exec("CREATE VIEW " + qualified(view) + " AS SELECT * FROM " + qualified(source))
	response := h.catalog(service, protocol.CatalogRequest{Kind: "foreignKeys", Schema: schema, Object: view, ObjectKind: "view"})
	if response.Type != "query.result" || len(response.Rows) != 0 {
		t.Fatal("a view without foreign keys should return an empty structured result")
	}
}
