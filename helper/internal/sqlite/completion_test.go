package sqlite_test

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/session"
	"dbeer/helper/internal/sqlcomplete"
	"dbeer/helper/internal/sqlite"
)

type completionHarness struct {
	t      *testing.T
	m      *session.Manager
	opened atomic.Int32
	next   int
}

func newCompletionHarness(t *testing.T) *completionHarness {
	h := &completionHarness{t: t}
	h.m = session.New(func(ctx context.Context, c protocol.Connection) (adapter.Session, error) {
		h.opened.Add(1)
		return sqlite.Open(ctx, c)
	})
	t.Cleanup(h.m.Close)
	return h
}
func (h *completionHarness) receive() protocol.Response {
	h.t.Helper()
	select {
	case r := <-h.m.Responses():
		return r
	case <-time.After(5 * time.Second):
		h.t.Fatal("SQLite session metadata timed out")
		return protocol.Response{}
	}
}
func (h *completionHarness) id() string { h.next++; return "completion-" + strconv.Itoa(h.next) }
func (h *completionHarness) connect(path string) string {
	h.t.Helper()
	h.m.Submit(protocol.Command{Type: "connect", RequestID: h.id(), Connection: &protocol.Connection{Engine: "sqlite", SQLite: &protocol.SQLiteSettings{Path: path}}})
	r := h.receive()
	if r.Type != "connect.result" {
		h.t.Fatal("SQLite completion fixture did not connect")
	}
	return r.SessionID
}
func (h *completionHarness) execute(sid, sql string) protocol.Response {
	h.t.Helper()
	reviewID := h.id()
	h.m.Submit(protocol.Command{Type: "operation.assess", RequestID: reviewID, QueryID: reviewID, SessionID: sid,
		Operations: []protocol.OperationRequest{{Type: "execute", SQL: sql}}})
	review := h.receive()
	if review.Type != "operation.assessment" || review.Assessment == nil {
		return review
	}
	id := h.id()
	h.m.Submit(protocol.Command{Type: "execute", RequestID: id, QueryID: id, SessionID: sid, SQL: sql,
		Authorization: review.Assessment.Authorization})
	for {
		r := h.receive()
		if r.Type != "query.started" {
			return r
		}
	}
}
func (h *completionHarness) run(sid, sql string) {
	h.t.Helper()
	if h.execute(sid, sql).Type != "query.result" {
		h.t.Fatal("SQLite completion fixture SQL failed")
	}
}
func (h *completionHarness) catalog(sid string, request protocol.CatalogRequest) ([]map[string]string, protocol.Response) {
	h.t.Helper()
	id := h.id()
	h.m.Submit(protocol.Command{Type: "catalog", RequestID: id, QueryID: id, SessionID: sid, Stream: true, Catalog: &request})
	var columns []protocol.Column
	var rows [][]*string
	for {
		r := h.receive()
		if r.RequestID != id || r.QueryID != id || r.SessionID != sid {
			h.t.Fatal("SQLite completion lost session correlation")
		}
		switch r.Type {
		case "query.started":
		case "query.chunk":
			if r.Columns != nil {
				columns = r.Columns
			}
			rows = append(rows, r.Rows...)
			if h.m.Control(protocol.Command{Type: "stream.ack", RequestID: h.id(), QueryID: id, SessionID: sid, Sequence: r.Sequence}) != nil {
				h.t.Fatal("SQLite completion credit rejected")
			}
		case "query.result":
			if !r.Streamed || len(r.ResultSets) != 1 || r.DisplayedRowCount != len(rows) || len(r.SQLiteValues) != len(rows) {
				h.t.Fatal("SQLite completion stream lost rows or types")
			}
			out := make([]map[string]string, len(rows))
			for i, row := range rows {
				out[i] = map[string]string{}
				for j, column := range columns {
					if row[j] != nil {
						out[i][column.Name] = *row[j]
					}
				}
			}
			return out, r
		case "error":
			return nil, r
		default:
			h.t.Fatal("Unexpected SQLite completion response")
		}
	}
}

func completionFile(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "completion.sqlite")
	if err := sqlite.Create(context.Background(), path); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestSQLiteCompletionUsesOnlyItsPhysicalSession(t *testing.T) {
	h := newCompletionHarness(t)
	main, extra := completionFile(t), completionFile(t)
	tab, service := h.connect(main), h.connect(main)
	h.run(tab, `CREATE TABLE duplicate(main_id INTEGER PRIMARY KEY)`)
	h.run(tab, "ATTACH DATABASE '"+strings.ReplaceAll(extra, "'", "''")+"' AS extra")
	h.run(tab, `CREATE TABLE extra.duplicate(extra_id TEXT, derived TEXT GENERATED ALWAYS AS (extra_id || '!'))`)
	h.run(tab, `CREATE INDEX extra.extra_index ON duplicate(extra_id)`)
	h.run(tab, `CREATE TEMP TABLE duplicate(temp_id BLOB)`)
	h.run(tab, `CREATE TEMP VIEW temporary_view AS SELECT temp_id FROM duplicate`)
	rows, r := h.catalog(tab, protocol.CatalogRequest{Kind: "completion"})
	if r.Type != "query.result" || len(rows) != 4 {
		t.Fatalf("tab completion count differs: %d", len(rows))
	}
	want := map[string]string{"main.duplicate": "main_id", "extra.duplicate": "extra_id", "temp.duplicate": "temp_id", "temp.temporary_view": "temp_id"}
	for _, row := range rows {
		key := row["schema"] + "." + row["name"]
		name, ok := want[key]
		if !ok {
			t.Fatal("completion included an unrelated object")
		}
		var columns []string
		if json.Unmarshal([]byte(row["columns"]), &columns) != nil || len(columns) == 0 || columns[0] != name {
			t.Fatal("completion columns came from a different namespace")
		}
		if key == "extra.duplicate" && (len(columns) != 2 || columns[1] != "derived") {
			t.Fatal("completion omitted a visible generated column")
		}
	}
	rows, r = h.catalog(service, protocol.CatalogRequest{Kind: "completion"})
	if r.Type != "query.result" || len(rows) != 1 || rows[0]["schema"] != "main" {
		t.Fatal("tab attachments or temp objects leaked into service session")
	}
	rows, r = h.catalog(tab, protocol.CatalogRequest{Kind: "completion", Schema: "extra"})
	if r.Type != "query.result" || len(rows) != 1 || rows[0]["schema"] != "extra" {
		t.Fatal("explicit attached completion schema failed")
	}
	_, r = h.catalog(service, protocol.CatalogRequest{Kind: "completion", Schema: "extra"})
	if r.Type != "error" {
		t.Fatal("completion discovered an unattached schema")
	}
	_, r = h.catalog(tab, protocol.CatalogRequest{Kind: "objects", Schema: "extra", ObjectKind: "table"})
	if r.Type != "error" {
		t.Fatal("profile catalog unexpectedly opened an attached schema")
	}
	h.run(tab, `DETACH extra`)
	rows, r = h.catalog(tab, protocol.CatalogRequest{Kind: "completion"})
	if r.Type != "query.result" || len(rows) != 3 {
		t.Fatal("detached completion metadata remained visible")
	}
	for _, row := range rows {
		if row["schema"] == "extra" {
			t.Fatal("completion retained detached schema")
		}
	}
	if h.opened.Load() != 2 {
		t.Fatal("completion opened extra physical connections")
	}
	missing := filepath.Join(t.TempDir(), "missing.sqlite")
	if h.execute(tab, "ATTACH '"+missing+"' AS absent").Type != "error" {
		t.Fatal("missing attachment opened")
	}
	if _, err := os.Stat(missing); !os.IsNotExist(err) {
		t.Fatal("completion or ATTACH created a missing file")
	}
}

func TestSQLiteCompletionPaginatesAcrossNamespacesAndQuotesAliases(t *testing.T) {
	h := newCompletionHarness(t)
	sid := h.connect(completionFile(t))
	extra := completionFile(t)
	h.run(sid, "ATTACH '"+extra+"' AS \"a\"\"; odd\"")
	for i := 0; i < 205; i++ {
		h.run(sid, fmt.Sprintf(`CREATE TABLE "a""; odd"."table_%03d"(attached_column TEXT)`, i))
	}
	h.run(sid, `CREATE TABLE main.last_table(main_column INTEGER)`)
	first, r := h.catalog(sid, protocol.CatalogRequest{Kind: "completion"})
	if r.Type != "query.result" || len(first) != 200 || first[0]["schema"] != "main" || first[0]["name"] != "last_table" || first[1]["schema"] != "a\"; odd" || first[1]["name"] != "table_000" || first[199]["name"] != "table_198" {
		t.Fatal("first completion page ordering differs")
	}
	second, r := h.catalog(sid, protocol.CatalogRequest{Kind: "completion", Page: 1})
	if r.Type != "query.result" || len(second) != 6 || second[0]["name"] != "table_199" || second[5]["name"] != "table_204" || second[5]["schema"] != "a\"; odd" {
		t.Fatal("completion page did not cross schema boundary deterministically")
	}
	again, r := h.catalog(sid, protocol.CatalogRequest{Kind: "completion", Page: 1})
	if r.Type != "query.result" || len(again) != len(second) {
		t.Fatal("completion pagination changed without metadata changes")
	}
	for i := range again {
		if again[i]["schema"] != second[i]["schema"] || again[i]["name"] != second[i]["name"] {
			t.Fatal("completion ordering is unstable")
		}
	}
	_, r = h.catalog(sid, protocol.CatalogRequest{Kind: "completion", Schema: `missing"; DELETE FROM main.last_table;--`})
	if r.Type != "error" {
		t.Fatal("completion accepted an unattached injected namespace")
	}
	_, r = h.catalog(sid, protocol.CatalogRequest{Kind: "completion", Page: 50})
	if r.Type != "error" {
		t.Fatal("completion exceeded its object limit")
	}
}

func TestSQLiteCompletionExcludesFTSShadowTables(t *testing.T) {
	h := newCompletionHarness(t)
	sid := h.connect(completionFile(t))
	h.run(sid, `CREATE VIRTUAL TABLE search_index USING fts5(body)`)
	rows, result := h.catalog(sid, protocol.CatalogRequest{Kind: "completion"})
	if result.Type != "query.result" || len(rows) != 1 || rows[0]["name"] != "search_index" {
		t.Fatal("SQLite completion exposed internal FTS shadow tables")
	}
	var columns []string
	if json.Unmarshal([]byte(rows[0]["columns"]), &columns) != nil || len(columns) != 1 || columns[0] != "body" {
		t.Fatal("SQLite completion exposed hidden virtual-table columns")
	}
}

func TestSQLiteCompletionKeepsNamesSimilarToReservedPrefix(t *testing.T) {
	h := newCompletionHarness(t)
	sid := h.connect(completionFile(t))
	h.run(sid, `CREATE TABLE sqliteX_public(id INTEGER PRIMARY KEY)`)
	for _, request := range []protocol.CatalogRequest{
		{Kind: "completion"},
		{Kind: "objects", Schema: "main", ObjectKind: "table"},
		{Kind: "search", Search: "sqliteX_public"},
	} {
		rows, response := h.catalog(sid, request)
		if response.Type != "query.result" || len(rows) != 1 || rows[0]["name"] != "sqliteX_public" {
			t.Fatal("SQLite metadata hid an ordinary name resembling the reserved prefix")
		}
	}
}

func TestSQLiteCompletionSchemaOrderMatchesLiveNameResolution(t *testing.T) {
	h := newCompletionHarness(t)
	sid := h.connect(completionFile(t))
	h.run(sid, `CREATE TABLE Shared(main_only TEXT)`)
	h.run(sid, "ATTACH '"+completionFile(t)+"' AS z_old")
	h.run(sid, `CREATE TABLE z_old.Shared(old_only TEXT)`)
	h.run(sid, "ATTACH '"+completionFile(t)+"' AS a_new")
	h.run(sid, `CREATE TABLE a_new.Shared(new_only TEXT)`)
	h.run(sid, `CREATE TEMP TABLE Shared(temp_only TEXT)`)
	for _, want := range []string{"temp_only", "main_only", "old_only", "new_only"} {
		rows, response := h.catalog(sid, protocol.CatalogRequest{Kind: "completion"})
		if response.Type != "query.result" {
			t.Fatal("SQLite completion metadata failed")
		}
		sort.SliceStable(rows, func(i, j int) bool {
			a, ea := strconv.Atoi(rows[i]["schemaOrder"])
			b, eb := strconv.Atoi(rows[j]["schemaOrder"])
			if ea != nil || eb != nil {
				t.Fatal("SQLite completion omitted schema search order")
			}
			return a < b
		})
		catalog := []sqlcomplete.Relation{}
		for _, row := range rows {
			var columns []string
			if json.Unmarshal([]byte(row["columns"]), &columns) != nil {
				t.Fatal("invalid completion column metadata")
			}
			catalog = append(catalog, sqlcomplete.Relation{Schema: row["schema"], Name: row["name"], Kind: row["kind"], Columns: columns})
		}
		const source = `SELECT s. FROM "SHARED" s`
		items := sqlcomplete.Complete(source, len("SELECT s."), sqlcomplete.Context{Engine: "sqlite", Catalog: catalog})
		found := false
		for _, item := range items {
			if item.Kind == 5 {
				if item.Label != want {
					t.Fatal("SQLite completion includes a shadowed table's column")
				}
				found = true
			}
		}
		if !found {
			t.Fatal("SQLite completion omitted the visible table's column")
		}
		live := h.execute(sid, `SELECT * FROM "SHARED" LIMIT 0`)
		if live.Type != "query.result" || len(live.Columns) != 1 || live.Columns[0].Name != want {
			t.Fatal("completion resolution differs from SQLite")
		}
		switch want {
		case "temp_only":
			h.run(sid, `DROP TABLE temp.Shared`)
		case "main_only":
			h.run(sid, `DROP TABLE main.Shared`)
		case "old_only":
			h.run(sid, `DETACH z_old`)
		}
	}
}
