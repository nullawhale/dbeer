package protocol

import (
	"encoding/json"
	"testing"
)

func TestPolicyAssessmentRejectsAmbiguousOrIncompletePayloads(t *testing.T) {
	for _, operations := range []string{
		`null`, `[]`, `[null]`, `[{"type":"execute","sql":"SELECT 1","changes":null}]`,
		`[{"type":"execute","SQL":"SELECT 1"}]`, `[{"type":"execute","sql":"SELECT 1","Type":"execute"}]`,
		`[{"type":"execute","sql":"SELECT 1","export":null}]`,
		`[{"type":"execute","sql":"SELECT 1","export":{"path":"/tmp/file.json","format":"json","password":"secret"}}]`,
		`[{"type":"changes.apply","changes":null}]`, `[{"type":"catalog","sql":"SELECT 1"}]`,
	} {
		_, err := ParseCommand([]byte(`{"type":"operation.assess","requestId":"r","sessionId":"s","queryId":"q","operations":` + operations + `}`))
		if err == nil {
			t.Fatal("invalid operation payload was accepted")
		}
	}
	for _, policy := range []string{`null`, `{}`, `{"environment":"production"}`, `{"environment":"production","readOnly":null}`, `{"environment":"production","readOnly":"false"}`, `{"environment":"unknown","readOnly":false}`, `{"Environment":"production","readOnly":false}`, `{"environment":"production","readOnly":false,"sql":"secret"}`} {
		_, err := ParseCommand([]byte(`{"type":"connect","requestId":"r","connection":{"host":"localhost","port":5432,"database":"db","user":"user","password":"","sslMode":"disable","policy":` + policy + `}}`))
		if err == nil {
			t.Fatal("invalid session policy was accepted")
		}
	}
}

func TestTypedApplyAndExportAssessmentRoundTrip(t *testing.T) {
	value := "9007199254740993.123456789"
	operations := []OperationRequest{
		{Type: "execute", SQL: "SELECT 1", Export: &ExportRequest{Path: "/tmp/approved.json", Format: "json"}},
		{Type: "changes.apply", Changes: &ChangesRequest{Schema: "public", Table: "demo", Columns: []SnapshotColumn{{Name: "value", Engine: "postgresql", NativeType: "numeric"}}, Changes: []RowChange{{Kind: "insert", Values: []ColumnAssignment{{Column: "value", Value: CellValue{Kind: "text", Value: &value}}}}}}},
	}
	command := Command{Type: "operation.assess", RequestID: "r", SessionID: "s", QueryID: "q", Operations: operations}
	encoded, err := json.Marshal(command)
	if err != nil {
		t.Fatal("cannot encode typed assessment")
	}
	parsed, err := ParseCommand(encoded)
	if err != nil || len(parsed.Operations) != 2 || *parsed.Operations[1].Changes.Changes[0].Values[0].Value.Value != value {
		t.Fatal("typed values lost in assessment")
	}
}
