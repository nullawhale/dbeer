package mysql

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestExplainJSONV1V2CapturedFormatsAndHonestMetrics(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/explain-options-v1/contract.json")
	if err != nil {
		t.Fatal("fixture")
	}
	var f struct {
		Plans []struct {
			ID, Engine, Mode, Format, Raw string
			Nodes                         int
		}
	}
	if json.Unmarshal(data, &f) != nil {
		t.Fatal("fixture")
	}
	for _, p := range f.Plans {
		if p.Engine != "mysql" {
			continue
		}
		t.Run(p.ID, func(t *testing.T) {
			nodes, roots, _, err := parseExplainPlan(context.Background(), p.Raw, p.Mode)
			if err != nil || len(nodes) != p.Nodes || len(roots) != 1 || mysqlPlanFormat(p.Raw) != p.Format {
				t.Fatalf("normalization %v", err)
			}
			switch p.ID {
			case "mysql57JSONv1":
				if *nodes[0].Metrics["totalCost"].Value != "9007199254740993.0000001" {
					t.Fatal("exact cost lost")
				}
				for _, n := range nodes {
					if strings.HasPrefix(n.Operation, "Table access") && (n.Metrics["totalCost"].Value != nil || n.Metrics["actualRows"].Value != nil || n.Metrics["totalCost"].UnavailableReason != "unsupported") {
						t.Fatal("v1 prefix cost/count invented")
					}
				}
			case "mysql84JSONv2":
				if *nodes[0].Metrics["startupTime"].Value != "0" || *nodes[2].Metrics["loops"].Value != "2" || nodes[2].Metrics["totalTime"].Basis != "perInvocation" {
					t.Fatal("per-loop/zero metrics lost")
				}
			case "mysql84UnknownLoops":
				if nodes[0].Execution != "unknown" || nodes[0].Metrics["loops"].Value != nil || nodes[0].Metrics["loops"].UnavailableReason != "notReported" {
					t.Fatal("unknown loops invented")
				}
			case "mysql84NeverExecuted":
				if nodes[0].Execution != "notExecuted" || *nodes[0].Metrics["loops"].Value != "0" || nodes[0].Metrics["actualRows"].Value != nil || nodes[0].Metrics["actualRows"].UnavailableReason != "notExecuted" {
					t.Fatal("never-executed is measured zero")
				}
			}
			support := adapter.ExplainSupport("mysql", "8.4.6")
			request := protocol.ExplainRequest{SQL: "SELECT 1", Mode: p.Mode, Options: &protocol.ExplainOptions{MySQL: &protocol.MySQLExplainOptions{Format: "json"}}}
			prepared, _ := adapter.PrepareExplain(support, request)
			prepared.Preview.Format = p.Format
			result := adapter.FinishExplain(context.Background(), protocol.Command{}, protocol.Response{Type: "query.result", Connected: true, TransactionStatus: "idle"}, prepared, &adapter.ExplainCapture{Raw: p.Raw}, parseExplainJSON)
			if result.Type != "explain.result" || !result.SQLCompleted || result.Explain.Status != "tree" || !result.Explain.Valid() || result.Explain.Format != p.Format {
				t.Fatal("captured completion/format lost")
			}
		})
	}
	for _, raw := range []string{`{"operation":"x","inputs":{}}`, `{"operation":"x","actual_rows":-1}`, `{"query_block":{}} trailing`, `{"future_plan":{}}`, `{"operation":"x","future_child":{"operation":"unhandled"}}`} {
		if _, _, _, err := parseExplainJSON(context.Background(), raw, "analyze"); err == nil {
			t.Fatal("unknown JSON accepted")
		}
	}
	request := protocol.ExplainRequest{SQL: "SELECT 1", Mode: "analyze", Options: &protocol.ExplainOptions{MySQL: &protocol.MySQLExplainOptions{Format: "json"}}}
	prepared, _ := adapter.PrepareExplain(adapter.ExplainSupport("mysql", "8.4.6"), request)
	prepared.Preview.Format = "jsonV1"
	captured := `{"query_block":{"message":"Unfamiliar actual response"}}`
	fallback := adapter.FinishExplain(context.Background(), protocol.Command{}, protocol.Response{Type: "query.result", Connected: true, TransactionStatus: "idle"}, prepared, &adapter.ExplainCapture{Raw: captured}, parseExplainJSON)
	if !fallback.SQLCompleted || fallback.Explain.Status != "rawOnly" || fallback.Explain.Format != "json" || fallback.Explain.Raw != captured || !fallback.Explain.Valid() {
		t.Fatal("existing unknown actual response lost known completion or raw evidence")
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, _, err := parseExplainJSON(ctx, `{"operation":"x"}`, "plan"); err == nil {
		t.Fatal("cancel ignored")
	}
}
