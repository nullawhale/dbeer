package sqllsp

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"testing"
)

func rpc(method string, id any, params any) map[string]any {
	m := map[string]any{"jsonrpc": "2.0", "method": method, "params": params}
	if id != nil {
		m["id"] = id
	}
	return m
}
func testRun(t *testing.T, messages ...any) []map[string]json.RawMessage {
	t.Helper()
	var input, output bytes.Buffer
	w := transport{writer: &input}
	for _, m := range messages {
		if err := w.write(m); err != nil {
			t.Fatal(err)
		}
	}
	if err := Run(&input, &output); err != nil {
		t.Fatal(err)
	}
	r := transport{reader: bufio.NewReader(&output)}
	responses := []map[string]json.RawMessage{}
	for {
		body, err := r.read()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		var response map[string]json.RawMessage
		if err = json.Unmarshal(body, &response); err != nil {
			t.Fatal(err)
		}
		responses = append(responses, response)
	}
	return responses
}
func open(uri, engine, text string, version int) map[string]any {
	return rpc("textDocument/didOpen", nil, map[string]any{"textDocument": map[string]any{"uri": uri, "languageId": engine, "text": text, "version": version}})
}
func change(uri, text string, version int) map[string]any {
	return rpc("textDocument/didChange", nil, map[string]any{"textDocument": map[string]any{"uri": uri, "version": version}, "contentChanges": []any{map[string]any{"text": text}}})
}
func configurationMessage(uri, engine string, catalog []catalogEntry) map[string]any {
	return rpc("workspace/didChangeConfiguration", nil, map[string]any{"settings": map[string]any{"dbeer": configuration{URI: uri, Engine: engine, Catalog: catalog}}})
}
func completion(uri string, p position, id int) map[string]any {
	return rpc("textDocument/completion", id, map[string]any{"textDocument": map[string]any{"uri": uri}, "position": p})
}
func resultItems(t *testing.T, response map[string]json.RawMessage) []completionItem {
	t.Helper()
	var result struct {
		Items []completionItem `json:"items"`
	}
	if err := json.Unmarshal(response["result"], &result); err != nil {
		t.Fatal(err)
	}
	return result.Items
}
func itemWithLabel(items []completionItem, label string) (completionItem, bool) {
	for _, item := range items {
		if item.Label == label {
			return item, true
		}
	}
	return completionItem{}, false
}

func TestProtocolLifecycleAndCurrentDiagnostics(t *testing.T) {
	uri := "dbeer-sql:///one.sql"
	responses := testRun(t,
		rpc("textDocument/completion", 1, map[string]any{}),
		rpc("initialize", "init", map[string]any{}), rpc("initialized", nil, map[string]any{}),
		open(uri, "postgresql", "SELECT (", 1),
		change(uri, "SELECT CO", 3), change(uri, "SELECT (", 2), change(uri, "SELECT '", 3),
		completion(uri, position{Character: 9}, 2),
		rpc("textDocument/didClose", nil, map[string]any{"textDocument": map[string]any{"uri": uri}}),
		completion(uri, position{}, 3), rpc("shutdown", 4, nil), rpc("exit", nil, nil),
	)
	if len(responses) != 8 {
		t.Fatalf("got %d responses", len(responses))
	}
	var initialError struct {
		Code int `json:"code"`
	}
	_ = json.Unmarshal(responses[0]["error"], &initialError)
	if initialError.Code != -32002 {
		t.Fatalf("unexpected initial error: %s", responses[0]["error"])
	}
	var initialized struct {
		Capabilities struct {
			PositionEncoding string `json:"positionEncoding"`
			TextDocumentSync struct {
				Change int `json:"change"`
			} `json:"textDocumentSync"`
		} `json:"capabilities"`
	}
	_ = json.Unmarshal(responses[1]["result"], &initialized)
	if initialized.Capabilities.PositionEncoding != "utf-16" || initialized.Capabilities.TextDocumentSync.Change != 1 {
		t.Fatal("missing protocol capabilities")
	}
	for i, want := range []int{1, 3} {
		var params struct {
			URI         string       `json:"uri"`
			Version     int          `json:"version"`
			Diagnostics []diagnostic `json:"diagnostics"`
		}
		_ = json.Unmarshal(responses[i+2]["params"], &params)
		if params.URI != uri || params.Version != want {
			t.Fatalf("unexpected diagnostic envelope: %s", responses[i+2]["params"])
		}
		if (i == 0) != (len(params.Diagnostics) > 0) {
			t.Fatalf("unexpected diagnostics: %s", responses[i+2]["params"])
		}
	}
	if _, ok := itemWithLabel(resultItems(t, responses[4]), "COALESCE"); !ok {
		t.Fatal("stale change replaced current document")
	}
	if len(resultItems(t, responses[6])) != 0 {
		t.Fatal("closed document retained completions")
	}
	if string(responses[7]["result"]) != "null" {
		t.Fatal("shutdown must return null")
	}
}

func TestConfigurationIsolationAndDialectRefresh(t *testing.T) {
	a, b := "dbeer-sql:///a.sql", "dbeer-sql:///b.sql"
	catalog := []catalogEntry{{Schema: "public", Name: "users", Kind: "table", Columns: []string{"id"}}}
	responses := testRun(t, rpc("initialize", 1, nil),
		configurationMessage(a, "postgresql", catalog), open(a, "sql", "SELECT ", 1),
		configurationMessage(b, "mysql", nil), open(b, "sql", "SELECT ", 1),
		completion(a, position{Character: 7}, 2), completion(b, position{Character: 7}, 3),
		configurationMessage(a, "mysql", nil), completion(a, position{Character: 7}, 4),
		rpc("shutdown", 5, nil), rpc("exit", nil, nil))
	postgres, mysql, updated := resultItems(t, responses[3]), resultItems(t, responses[4]), resultItems(t, responses[6])
	if _, ok := itemWithLabel(postgres, "DATE_TRUNC"); !ok {
		t.Fatal("missing PostgreSQL function")
	}
	if _, ok := itemWithLabel(postgres, "users"); !ok {
		t.Fatal("missing supplied catalog")
	}
	for _, items := range [][]completionItem{mysql, updated} {
		if _, ok := itemWithLabel(items, "DATE_FORMAT"); !ok {
			t.Fatal("missing MySQL function")
		}
		if _, ok := itemWithLabel(items, "DATE_TRUNC"); ok {
			t.Fatal("PostgreSQL function leaked")
		}
		if _, ok := itemWithLabel(items, "users"); ok {
			t.Fatal("catalog leaked")
		}
	}
}

func TestTransportBoundsAndRecovery(t *testing.T) {
	for _, header := range []string{"Content-Length: 4194305\r\n\r\n", "Content-Length: 1\r\nContent-Length: 1\r\n\r\nx", "Content-Length: -1\r\n\r\n", "Content-Length: 3\r\n\r\nx", strings.Repeat("x", 17000)} {
		if err := Run(strings.NewReader(header), io.Discard); err == nil {
			t.Fatal("accepted malformed or excessive frame")
		}
	}
	var input, output bytes.Buffer
	input.WriteString("Content-Length: 1\r\n\r\n{")
	w := transport{writer: &input}
	_ = w.write(rpc("initialize", 1, nil))
	_ = w.write(rpc("shutdown", 2, nil))
	_ = w.write(rpc("exit", nil, nil))
	if err := Run(&input, &output); err != nil {
		t.Fatal(err)
	}
	r := transport{reader: bufio.NewReader(&output)}
	body, err := r.read()
	if err != nil || !bytes.Contains(body, []byte(`"code":-32700`)) {
		t.Fatal("missing parse error")
	}
	var earlyExit bytes.Buffer
	earlyWriter := transport{writer: &earlyExit}
	_ = earlyWriter.write(rpc("exit", nil, nil))
	if err := Run(&earlyExit, io.Discard); err == nil {
		t.Fatal("exit without shutdown accepted")
	}
}

func TestDocumentAndCatalogLimits(t *testing.T) {
	s := server{documents: map[string]document{}, contexts: map[string]configuration{}}
	if s.acceptDocument("", "") || s.acceptDocument("x", strings.Repeat("x", maxDocumentBytes+1)) {
		t.Fatal("document bound not enforced")
	}
	for i := 0; i < maxDocuments; i++ {
		s.documents[fmt.Sprint(i)] = document{}
	}
	if s.acceptDocument("extra", "") || !s.acceptDocument("0", "SELECT") {
		t.Fatal("open-document bound not enforced")
	}
	if boundedConfiguration(configuration{URI: "x", Engine: "other"}) || boundedConfiguration(configuration{URI: "x", Engine: "mysql", Catalog: make([]catalogEntry, maxCatalogEntries+1)}) {
		t.Fatal("invalid catalog accepted")
	}
}

func TestOversizeChangeInvalidatesOldSnapshot(t *testing.T) {
	uri := "dbeer-sql:///large.sql"
	responses := testRun(t, rpc("initialize", 1, nil), open(uri, "sql", "SELECT CO", 1),
		change(uri, strings.Repeat("x", maxDocumentBytes+1), 2), completion(uri, position{Character: 9}, 2),
		change(uri, "SELECT CO", 3), completion(uri, position{Character: 9}, 3), rpc("shutdown", 4, nil), rpc("exit", nil, nil))
	if len(resultItems(t, responses[3])) != 0 {
		t.Fatal("oversize change retained old completion snapshot")
	}
	var params struct {
		Version     int          `json:"version"`
		Diagnostics []diagnostic `json:"diagnostics"`
	}
	_ = json.Unmarshal(responses[2]["params"], &params)
	if params.Version != 2 || len(params.Diagnostics) != 0 {
		t.Fatal("oversize change retained old diagnostics")
	}
	if _, ok := itemWithLabel(resultItems(t, responses[5]), "COALESCE"); !ok {
		t.Fatal("small document did not recover")
	}
}
