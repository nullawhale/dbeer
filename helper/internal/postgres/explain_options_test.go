package postgres

import (
	"context"
	"dbeer/helper/internal/protocol"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestExplainTimingDisabledRetainsCountsSummaryAndOptionEvidence(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/explain-options-v1/contract.json")
	if err != nil {
		t.Fatal("fixture")
	}
	var f struct {
		Plans []struct {
			Engine, Raw, Mode string
			Options           *protocol.ExplainOptions
		}
	}
	if json.Unmarshal(data, &f) != nil {
		t.Fatal("fixture")
	}
	for _, p := range f.Plans {
		if p.Engine != "postgresql" {
			continue
		}
		nodes, _, metrics, err := parseExplainJSONWithOptions(context.Background(), p.Raw, p.Mode, p.Options)
		if err != nil || len(nodes) != 1 {
			t.Fatal("parse")
		}
		n := nodes[0]
		if n.Metrics["totalTime"].Value != nil || n.Metrics["totalTime"].UnavailableReason != "disabled" || n.Metrics["actualRows"].Value == nil || *n.Metrics["actualRows"].Value != "1" || *metrics["executionTime"].Value != "0" || n.Details["Settings"] == "" || n.Details["Planning"] == "" || n.Details["Serialization"] == "" {
			t.Fatal("disabled timing confused with zero/missing or option evidence lost")
		}
		zeroRaw := strings.Replace(p.Raw, `"Actual Loops":1`, `"Actual Loops":0`, 1)
		nodes, _, _, err = parseExplainJSONWithOptions(context.Background(), zeroRaw, p.Mode, p.Options)
		if err != nil || nodes[0].Metrics["totalTime"].UnavailableReason != "notExecuted" {
			t.Fatal("unexecuted timing")
		}
	}
	raw := `[{"Plan":{"Node Type":"Result","Actual Loops":1,"Actual Rows":0,"Actual Total Time":0},"Execution Time":0}]`
	nodes, _, _, err := parseExplainJSON(context.Background(), raw, "analyze")
	if err != nil || nodes[0].Metrics["startupTime"].UnavailableReason != "notReported" || *nodes[0].Metrics["totalTime"].Value != "0" {
		t.Fatal("zero vs unavailable")
	}
}
