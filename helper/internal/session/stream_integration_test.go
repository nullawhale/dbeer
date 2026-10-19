package session_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

func (h *pgHarness) stream(id, sql string) (protocol.Response, []protocol.ResultSet) {
	h.t.Helper()
	command := protocol.Command{Type: "execute", RequestID: h.id(), SessionID: id, QueryID: h.id(), SQL: sql, Stream: true}
	h.send(command)
	var sets []protocol.ResultSet
	sequence := 0
	started := false
	for {
		response := h.receive()
		if response.RequestID != command.RequestID || response.QueryID != command.QueryID || response.SessionID != id {
			h.t.Fatal("stream lost execution correlation")
		}
		switch response.Type {
		case "query.started":
			if started {
				h.t.Fatal("stream repeated its start")
			}
			started = true
		case "query.chunk":
			sequence++
			if !started || response.Sequence != sequence {
				h.t.Fatal("stream reordered chunks")
			}
			if response.Columns != nil {
				if response.ResultIndex != len(sets) {
					h.t.Fatal("stream reordered result sets")
				}
				sets = append(sets, protocol.ResultSet{Columns: response.Columns, Rows: [][]*string{}})
			}
			if response.ResultIndex < 0 || response.ResultIndex >= len(sets) {
				h.t.Fatal("stream omitted metadata")
			}
			sets[response.ResultIndex].Rows = append(sets[response.ResultIndex].Rows, response.Rows...)
			if reply := h.manager.Control(protocol.Command{Type: "stream.ack", RequestID: h.id(), SessionID: id, QueryID: command.QueryID, Sequence: sequence}); reply != nil {
				h.t.Fatal("stream credit was rejected")
			}
		case "query.result", "error":
			if !response.Streamed {
				h.t.Fatal("stream terminal did not identify its summaries")
			}
			if len(response.ResultSets) > len(sets) {
				h.t.Fatal("stream terminal added unseen data")
			}
			for index, summary := range response.ResultSets {
				if summary.DisplayedRowCount != len(sets[index].Rows) || len(summary.Rows) != 0 {
					h.t.Fatal("stream terminal duplicated data or changed its prefix count")
				}
			}
			return response, sets
		default:
			h.t.Fatal("unexpected stream response")
		}
	}
}

func TestPostgresStreamingBoundsBinaryAndPaging(t *testing.T) {
	h := newPGHarness(t)
	id := h.connect()
	response, sets := h.stream(id, "SELECT n FROM generate_series(1,1107)n")
	if response.Type != "query.result" || response.RowCount != 1107 || len(sets) != 1 || len(sets[0].Rows) != 1000 || !response.Truncated {
		t.Fatal("stream did not retain the first 1000 rows and drain the complete command")
	}
	response, sets = h.stream(id, "SELECT repeat(chr(1),2048) FROM generate_series(1,1000)")
	if response.Type != "query.result" || response.RowCount != 1000 || !response.Truncated || len(sets[0].Rows) == 0 || len(sets[0].Rows) >= 1000 {
		t.Fatal("stream did not budget escaped JSON data")
	}
	encoded, _ := json.Marshal(sets)
	if len(encoded) > 8*1024*1024 {
		t.Fatal("stream retained more than its byte budget")
	}
	h.query(id, "SET bytea_output='escape'", "idle")
	response, sets = h.stream(id, "SELECT decode('00ff5c','hex') AS x,NULL::bytea AS x,9007199254740993.123456789::numeric AS exact")
	if response.Type != "query.result" || len(sets[0].Rows) != 1 || sets[0].Columns[0].Encoding != "base64" || *sets[0].Rows[0][0] != "AP9c" || sets[0].Rows[0][1] != nil || *sets[0].Rows[0][2] != "9007199254740993.123456789" {
		t.Fatal("stream lost binary, NULL, duplicate names or exact numeric text")
	}
	// Table paging uses a separate data session and a real composite PK. Ties
	// in the requested sort must still have deterministic primary-key order.
	h.query(id, "CREATE TEMP TABLE dbeer_paging(tenant int,id int,marker text,payload bytea,PRIMARY KEY(tenant,id))", "idle")
	h.query(id, "INSERT INTO dbeer_paging SELECT 1,n,'same',decode('00ff','hex') FROM generate_series(1,405)n", "idle")
	// pg_temp resolves to a backend-specific real schema; introspection requires
	// that actual namespace name rather than PostgreSQL's search-path alias.
	namespace := h.query(id, "SELECT n.nspname FROM pg_namespace n WHERE n.oid=pg_my_temp_schema()", "idle")
	schema := *namespace.Rows[0][0]
	request := protocol.CatalogRequest{Kind: "browse", Schema: schema, Object: "dbeer_paging", ObjectKind: "table", Page: 1, Sort: []protocol.CatalogSort{{Column: "marker", Direction: "asc"}}}
	page := h.catalog(id, request)
	if page.Type != "query.result" || len(page.Rows) != 200 || *page.Rows[0][1] != "201" || *page.Rows[199][1] != "400" {
		t.Fatal("paging omitted PK tie-breakers or used the wrong offset")
	}
	value := "400"
	request.Page = 0
	request.Filters = []protocol.CatalogFilter{{Column: "id", Operator: "gt", Value: &value}}
	page = h.catalog(id, request)
	if page.Type != "query.result" || len(page.Rows) != 5 || *page.Rows[0][1] != "401" {
		t.Fatal("paging did not bind typed filters")
	}
	literal := "same%' OR true --"
	request.Filters = []protocol.CatalogFilter{{Column: "marker", Operator: "contains", Value: &literal}}
	if page = h.catalog(id, request); page.Type != "query.result" || len(page.Rows) != 0 {
		t.Fatal("filter text was interpreted as SQL")
	}
	request.Sort = []protocol.CatalogSort{{Column: "id; DROP TABLE dbeer_paging", Direction: "asc"}}
	if page = h.catalog(id, request); page.Type != "error" || page.Category != "protocol" || !page.Connected {
		t.Fatal("unknown sort identifiers were accepted")
	}
	h.query(id, "SELECT count(*) FROM dbeer_paging", "idle")
}

func TestPostgresRunToFileExecutesOnceAndPublishesOnlyConfirmedSuccess(t *testing.T) {
	h := newPGHarness(t)
	id := h.connect()
	directory := t.TempDir()
	h.query(id, "CREATE TEMP TABLE dbeer_export_probe(id bigserial PRIMARY KEY,value integer)", "idle")
	path := filepath.Join(directory, "all.json")
	executeExport := func(sql string, request protocol.ExportRequest) protocol.Response {
		t.Helper()
		command := protocol.Command{Type: "execute", RequestID: h.id(), SessionID: id, QueryID: h.id(), SQL: sql, Export: &request}
		h.send(command)
		if h.receive().Type != "query.started" {
			t.Fatal("export did not start")
		}
		return h.receive()
	}
	response := executeExport("INSERT INTO dbeer_export_probe(value) SELECT n FROM generate_series(1,1503)n RETURNING id,value", protocol.ExportRequest{Path: path, Format: "json"})
	if response.Type != "query.result" || response.ExportRowCount != 1503 || response.RowCount != 1503 {
		t.Fatal("full export did not finish the one SQL execution")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal("export did not publish its destination")
	}
	var document struct {
		ResultSets []struct {
			Metadata struct {
				RowCount  int64
				Truncated bool
			}
			Rows [][]*string
		}
	}
	if json.Unmarshal(data, &document) != nil || len(document.ResultSets) != 1 || len(document.ResultSets[0].Rows) != 1503 || document.ResultSets[0].Metadata.Truncated {
		t.Fatal("full export silently retained only the display prefix")
	}
	count := h.query(id, "SELECT count(*) FROM dbeer_export_probe", "idle")
	if *count.Rows[0][0] != "1503" {
		t.Fatal("export repeated a SQL command with side effects")
	}
	preserve := filepath.Join(directory, "preserve.csv")
	if os.WriteFile(preserve, []byte("original"), 0600) != nil {
		t.Fatal("cannot create export destination fixture")
	}
	marker := "NULL"
	response = executeExport("SELECT 'NULL'::text", protocol.ExportRequest{Path: preserve, Format: "csv", NullMarker: &marker})
	if response.Type != "error" || response.Category != "export" || !response.Connected || response.OutcomeUnknown || !strings.Contains(response.Message, "SQL completed") {
		t.Fatal("NULL collision obscured the confirmed SQL outcome")
	}
	response = executeExport("SELECT 1/0", protocol.ExportRequest{Path: preserve, Format: "csv"})
	if response.Type != "error" || response.Category != "sql" {
		t.Fatal("failed SQL was published as an export")
	}
	pid := h.pid(id)
	request := protocol.ExportRequest{Path: preserve, Format: "json"}
	command := protocol.Command{Type: "execute", RequestID: h.id(), SessionID: id, QueryID: h.id(), SQL: "SELECT n,pg_sleep(0.01) FROM generate_series(1,10000)n", Export: &request}
	h.send(command)
	if h.receive().Type != "query.started" {
		t.Fatal("cancelled export did not start")
	}
	h.waitBackend(pid, true, true)
	ack := h.manager.Control(protocol.Command{Type: "cancel", RequestID: h.id(), SessionID: id, QueryID: command.QueryID})
	if ack == nil || ack.Status != "accepted" {
		t.Fatal("export Stop was not accepted")
	}
	response = h.receive()
	if response.Type != "error" || response.Category != "cancelled" {
		t.Fatal("cancelled export was reported as success")
	}
	preserved, _ := os.ReadFile(preserve)
	partial, _ := filepath.Glob(filepath.Join(directory, ".dbeer-export-*"))
	if string(preserved) != "original" || len(partial) != 0 {
		t.Fatal("failed/cancelled export replaced its destination or left a partial file")
	}
}
