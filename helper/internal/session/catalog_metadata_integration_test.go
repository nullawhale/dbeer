package session_test

import (
	"context"
	"dbeer/helper/internal/protocol"
	"fmt"
	"github.com/jackc/pgx/v5"
	"strings"
	"testing"
	"time"
)

func TestPostgresMetadataPagesLargeCatalogAndAtomicForeignKeys(t *testing.T) {
	h := newPGHarness(t)
	schema := fmt.Sprintf("metadata_%d", time.Now().UnixNano())
	role := schema + "_reader"
	qualified := func(name string) string { return pgx.Identifier{schema, name}.Sanitize() }
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	exec := func(sql string) {
		t.Helper()
		if _, err := h.observer.Exec(ctx, sql); err != nil {
			t.Fatal("cannot prepare isolated metadata fixture")
		}
	}
	exec("CREATE SCHEMA " + pgx.Identifier{schema}.Sanitize())
	t.Cleanup(func() {
		h.manager.Close()
		cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		h.observer.Exec(cleanup, "DROP SCHEMA IF EXISTS "+pgx.Identifier{schema}.Sanitize()+" CASCADE")
		h.observer.Exec(cleanup, "DROP ROLE IF EXISTS "+pgx.Identifier{role}.Sanitize())
	})
	var definitions strings.Builder
	for i := 0; i < 1005; i++ {
		fmt.Fprintf(&definitions, "CREATE TABLE %s(id integer);", qualified(fmt.Sprintf("table_%04d", i)))
	}
	exec(definitions.String())
	columns := make([]string, 1005)
	for i := range columns {
		columns[i] = fmt.Sprintf("column_%04d text", i)
	}
	exec("CREATE TABLE " + qualified("wide") + "(" + strings.Join(columns, ",") + ")")
	exec("CREATE TABLE " + qualified("target") + "(a integer,b integer,c integer,PRIMARY KEY(a,b,c))")
	constraints := make([]string, 334)
	for i := range constraints {
		constraints[i] = fmt.Sprintf("CONSTRAINT fk_%04d FOREIGN KEY(a,b,c) REFERENCES %s(a,b,c)", i, qualified("target"))
	}
	exec("CREATE TABLE " + qualified("source") + "(a integer,b integer,c integer," + strings.Join(constraints, ",") + ")")
	sid := h.connect()
	metadata := func(command protocol.Command) protocol.Response {
		t.Helper()
		command.RequestID, command.QueryID, command.SessionID = h.id(), h.id(), sid
		h.send(command)
		if h.receive().Type != "query.started" {
			t.Fatal("metadata did not start")
		}
		r := h.receive()
		if r.Type != command.Type+".result" || r.CatalogMetadata == nil || !r.CatalogMetadata.Valid() || r.TransactionStatus != "idle" {
			t.Fatalf("metadata did not complete: %s %s", r.Type, r.Message)
		}
		return r
	}
	for _, test := range []struct {
		selector protocol.CatalogRequest
		count    int
	}{
		{protocol.CatalogRequest{Kind: "objects", Schema: schema, ObjectKind: "table"}, 1008},
		{protocol.CatalogRequest{Kind: "columns", Schema: schema, Object: "wide", ObjectKind: "table"}, 1005},
		{protocol.CatalogRequest{Kind: "foreignKeys", Schema: schema, Object: "source", ObjectKind: "table"}, 1002},
		{protocol.CatalogRequest{Kind: "foreignKeys", Schema: schema, Object: "wide", ObjectKind: "table"}, 0},
		{protocol.CatalogRequest{Kind: "indexes", Schema: schema, Object: "wide", ObjectKind: "table"}, 0},
		{protocol.CatalogRequest{Kind: "triggers", Schema: schema, Object: "wide", ObjectKind: "table"}, 0},
	} {
		cursor := ""
		count := 0
		capture := ""
		for {
			r := metadata(protocol.Command{Type: "catalog.page", CatalogMetadata: &protocol.CatalogMetadataRequest{Selectors: []protocol.CatalogRequest{test.selector}, Cursor: cursor}})
			page := r.CatalogMetadata.Collections[0]
			if page.State != "complete" || page.Consistency != "repeatableRead" {
				t.Fatalf("incomplete PostgreSQL metadata: %s", page.Issue)
			}
			if test.selector.Kind == "foreignKeys" && len(page.Rows)%3 != 0 {
				t.Fatal("FK split across pages")
			}
			count += len(page.Rows)
			cursor, capture = page.NextCursor, page.CaptureID
			if cursor == "" {
				break
			}
		}
		if count != test.count {
			t.Fatalf("%s captured %d, expected %d", test.selector.Kind, count, test.count)
		}
		metadata(protocol.Command{Type: "catalog.close", CatalogMetadata: &protocol.CatalogMetadataRequest{CaptureIDs: []string{capture}}})
	}
	exec("CREATE ROLE " + pgx.Identifier{role}.Sanitize())
	exec("GRANT USAGE ON SCHEMA " + pgx.Identifier{schema}.Sanitize() + " TO " + pgx.Identifier{role}.Sanitize())
	exec("GRANT SELECT ON " + qualified("target") + " TO " + pgx.Identifier{role}.Sanitize())
	h.query(sid, "SET ROLE "+pgx.Identifier{role}.Sanitize(), "idle")
	batch := metadata(protocol.Command{Type: "catalog.batch", CatalogMetadata: &protocol.CatalogMetadataRequest{Selectors: []protocol.CatalogRequest{
		{Kind: "columns", Schema: schema, Object: "target", ObjectKind: "table"},
		{Kind: "columns", Schema: schema, Object: "source", ObjectKind: "table"},
	}}})
	if batch.CatalogMetadata.Collections[0].State != "complete" || batch.CatalogMetadata.Collections[1].State != "unavailable" {
		t.Fatal("denied table became empty complete collection")
	}
}
