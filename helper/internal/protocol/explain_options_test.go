package protocol

import (
	"encoding/json"
	"os"
	"testing"
)

func TestExplainOptionsSharedClosedContract(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/explain-options-v1/contract.json")
	if err != nil {
		t.Fatal("missing fixture")
	}
	var fixture struct {
		Version         int
		Capability      string
		Commands        []json.RawMessage
		InvalidCommands []struct {
			ID      string
			Command json.RawMessage
		}
	}
	if json.Unmarshal(data, &fixture) != nil || fixture.Version != 1 || fixture.Capability != ExplainOptionsCapability {
		t.Fatal("fixture")
	}
	for i, raw := range fixture.Commands {
		c, err := ParseCommand(raw)
		if err != nil || c.Explain.Options == nil || !c.Explain.Options.Valid() {
			t.Fatalf("valid options %d", i)
		}
	}
	for _, item := range fixture.InvalidCommands {
		if _, err := ParseCommand(item.Command); err == nil {
			t.Fatalf("accepted %s", item.ID)
		}
	}
	for _, raw := range []string{`{"postgresql":{"timing":true,"timing":false}}`, `{"mysql":{"format":"tree"},"mysql":{"format":"json"}}`} {
		if _, err := ParseCommand([]byte(`{"type":"explain.run","requestId":"r","sessionId":"s","queryId":"q","explain":{"sql":"SELECT 1","mode":"plan","options":` + raw + `}}`)); err == nil {
			t.Fatal("ambiguous options")
		}
	}
}

func TestExplainOptionsResultFormatSelectionIsClosed(t *testing.T) {
	support := ExplainSupport{Engine: "mysql", ServerVersion: "8.4.6", Format: "tree", Modes: []string{"plan", "analyze"}, Options: &ExplainOptionSupport{MySQL: &MySQLExplainOptionSupport{Plan: []string{"tree", "json"}, Analyze: []string{"tree", "json"}, JSONAnalyzeRequiresVersion2: true}}}
	options := &ExplainOptions{MySQL: &MySQLExplainOptions{Format: "json"}}
	node := ExplainNode{ID: "0", Operation: "Result", Children: []string{}, Details: map[string]string{}, Execution: "unknown", Metrics: map[string]ExplainMetric{}}
	result := ExplainResult{Support: support, Mode: "analyze", Options: options, Format: "jsonV2", Status: "tree", Raw: "{}", Complete: true, Roots: []string{"0"}, Nodes: []ExplainNode{node}, Metrics: map[string]ExplainMetric{}}
	if !result.Valid() {
		t.Fatal("JSON v2 actual rejected")
	}
	for _, format := range []string{"", "json", "jsonV1", "tree", "future"} {
		changed := result
		changed.Format = format
		if changed.Valid() {
			t.Fatalf("incorrect observed/requested format %s accepted", format)
		}
	}
	result.Mode = "plan"
	result.Format = "jsonV1"
	if !result.Valid() {
		t.Fatal("JSON v1 estimated rejected")
	}
	changed := result
	changed.Options = &ExplainOptions{MySQL: &MySQLExplainOptions{Format: "tree"}}
	if changed.Valid() {
		t.Fatal("different selected format accepted")
	}
	changed = result
	changed.Options = &ExplainOptions{PostgreSQL: &PostgresExplainOptions{}}
	if changed.Valid() {
		t.Fatal("cross-engine options accepted")
	}
	result.Status = "rawOnly"
	result.Format = "json"
	result.Nodes = []ExplainNode{}
	result.Roots = []string{}
	result.Diagnostic = "Captured; unrecognized response"
	if !result.Valid() {
		t.Fatal("unknown captured JSON lost")
	}
}
