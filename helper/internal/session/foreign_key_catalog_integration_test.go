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

// ER diagrams read only selected tables; outgoing constraints must retain all
// qualified endpoints without deriving PK membership from a reference.
func TestPostgresERDiagramCatalogCrossSchemaSelfAndParallelKeys(t *testing.T) {
	h := newPGHarness(t)
	base := fmt.Sprintf("dbeer_er_%d", time.Now().UnixNano())
	sourceSchema, targetSchema := base+"_source", base+"_target"
	q := func(schema, table string) string { return pgx.Identifier{schema, table}.Sanitize() }
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	exec := func(sql string) {
		t.Helper()
		if _, err := h.observer.Exec(ctx, sql); err != nil {
			t.Fatal("cannot create disposable ER catalog fixture")
		}
	}
	exec("CREATE SCHEMA " + pgx.Identifier{sourceSchema}.Sanitize())
	exec("CREATE SCHEMA " + pgx.Identifier{targetSchema}.Sanitize())
	t.Cleanup(func() {
		h.manager.Close()
		cleanup, done := context.WithTimeout(context.Background(), 5*time.Second)
		defer done()
		_, _ = h.observer.Exec(cleanup, "DROP SCHEMA IF EXISTS "+pgx.Identifier{sourceSchema}.Sanitize()+" CASCADE")
		_, _ = h.observer.Exec(cleanup, "DROP SCHEMA IF EXISTS "+pgx.Identifier{targetSchema}.Sanitize()+" CASCADE")
	})
	exec("CREATE TABLE " + q(targetSchema, "parent.with.dots") + " (second integer, first integer, alternate integer UNIQUE, PRIMARY KEY(first,second))")
	exec("CREATE TABLE " + q(sourceSchema, "child.with.dots") + " (id integer PRIMARY KEY, a integer, b integer, alt integer, parent integer, CONSTRAINT ordered FOREIGN KEY(a,b) REFERENCES " + q(targetSchema, "parent.with.dots") + "(first,second), CONSTRAINT parallel FOREIGN KEY(a,b) REFERENCES " + q(targetSchema, "parent.with.dots") + "(first,second), CONSTRAINT non_primary FOREIGN KEY(alt) REFERENCES " + q(targetSchema, "parent.with.dots") + "(alternate), CONSTRAINT self_reference FOREIGN KEY(parent) REFERENCES " + q(sourceSchema, "child.with.dots") + "(id))")
	exec("CREATE TABLE " + q(sourceSchema, "empty.columns") + " ()")
	service := h.connect()
	columns := h.catalog(service, protocol.CatalogRequest{Kind: "columns", Schema: targetSchema, Object: "parent.with.dots", ObjectKind: "table"})
	if len(columns.Rows) != 3 || catalogText(t, columns, 0, "name") != "second" || catalogText(t, columns, 0, "primaryKey") != "2" || catalogText(t, columns, 1, "primaryKey") != "1" || catalogText(t, columns, 2, "primaryKey") != "0" {
		t.Fatal("ER columns lost physical order or primary-key ordinals")
	}
	keys := h.catalog(service, protocol.CatalogRequest{Kind: "foreignKeys", Schema: sourceSchema, Object: "child.with.dots", ObjectKind: "table"})
	if keys.Truncated || len(keys.Rows) != 6 {
		t.Fatal("ER outgoing constraints were incomplete")
	}
	counts := map[string]int{}
	for i := range keys.Rows {
		name := catalogText(t, keys, i, "name")
		counts[name]++
		if name == "self_reference" {
			if catalogText(t, keys, i, "targetSchema") != sourceSchema || catalogText(t, keys, i, "targetTable") != "child.with.dots" {
				t.Fatal("ER self-reference lost its exact table identity")
			}
		} else if catalogText(t, keys, i, "targetSchema") != targetSchema || catalogText(t, keys, i, "targetTable") != "parent.with.dots" {
			t.Fatal("ER cross-schema reference lost its exact target identity")
		}
	}
	if counts["ordered"] != 2 || counts["parallel"] != 2 || counts["self_reference"] != 1 || counts["non_primary"] != 1 {
		t.Fatal("ER constraints were merged or split")
	}
	empty := h.catalog(service, protocol.CatalogRequest{Kind: "columns", Schema: sourceSchema, Object: "empty.columns", ObjectKind: "table"})
	if empty.Type != "query.result" || empty.Truncated || len(empty.Rows) != 0 {
		t.Fatal("PostgreSQL zero-column metadata was not represented faithfully")
	}
}
