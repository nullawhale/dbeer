package protocol

import (
	"encoding/json"
	"os"
	"testing"
)

func TestEngineDiagnosticSharedContractAndClosedKinds(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/engine-diagnostics-v1/contract.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Version    int
		Capability string
		Fixtures   []struct {
			Name    string
			Request ExplainRequest
			Result  ExplainResult
		}
	}
	if json.Unmarshal(data, &fixture) != nil || fixture.Version != 1 || fixture.Capability != EngineDiagnosticsCapability || len(fixture.Fixtures) != 2 {
		t.Fatal("invalid shared fixture")
	}
	for _, f := range fixture.Fixtures {
		if !f.Request.Valid() || !f.Result.Valid() {
			t.Fatalf("invalid %s", f.Name)
		}
		if f.Result.Support.Engine == "cassandra" {
			complete := f.Result
			complete.Complete = true
			if complete.Valid() {
				t.Fatal("eventual trace capture falsely claimed complete")
			}
		}
		wrong := f.Result
		wrong.Support.Engine = "postgresql"
		if wrong.Valid() {
			t.Fatal("engine/kind mismatch admitted")
		}
		wrong = f.Result
		wrong.Nodes = []ExplainNode{{ID: "fake"}}
		if wrong.Valid() {
			t.Fatal("diagnostic admitted fabricated plan nodes")
		}
	}
	for _, input := range []string{`{"kind":"future","mongodb":{}}`, `{"kind":"mongodbExplain","mongodb":null}`, `{"kind":"mongodbExplain","mongodb":{},"cassandra":null}`, `{"kind":"mongodbExplain","mongodb":{},"sessionId":"private"}`} {
		var d EngineDiagnostic
		if json.Unmarshal([]byte(input), &d) == nil {
			t.Fatal("unknown or injected union payload admitted")
		}
	}
	m := DiagnosticMetric{Unit: "us", Basis: "sourceElapsed", UnavailableReason: "notReported"}
	if !m.Valid() {
		t.Fatal("missing elapsed invalid")
	}
	negative := "-1"
	m.Value = &negative
	m.UnavailableReason = ""
	if m.Valid() {
		t.Fatal("negative elapsed admitted")
	}
}
func TestEngineDiagnosticCapabilityAndOwnerContextBoundary(t *testing.T) {
	for _, s := range []ExplainSupport{{Engine: "cassandra", ServerVersion: "5.0", Format: "cassandraTrace", DiagnosticModel: "cassandraTrace", Modes: []string{"plan"}}, {Engine: "mongodb", ServerVersion: "8.0", Format: "mongodbExplain", Modes: []string{"plan", "analyze"}}, {Engine: "postgresql", ServerVersion: "17", Format: "json", DiagnosticModel: "mongodbExplain", Modes: []string{"plan"}}} {
		if s.Valid() {
			t.Fatal("unsupported diagnostic capability admitted")
		}
	}
}
