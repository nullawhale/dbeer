package protocol

import (
	"encoding/json"
	"os"
	"testing"
)

func TestExplainMetricsSharedContract(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/explain-metrics-v1/contract.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Version        int
		Capability     string
		Results        []ExplainResult
		InvalidResults []struct {
			ID     string
			Result ExplainResult
		}
		InvalidDecodes []struct {
			ID     string
			Result json.RawMessage
		}
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if fixture.Version != 1 || fixture.Capability != ExplainMetricsCapability {
		t.Fatal("contract identity")
	}
	for _, result := range fixture.Results {
		if !result.Valid() {
			t.Fatal("valid advanced result")
		}
		data, err := json.Marshal(result)
		if err != nil {
			t.Fatal(err)
		}
		var roundtrip ExplainResult
		if json.Unmarshal(data, &roundtrip) != nil || !roundtrip.Valid() {
			t.Fatal("advanced roundtrip")
		}
	}
	for _, item := range fixture.InvalidResults {
		if item.Result.Valid() {
			t.Fatalf("accepted %s", item.ID)
		}
	}
	for _, item := range fixture.InvalidDecodes {
		var result ExplainResult
		if json.Unmarshal(item.Result, &result) == nil {
			t.Fatalf("decoded %s", item.ID)
		}
	}
}
