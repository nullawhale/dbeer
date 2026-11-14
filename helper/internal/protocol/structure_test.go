package protocol

import (
	"encoding/json"
	"os"
	"testing"
)

func TestStructureSharedContract(t *testing.T) {
	b, e := os.ReadFile("../../../protocol/fixtures/table-structure-editor-v1.json")
	if e != nil {
		t.Fatal(e)
	}
	var f struct {
		Valid   []json.RawMessage `json:"valid"`
		Invalid []string          `json:"invalid"`
	}
	if json.Unmarshal(b, &f) != nil {
		t.Fatal("invalid fixture")
	}
	for i, b := range f.Valid {
		if _, e := ParseCommand(b); e != nil {
			t.Errorf("valid case %d rejected", i)
		}
	}
	for i, b := range f.Invalid {
		if _, e := ParseCommand([]byte(b)); e == nil {
			t.Errorf("invalid case %d accepted", i)
		}
	}
}
func TestStructureOperationCannotHideFields(t *testing.T) {
	for _, b := range []string{`[{"type":"execute","sql":"SELECT 1","structure":{"planId":"p","digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","executionId":"e"}}]`, `[{"type":"structure.apply","structure":{"planId":"p","digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","executionId":"e"},"sql":"DROP TABLE t"}]`} {
		if _, ok := parseOperations([]byte(b)); ok {
			t.Fatal("mixed operation accepted")
		}
	}
}

func TestStructureSessionPurposeIsAdditiveAndStrict(t *testing.T) {
	base := `{"type":"connect","requestId":"r","connection":{"engine":"postgresql","host":"fixture.invalid","port":5432,"database":"fixture","user":"fixture","password":"","sslMode":"disable"`
	for _, suffix := range []string{`}}`, `,"sessionPurpose":"structure"}}`} {
		if _, e := ParseCommand([]byte(base + suffix)); e != nil {
			t.Fatal("valid purpose contract rejected")
		}
	}
	for _, suffix := range []string{`,"sessionPurpose":"sql"}}`, `,"sessionPurpose":null}}`, `,"sessionPurpose":true}}`} {
		if _, e := ParseCommand([]byte(base + suffix)); e == nil {
			t.Fatal("invalid purpose accepted")
		}
	}
}

func TestStructureAuthoringV2SharedContract(t *testing.T) {
	b, e := os.ReadFile("../../../protocol/fixtures/table-structure-authoring-v2.json")
	if e != nil {
		t.Fatal(e)
	}
	var f struct {
		Valid   []json.RawMessage `json:"valid"`
		Invalid []string          `json:"invalid"`
	}
	if json.Unmarshal(b, &f) != nil {
		t.Fatal("invalid fixture")
	}
	for i, b := range f.Valid {
		if _, e := ParseCommand(b); e != nil {
			t.Errorf("valid authoring case %d rejected", i)
		}
	}
	for i, b := range f.Invalid {
		if _, e := ParseCommand([]byte(b)); e == nil {
			t.Errorf("invalid authoring case %d accepted", i)
		}
	}
}
