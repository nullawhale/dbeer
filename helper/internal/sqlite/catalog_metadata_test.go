package sqlite_test

import (
	"dbeer/helper/internal/protocol"
	"fmt"
	"strings"
	"testing"
)

func TestSQLiteMetadataPagesWideObjectsAndCompleteForeignKeys(t *testing.T) {
	h := newCompletionHarness(t)
	sid := h.connect(completionFile(t))
	for i := 0; i < 1005; i++ {
		h.run(sid, fmt.Sprintf("CREATE TABLE table_%04d(id INTEGER PRIMARY KEY)", i))
	}
	columns := make([]string, 1005)
	for i := range columns {
		columns[i] = fmt.Sprintf("column_%04d TEXT", i)
	}
	h.run(sid, "CREATE TABLE wide ("+strings.Join(columns, ",")+")")
	h.run(sid, "CREATE TABLE target (a INTEGER,b INTEGER,c INTEGER,PRIMARY KEY(a,b,c))")
	constraints := make([]string, 334)
	for i := range constraints {
		constraints[i] = "FOREIGN KEY(a,b,c) REFERENCES target(a,b,c)"
	}
	h.run(sid, "CREATE TABLE source (a INTEGER,b INTEGER,c INTEGER,"+strings.Join(constraints, ",")+")")
	for _, test := range []struct {
		selector protocol.CatalogRequest
		count    int
	}{
		{protocol.CatalogRequest{Kind: "objects", Schema: "main", ObjectKind: "table"}, 1008},
		{protocol.CatalogRequest{Kind: "columns", Schema: "main", Object: "wide", ObjectKind: "table"}, 1005},
		{protocol.CatalogRequest{Kind: "foreignKeys", Schema: "main", Object: "source", ObjectKind: "table"}, 1002},
	} {
		cursor := ""
		count := 0
		capture := ""
		for {
			id := h.id()
			h.m.Submit(protocol.Command{Type: "catalog.page", RequestID: id, QueryID: id, SessionID: sid, CatalogMetadata: &protocol.CatalogMetadataRequest{Selectors: []protocol.CatalogRequest{test.selector}, Cursor: cursor}})
			started := h.receive()
			if started.Type != "query.started" {
				t.Fatalf("metadata start missing: %s", started.Type)
			}
			r := h.receive()
			if r.Type != "catalog.page.result" || r.CatalogMetadata == nil || !r.CatalogMetadata.Valid() {
				t.Fatalf("metadata terminal invalid: %s %s", r.Type, r.Message)
			}
			page := r.CatalogMetadata.Collections[0]
			if page.State != "complete" || page.Consistency != "schemaVersion" {
				t.Fatalf("unexpected observation: %s %s", page.State, page.Issue)
			}
			if test.selector.Kind == "foreignKeys" && len(page.Rows)%3 != 0 {
				t.Fatal("composite FK split across pages")
			}
			count += len(page.Rows)
			cursor = page.NextCursor
			capture = page.CaptureID
			if cursor == "" {
				break
			}
		}
		if count != test.count {
			t.Fatalf("%s captured %d, expected %d", test.selector.Kind, count, test.count)
		}
		id := h.id()
		h.m.Submit(protocol.Command{Type: "catalog.close", RequestID: id, QueryID: id, SessionID: sid, CatalogMetadata: &protocol.CatalogMetadataRequest{CaptureIDs: []string{capture}}})
		h.receive()
		closed := h.receive()
		if closed.Type != "catalog.close.result" {
			t.Fatal("capture did not close")
		}
	}
}
