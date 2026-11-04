package sqlite_test

import (
	"context"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/session"
	"dbeer/helper/internal/sqlite"
	"encoding/base64"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"testing"
	"time"
)

func TestManagerConnectExecuteDisconnect(t *testing.T) {
	path := filepath.Join(t.TempDir(), "manager.sqlite")
	if err := sqlite.Create(context.Background(), path); err != nil {
		t.Fatal(err)
	}
	m := session.New(sqlite.Open)
	defer m.Close()
	receive := func() protocol.Response {
		t.Helper()
		select {
		case r := <-m.Responses():
			return r
		case <-time.After(5 * time.Second):
			t.Fatal("manager timed out")
			return protocol.Response{}
		}
	}
	m.Submit(protocol.Command{Type: "connect", RequestID: "connect", Connection: &protocol.Connection{Engine: "sqlite", SQLite: &protocol.SQLiteSettings{Path: path}}})
	r := receive()
	if r.Type != "connect.result" || r.Engine != "sqlite" {
		t.Fatalf("SQLite manager connection failed: %#v", r)
	}
	sid := r.SessionID
	m.Submit(protocol.Command{Type: "execute", RequestID: "read", SessionID: sid, QueryID: "query", SQL: "SELECT 42"})
	if r = receive(); r.Type != "query.started" {
		t.Fatal("manager omitted start")
	}
	if r = receive(); r.Type != "query.result" || r.SQLiteValues[0][0].Value != "42" {
		t.Fatal("manager lost typed result")
	}
	m.Submit(protocol.Command{Type: "disconnect", RequestID: "close", SessionID: sid})
	if r = receive(); r.Type != "disconnect.ack" {
		t.Fatal("manager did not disconnect")
	}
}

const mixedRowsSQL = `WITH RECURSIVE numbers(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM numbers WHERE n<1500)
SELECT n,CASE n%5 WHEN 0 THEN NULL WHEN 1 THEN n WHEN 2 THEN n+0.5 WHEN 3 THEN 'text' ELSE X'00ff' END AS mixed FROM numbers ORDER BY n`

func sqliteManager(t *testing.T, seed ...string) (*session.Manager, string, func() protocol.Response) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "stream.sqlite")
	if err := sqlite.Create(context.Background(), path); err != nil {
		t.Fatal(err)
	}
	if len(seed) > 0 {
		physical, err := sqlite.Open(context.Background(), protocol.Connection{Engine: "sqlite", SQLite: &protocol.SQLiteSettings{Path: path}})
		if err != nil {
			t.Fatal(err)
		}
		for _, sql := range seed {
			if result := physical.Execute(context.Background(), protocol.Command{Type: "execute", SQL: sql}); result.Type != "query.result" {
				physical.Close()
				t.Fatal("could not seed SQLite catalog")
			}
		}
		physical.Close()
	}
	m := session.New(sqlite.Open)
	t.Cleanup(m.Close)
	receive := func() protocol.Response {
		t.Helper()
		select {
		case r := <-m.Responses():
			return r
		case <-time.After(5 * time.Second):
			t.Fatal("SQLite manager timed out")
			return protocol.Response{}
		}
	}
	if !m.Submit(protocol.Command{Type: "connect", RequestID: "connect", Connection: &protocol.Connection{Engine: "sqlite", SQLite: &protocol.SQLiteSettings{Path: path}}}) {
		t.Fatal("manager rejected connection")
	}
	r := receive()
	if r.Type != "connect.result" {
		t.Fatal("manager did not connect")
	}
	return m, r.SessionID, receive
}

func TestSQLiteManagerStreamsCatalogMetadata(t *testing.T) {
	m, sid, receive := sqliteManager(t, "CREATE TABLE catalog_items(id INTEGER PRIMARY KEY,name TEXT)")
	for _, test := range []struct {
		name    string
		request protocol.CatalogRequest
		rows    int
		first   string
	}{
		{"schemas", protocol.CatalogRequest{Kind: "schemas"}, 1, "main"},
		{"objects", protocol.CatalogRequest{Kind: "objects", Schema: "main", ObjectKind: "table"}, 1, "catalog_items"},
		{"columns", protocol.CatalogRequest{Kind: "columns", Schema: "main", Object: "catalog_items", ObjectKind: "table"}, 2, "id"},
		{"foreignKeys", protocol.CatalogRequest{Kind: "foreignKeys", Schema: "main", Object: "catalog_items", ObjectKind: "table"}, 0, ""},
		{"completion", protocol.CatalogRequest{Kind: "completion"}, 1, "catalog_items"},
	} {
		t.Run(test.name, func(t *testing.T) {
			command := protocol.Command{Type: "catalog", RequestID: "catalog-" + test.name, SessionID: sid, QueryID: "metadata-" + test.name, Catalog: &test.request, Stream: true}
			if !m.Submit(command) {
				t.Fatal("manager rejected catalog request")
			}
			rows := [][]*string{}
			columns := []protocol.Column{}
			sequence := 0
			for {
				r := receive()
				if r.RequestID != command.RequestID || r.QueryID != command.QueryID || r.SessionID != sid {
					t.Fatal("metadata stream lost correlation")
				}
				switch r.Type {
				case "query.started":
				case "query.chunk":
					sequence++
					if r.Sequence != sequence || r.ResultIndex != 0 {
						t.Fatal("metadata stream sequence differs")
					}
					if r.Columns != nil {
						columns = r.Columns
					}
					rows = append(rows, r.Rows...)
					if reply := m.Control(protocol.Command{Type: "stream.ack", RequestID: "ack-" + test.name + strconv.Itoa(sequence), SessionID: sid, QueryID: command.QueryID, Sequence: sequence}); reply != nil {
						t.Fatal("metadata stream credit rejected")
					}
				case "query.result":
					if len(columns) == 0 || !r.Streamed || len(r.ResultSets) != 1 || len(rows) != test.rows || r.DisplayedRowCount != len(rows) || len(r.SQLiteValues) != len(rows) || r.ResultSets[0].DisplayedRowCount != len(rows) || len(r.ResultSets[0].Rows) != 0 {
						t.Fatal("metadata terminal omitted streamed rows or summary")
					}
					if len(rows) > 0 && (rows[0][0] == nil || *rows[0][0] != test.first) {
						t.Fatal("metadata result content differs")
					}
					for i, row := range r.SQLiteValues {
						if len(row) != len(rows[i]) {
							t.Fatal("metadata sidecar width differs")
						}
						for j, v := range row {
							if v.Type == "null" {
								if rows[i][j] != nil {
									t.Fatal("NULL metadata changed")
								}
								continue
							}
							if v.Type == "text" {
								b, e := base64.StdEncoding.DecodeString(v.Value)
								if e != nil || rows[i][j] == nil || string(b) != *rows[i][j] {
									t.Fatal("metadata sidecar diverges from stream")
								}
							}
						}
					}
					return
				default:
					t.Fatal("metadata streaming failed")
				}
			}
		})
	}
}

func checkMixedTypedRow(t *testing.T, n int, row []protocol.SQLiteValue, display []*string) {
	t.Helper()
	if len(row) != 2 || row[0].Type != "integer" || row[0].Value != strconv.Itoa(n) {
		t.Fatal("typed row identity differs from requested prefix")
	}
	wantType := []string{"null", "integer", "real", "text", "blob"}[n%5]
	if row[1].Type != wantType {
		t.Fatal("mixed column lost its per-cell storage class")
	}
	var value *string
	switch wantType {
	case "null":
		if row[1].Value != "" {
			t.Fatal("NULL has a payload")
		}
	case "integer":
		if row[1].Value != strconv.Itoa(n) {
			t.Fatal("integer payload changed")
		}
		v := strconv.Itoa(n)
		value = &v
	case "real":
		bits, err := strconv.ParseUint(row[1].Value, 16, 64)
		if err != nil || math.Float64frombits(bits) != float64(n)+0.5 {
			t.Fatal("REAL payload changed")
		}
		v := strconv.FormatFloat(float64(n)+0.5, 'g', -1, 64)
		value = &v
	case "text":
		bytes, err := base64.StdEncoding.DecodeString(row[1].Value)
		if err != nil || string(bytes) != "text" {
			t.Fatal("TEXT payload changed")
		}
		v := "text"
		value = &v
	case "blob":
		bytes, err := base64.StdEncoding.DecodeString(row[1].Value)
		if err != nil || !reflect.DeepEqual(bytes, []byte{0, 255}) {
			t.Fatal("BLOB payload changed")
		}
		v := "AP8="
		value = &v
	}
	if display != nil {
		first := strconv.Itoa(n)
		if !reflect.DeepEqual(display, []*string{&first, value}) {
			t.Fatal("typed terminal values do not match streamed display rows")
		}
	}
}

func TestSQLiteManagerStreamingPreservesTypedPrefix(t *testing.T) {
	m, sid, receive := sqliteManager(t)
	command := protocol.Command{Type: "execute", RequestID: "stream", SessionID: sid, QueryID: "mixed", SQL: mixedRowsSQL, Stream: true}
	if !m.Submit(command) {
		t.Fatal("manager rejected stream")
	}
	rows := [][]*string{}
	sequence := 0
	started := false
	for {
		r := receive()
		if r.RequestID != command.RequestID || r.QueryID != command.QueryID || r.SessionID != sid {
			t.Fatal("stream lost correlation")
		}
		switch r.Type {
		case "query.started":
			if started {
				t.Fatal("stream repeated its start")
			}
			started = true
		case "query.chunk":
			sequence++
			if !started || r.Sequence != sequence || r.ResultIndex != 0 {
				t.Fatal("stream credit sequence changed")
			}
			if r.Columns != nil && len(r.Columns) != 2 {
				t.Fatal("stream columns were lost")
			}
			rows = append(rows, r.Rows...)
			if reply := m.Control(protocol.Command{Type: "stream.ack", RequestID: "ack-" + strconv.Itoa(sequence), SessionID: sid, QueryID: command.QueryID, Sequence: sequence}); reply != nil {
				t.Fatal("stream credit was rejected")
			}
		case "query.result":
			if !r.Streamed || !r.Truncated || r.RowCount != 1500 || len(rows) != 1000 || r.DisplayedRowCount != len(rows) || len(r.SQLiteValues) != len(rows) || len(r.ResultSets) != 1 {
				t.Fatal("stream did not retain one exact typed display prefix")
			}
			if len(r.ResultSets[0].Rows) != 0 || r.ResultSets[0].DisplayedRowCount != len(rows) || !reflect.DeepEqual(r.ResultSets[0].SQLiteValues, r.SQLiteValues) {
				t.Fatal("stream terminal duplicated or diverged from typed summary")
			}
			for i, row := range r.SQLiteValues {
				checkMixedTypedRow(t, i+1, row, rows[i])
			}
			return
		default:
			t.Fatal("stream did not complete successfully")
		}
	}
}

func TestSQLiteManagerRunToFileExportsAllTypedRows(t *testing.T) {
	m, sid, receive := sqliteManager(t)
	path := filepath.Join(t.TempDir(), "complete.json")
	command := protocol.Command{Type: "execute", RequestID: "export", SessionID: sid, QueryID: "all-typed", SQL: mixedRowsSQL, Export: &protocol.ExportRequest{Path: path, Format: "json"}}
	if !m.Submit(command) {
		t.Fatal("manager rejected export")
	}
	if r := receive(); r.Type != "query.started" {
		t.Fatal("export did not start")
	}
	r := receive()
	if r.Type != "query.result" || r.ExportRowCount != 1500 || r.RowCount != 1500 || r.ExportPath != path {
		t.Fatal("export did not publish complete SQL execution")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var document struct {
		Version    int `json:"version"`
		ResultSets []struct {
			Rows     [][]protocol.SQLiteValue `json:"rows"`
			Metadata struct {
				RowCount  int64 `json:"rowCount"`
				Truncated bool  `json:"truncated"`
			} `json:"metadata"`
		} `json:"resultSets"`
	}
	if err = json.Unmarshal(data, &document); err != nil || document.Version != 1 || len(document.ResultSets) != 1 || len(document.ResultSets[0].Rows) != 1500 || document.ResultSets[0].Metadata.RowCount != 1500 || document.ResultSets[0].Metadata.Truncated {
		t.Fatal("export did not preserve full typed JSON rows")
	}
	for i, row := range document.ResultSets[0].Rows {
		checkMixedTypedRow(t, i+1, row, nil)
	}
}
