package sqllsp

import (
	"dbeer/helper/internal/sqlcomplete"
	"encoding/json"
	"strings"
	"testing"
)

func editorRPC(method, uri string, id int, extra map[string]any) map[string]any {
	if extra == nil {
		extra = map[string]any{}
	}
	extra["textDocument"] = map[string]any{"uri": uri}
	return rpc(method, id, extra)
}
func TestEditorToolsVersionAndUTF16(t *testing.T) {
	uri := "file:///editor.sql"
	text := "SELECT '🌍';\r\nSELECT u.id FROM users u;"
	responses := testRun(t, rpc("initialize", 1, map[string]any{}), open(uri, "sql", text, 7), configurationMessage(uri, "postgresql", []catalogEntry{{Schema: "public", Name: "users", Kind: "table", Columns: []string{"id"}}}), editorRPC("dbeer/editorAnalysis", uri, 2, map[string]any{"position": position{Line: 1, Character: 8}}), editorRPC("dbeer/format", uri, 3, map[string]any{"options": map[string]any{"insertSpaces": true, "tabSize": 4}}), rpc("shutdown", 4, nil), rpc("exit", nil, nil))
	foundAnalysis, foundFormat := false, false
	for _, response := range responses {
		if string(response["id"]) == "2" {
			var value struct {
				Version    int
				References []textRange
				Symbols    []struct{ Range textRange }
			}
			if err := json.Unmarshal(response["result"], &value); err != nil {
				t.Fatal(err)
			}
			if value.Version != 7 || len(value.References) != 2 || len(value.Symbols) != 2 {
				t.Fatalf("invalid analysis: %s", response["result"])
			}
			if value.References[0].Start != (position{1, 7}) {
				t.Fatal("wrong UTF16 reference", value.References)
			}
			foundAnalysis = true
		}
		if string(response["id"]) == "3" {
			var value struct {
				Version int
				Edits   []textEdit
			}
			if err := json.Unmarshal(response["result"], &value); err != nil {
				t.Fatal(err)
			}
			if value.Version != 7 || len(value.Edits) != 1 || value.Edits[0].Range.End != positionAt(text, len(text)) {
				t.Fatal("invalid versioned format")
			}
			foundFormat = true
		}
	}
	if !foundAnalysis || !foundFormat {
		t.Fatal("missing editor responses")
	}
}
func TestEditorFormattingRejectsPartialLiteralWithoutEdits(t *testing.T) {
	uri := "file:///partial.sql"
	responses := testRun(t, rpc("initialize", 1, nil), open(uri, "sql", "SELECT 'a   b'", 1), editorRPC("dbeer/format", uri, 2, map[string]any{"range": textRange{position{0, 9}, position{0, 12}}}), rpc("shutdown", 3, nil), rpc("exit", nil, nil))
	for _, response := range responses {
		if string(response["id"]) == "2" {
			var v struct {
				Error string
				Edits []textEdit
			}
			_ = json.Unmarshal(response["result"], &v)
			if v.Error == "" || len(v.Edits) != 0 {
				t.Fatal("partial literal changed")
			}
			return
		}
	}
	t.Fatal("missing response")
}
func TestEditorPositionIndexMatchesExistingConversion(t *testing.T) {
	text := "🌍\r\nSELECT (\n1\n);\rSELECT 2;"
	a := sqlcomplete.AnalyzeEditor(text, 0, sqlcomplete.Context{Engine: "postgresql"})
	index := editorPositionIndex(text, a)
	for _, s := range a.Symbols {
		for _, offset := range []int{s.Range.Start, s.Range.End, s.Selection.Start, s.Selection.End} {
			if index(offset) != positionAt(text, offset) {
				t.Fatal("position mismatch", offset, index(offset), positionAt(text, offset))
			}
		}
	}
}
func TestEditorBoundedLargeResponse(t *testing.T) {
	text := strings.Repeat("SELECT (\n 1\n);\n", 10000)
	a := sqlcomplete.AnalyzeEditor(text, 0, sqlcomplete.Context{Engine: "postgresql"})
	positions := editorPositionIndex(text, a)
	for _, span := range a.Folds {
		if positions(span.End).Line < 0 {
			t.Fatal("bad position")
		}
	}
}
