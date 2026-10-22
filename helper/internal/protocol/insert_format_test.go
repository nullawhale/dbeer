package protocol

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestSharedOfflineInsertCommands(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/copy-inserts-v1/cases.json")
	if err != nil {
		t.Fatal("shared INSERT fixtures are unavailable")
	}
	var fixture struct {
		Version         int
		Cases           []struct{ Command json.RawMessage }
		InvalidCommands []string
	}
	if json.Unmarshal(data, &fixture) != nil || fixture.Version != 1 || len(fixture.Cases) < 3 || len(fixture.InvalidCommands) < 10 {
		t.Fatal("invalid shared INSERT fixture")
	}
	for index, item := range fixture.Cases {
		command, err := ParseCommand(item.Command)
		if err != nil || command.Insert == nil || command.Type != "formatInserts" || command.SessionID != "" || command.QueryID != "" {
			t.Fatalf("valid offline INSERT fixture %d rejected", index)
		}
		encoded, _ := json.Marshal(command)
		if _, err := ParseCommand(encoded); err != nil {
			t.Fatal("offline INSERT command failed round trip")
		}
	}
	for index, raw := range fixture.InvalidCommands {
		_, err := ParseCommand([]byte(raw))
		if err == nil || strings.Contains(err.Error(), "sensitive") {
			t.Fatalf("invalid offline INSERT fixture %d accepted or exposed data", index)
		}
	}
}

func TestOfflineInsertBoundsAndTypedCells(t *testing.T) {
	text := ""
	request := InsertFormatRequest{Engine: "postgresql", Schema: "public", Table: "target", Columns: []InsertFormatColumn{{Name: "v"}}, Rows: [][]CellValue{{{Kind: "text", Value: &text}}}}
	if !request.Valid() {
		t.Fatal("empty text must remain a valid value")
	}
	for _, kind := range []string{"null", "default"} {
		request.Rows[0][0] = CellValue{Kind: kind}
		if !request.Valid() {
			t.Fatal("typed NULL and DEFAULT rejected")
		}
		request.Rows[0][0].Value = &text
		if request.Valid() {
			t.Fatal("NULL and DEFAULT cannot contain text")
		}
	}
	request.Rows = make([][]CellValue, MaxInsertRows+1)
	if request.Valid() {
		t.Fatal("too many rows accepted")
	}
	request.Rows = [][]CellValue{{{Kind: "null"}}}
	request.Columns = make([]InsertFormatColumn, MaxInsertColumns+1)
	if request.Valid() {
		t.Fatal("too many columns accepted")
	}
	request.Columns = []InsertFormatColumn{{Name: "v"}}
	text = strings.Repeat("x", MaxInsertBytes)
	request.Rows = [][]CellValue{{{Kind: "text", Value: &text}}}
	if request.Valid() {
		t.Fatal("combined input byte bound not enforced")
	}
}
