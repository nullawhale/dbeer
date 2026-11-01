package protocol

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func importFixture(t *testing.T) map[string]json.RawMessage {
	t.Helper()
	data, err := os.ReadFile("../../../protocol/fixtures/table-import-v1.json")
	if err != nil {
		t.Fatal("read import fixture")
	}
	var f map[string]json.RawMessage
	if json.Unmarshal(data, &f) != nil {
		t.Fatal("decode import fixture")
	}
	return f
}

func TestTableImportSharedFixtureStrictCommandsAndReplies(t *testing.T) {
	f := importFixture(t)
	for _, name := range []string{"describe", "preview", "apply", "assessment"} {
		command, err := ParseCommand(f[name])
		if err != nil {
			t.Fatalf("decode %s", name)
		}
		if name == "assessment" {
			if command.Operations[0].TableImport == nil {
				t.Fatal("assessment lost import")
			}
		} else if command.TableImport == nil {
			t.Fatal("missing import")
		}
	}
	command, _ := ParseCommand(f["apply"])
	if command.TableImport.Rows[0][2].Kind != "null" || *command.TableImport.Rows[1][0].Value != "" || *command.TableImport.Rows[0][0].Value != "NULL" {
		t.Fatal("null, empty and text NULL conflated")
	}
	for _, kind := range []string{"import.describe.result", "import.preview.result", "import.apply.result", "error"} {
		count, row := 2, 1
		response := Response{Type: kind, RequestID: "import", Connected: true, TransactionStatus: "idle", TableImport: &TableImportReply{RowCount: &count}}
		if kind == "error" {
			response.TableImport = &TableImportReply{Row: &row}
		}
		data, err := json.Marshal(response)
		if err != nil || !strings.Contains(string(data), `"tableImport"`) {
			t.Fatal("import reply omitted")
		}
	}
}

func TestTableImportRejectsMalformedAndOversizedPayloads(t *testing.T) {
	f := importFixture(t)
	var frame map[string]any
	_ = json.Unmarshal(f["apply"], &frame)
	for _, mutate := range []func(map[string]any){
		func(r map[string]any) { r["extra"] = true }, func(r map[string]any) { r["fingerprint"] = "bad" }, func(r map[string]any) { r["columns"] = []string{"x", "x"} }, func(r map[string]any) { r["rows"] = [][]any{{map[string]any{"kind": "default"}}} }, func(r map[string]any) {
			r["rows"] = [][]any{{map[string]any{"kind": "text", "value": "a", "extra": true}}}
		}, func(r map[string]any) {
			r["columns"] = []string{"x"}
			r["rows"] = [][]any{{map[string]any{"kind": "text", "value": "\x00"}}}
		}, func(r map[string]any) {
			r["columns"] = []string{"x"}
			r["rows"] = [][]any{{map[string]any{"kind": "binary", "value": "AA==\n"}}}
		}, func(r map[string]any) {
			r["columns"] = []string{"x"}
			r["rows"] = [][]any{{map[string]any{"kind": "null", "value": nil}}}
		},
	} {
		var copy map[string]any
		_ = json.Unmarshal(f["apply"], &copy)
		mutate(copy["tableImport"].(map[string]any))
		raw, _ := json.Marshal(copy)
		if _, err := ParseCommand(raw); err == nil {
			t.Fatal("invalid import accepted")
		}
	}
	command, _ := ParseCommand(f["apply"])
	request := *command.TableImport
	large := strings.Repeat("x", MaxImportValueBytes+1)
	request.Columns = []string{"label"}
	request.Rows = [][]CellValue{{{Kind: "text", Value: &large}}}
	if request.Valid("import.apply") {
		t.Fatal("value budget ignored")
	}
	if (&TableImportRequest{Schema: "s", Table: "t", Columns: []string{}}).Valid("import.describe") {
		t.Fatal("describe accepted write fields")
	}
	var assessment map[string]any
	_ = json.Unmarshal(f["assessment"], &assessment)
	assessment["operations"].([]any)[0].(map[string]any)["type"] = "execute"
	assessment["operations"].([]any)[0].(map[string]any)["sql"] = "SELECT 1"
	raw, _ := json.Marshal(assessment)
	if _, err := ParseCommand(raw); err == nil {
		t.Fatal("non-import operation silently ignored tableImport")
	}
}
