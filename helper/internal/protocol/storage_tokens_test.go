package protocol

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestSharedOriginalRowStorageEvidence(t *testing.T) {
	raw, err := os.ReadFile("../../../protocol/fixtures/row-storage-evidence-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct{ Command json.RawMessage }
	if json.Unmarshal(raw, &fixture) != nil {
		t.Fatal("invalid storage fixture")
	}
	c, err := ParseCommand(fixture.Command)
	if err != nil || c.Changes.Changes[0].StorageToken != "pgrow-v1/16384/(0,1)/456" {
		t.Fatal("row evidence was lost")
	}
	encoded, _ := json.Marshal(c)
	if _, err := ParseCommand(encoded); err != nil {
		t.Fatal("row evidence did not round trip")
	}
	for _, replacement := range []string{`null`, `""`, `"line\nbreak"`, `"` + strings.Repeat("x", 4097) + `"`} {
		bad := strings.Replace(string(fixture.Command), `"pgrow-v1/16384/(0,1)/456"`, replacement, 1)
		if _, err := ParseCommand([]byte(bad)); err == nil {
			t.Fatal("invalid row storage evidence accepted")
		}
	}
}

func TestLongNativeTypeDefinitionsRemainBoundedAndEditable(t *testing.T) {
	value := "1"
	r := ChangesRequest{Schema: "fixture", Table: "items", Columns: []SnapshotColumn{{Name: "choice", Engine: "mysql", NativeType: "enum('" + strings.Repeat("label", 1000) + "')"}}, Changes: []RowChange{{Kind: "insert", Values: []ColumnAssignment{{Column: "choice", Value: CellValue{Kind: "text", Value: &value}}}}}}
	if !r.Valid() {
		t.Fatal("valid long native type definition rejected")
	}
	r.Columns[0].NativeType = strings.Repeat("x", 65537)
	if r.Valid() {
		t.Fatal("oversized native type definition accepted")
	}
}
