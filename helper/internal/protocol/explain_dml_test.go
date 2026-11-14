package protocol

import (
	"encoding/json"
	"os"
	"testing"
)

func TestExplainDMLSharedContract(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/explain-dml-v1/contract.json")
	if err != nil {
		t.Fatal("missing shared DML fixture")
	}
	var f struct {
		Version         int
		Capability      string
		Commands        []json.RawMessage
		InvalidCommands []struct {
			ID      string
			Command json.RawMessage
		}
		Outcomes      []ExplainDMLResult
		MySQLOutcomes []ExplainDMLResult
		Supports      []struct {
			Engine string
			DML    ExplainDMLSupport
		}
	}
	if json.Unmarshal(data, &f) != nil || f.Version != 1 || f.Capability != ExplainDMLCapability {
		t.Fatal("invalid shared DML fixture")
	}
	for i, raw := range f.Commands {
		c, err := ParseCommand(raw)
		if err != nil || c.Explain == nil || !c.Explain.Valid() {
			t.Fatalf("valid DML command %d rejected", i)
		}
	}
	for _, item := range f.InvalidCommands {
		if _, err := ParseCommand(item.Command); err == nil {
			t.Fatalf("invalid DML command accepted: %s", item.ID)
		}
	}
	for _, r := range f.Outcomes {
		mode := "analyze"
		if r.Execution == "estimated" {
			mode = "plan"
		}
		if !r.Valid("postgresql", mode) {
			t.Fatal("DML outcome rejected")
		}
	}
	for _, r := range f.MySQLOutcomes {
		if !r.Valid("mysql", "analyze") {
			t.Fatal("MySQL suppressed-target outcome rejected")
		}
	}
	for _, s := range f.Supports {
		if !s.DML.Valid(s.Engine) {
			t.Fatal("DML support rejected")
		}
	}
	for _, raw := range []string{`{"disposition":"currentSession","expectedTransactionStatus":"idle","expectedTransactionStatus":"transaction"}`, `{"disposition":"currentSession","expectedTransactionStatus":"idle","commit":null}`, `null`} {
		command := `{"type":"explain.run","requestId":"r","sessionId":"s","queryId":"q","explain":{"sql":"UPDATE t SET n=1","mode":"analyze","context":{"documentId":"d","targetDocumentId":"d","rangeLocation":0,"rangeLength":16,"profileId":"p","sessionId":"s","transactionStatus":"idle"},"writeIntent":` + raw + `}}`
		if _, err := ParseCommand([]byte(command)); err == nil {
			t.Fatal("ambiguous DML authority accepted")
		}
	}
}
