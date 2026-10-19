package session_test

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
)

func TestPostgresCopyNameQuotesEveryObjectKindWithoutExecutingIt(t *testing.T) {
	h := newPGHarness(t)
	schema := fmt.Sprintf("dbeer_name_%x_\"猫", time.Now().UnixNano())
	qualified := func(name string) string { return pgx.Identifier{schema, name}.Sanitize() }
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	exec := func(sql string) {
		t.Helper()
		if _, err := h.observer.Exec(ctx, sql); err != nil {
			t.Fatal("cannot create disposable PostgreSQL Copy Name fixture")
		}
	}
	exec("CREATE SCHEMA " + pgx.Identifier{schema}.Sanitize())
	t.Cleanup(func() {
		h.manager.Close()
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_, _ = h.observer.Exec(cleanupCtx, "DROP SCHEMA IF EXISTS "+pgx.Identifier{schema}.Sanitize()+" CASCADE")
	})
	names := map[string]string{}
	for _, kind := range []string{"table", "view", "function", "procedure", "trigger"} {
		names[kind] = kind + ` "Ω表';%_--`
	}
	exec("CREATE TABLE " + qualified(names["table"]) + " (id integer)")
	exec("CREATE VIEW " + qualified(names["view"]) + " AS SELECT id FROM " + qualified(names["table"]))
	exec("CREATE FUNCTION " + qualified(names["function"]) + "(integer) RETURNS integer LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'Copy Name must not execute a function'; END$$")
	exec("CREATE FUNCTION " + qualified(names["function"]) + "(text) RETURNS text LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'Copy Name must not execute a function'; END$$")
	exec("CREATE PROCEDURE " + qualified(names["procedure"]) + "() LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'Copy Name must not execute a procedure'; END$$")
	exec("CREATE FUNCTION " + qualified("trigger_body") + "() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'Copy Name must not execute a trigger'; END$$")
	exec("CREATE TRIGGER " + pgx.Identifier{names["trigger"]}.Sanitize() + " BEFORE INSERT ON " + qualified(names["table"]) + " FOR EACH ROW EXECUTE FUNCTION " + qualified("trigger_body") + "()")
	service := h.connect()
	for _, kind := range []string{"table", "view", "function", "procedure", "trigger"} {
		request := protocol.CatalogRequest{Kind: "name", Schema: schema, Object: names[kind], ObjectKind: kind}
		assertName := func(request protocol.CatalogRequest) {
			t.Helper()
			response := h.catalog(service, request)
			expected := qualified(names[kind])
			if kind == "trigger" {
				expected = pgx.Identifier{names[kind]}.Sanitize()
			}
			if response.Type != "query.result" || len(response.Columns) != 1 || response.Columns[0].Name != "name" || len(response.Rows) != 1 || catalogText(t, response, 0, "name") != expected {
				t.Fatalf("Copy Name did not return one correctly quoted %s identifier", kind)
			}
		}
		assertName(request)
		for _, scope := range []string{"", schema} {
			for _, search := range []string{names[kind], strings.ToLower(names[kind])} {
				found := h.catalog(service, protocol.CatalogRequest{Kind: "search", Schema: scope, Search: search})
				matched := false
				for row := range found.Rows {
					if catalogText(t, found, row, "name") == names[kind] && catalogText(t, found, row, "kind") == kind && catalogText(t, found, row, "schema") == schema {
						matched = true
					}
				}
				if !matched {
					t.Fatalf("Unicode catalog search omitted %s (schema scoped=%t, original case=%t, response=%s)", kind, scope != "", search == names[kind], found.Type)
				}
			}
		}
		if kind == "function" || kind == "procedure" || kind == "trigger" {
			objects := h.catalog(service, protocol.CatalogRequest{Kind: "objects", Schema: schema, ObjectKind: kind})
			row := catalogFind(t, objects, names[kind])
			request.Identity = catalogText(t, objects, row, "identity")
			assertName(request)
			request.Identity = "0"
			missing := h.catalog(service, request)
			if missing.Type != "query.result" || len(missing.Rows) != 0 || missing.DisplayNotice == "" {
				t.Fatal("Copy Name returned an identifier for a stale object identity")
			}
		}
	}
	// Generate SELECT remains a table/view operation with its original shape.
	selected := h.catalog(service, protocol.CatalogRequest{Kind: "select", Schema: schema, Object: names["view"], ObjectKind: "view"})
	if catalogText(t, selected, 0, "sql") != "SELECT * FROM "+qualified(names["view"])+" LIMIT 200" {
		t.Fatal("Copy Name changed Generate SELECT")
	}
}
