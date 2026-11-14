package adapter

import (
	"context"
	"strconv"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestExplainMetricsCollectorAndBounds(t *testing.T) {
	request := protocol.ExplainRequest{SQL: "SELECT 1", Mode: "analyze"}
	prepared, err := PrepareExplain(ExplainSupport("postgresql", "17.10"), request)
	if err != nil {
		t.Fatal(err)
	}
	one, time := "1", "0"
	node := protocol.ExplainNode{ID: "0", Operation: "Result", Children: []string{}, Details: map[string]string{}, Execution: "executed", Metrics: map[string]protocol.ExplainMetric{"estimatedRows": ExplainMetric(&one, "rows", "perInvocation", ""), "actualRows": ExplainMetric(&one, "rows", "perInvocation", ""), "loops": ExplainMetric(&one, "count", "total", ""), "totalTime": ExplainMetric(&time, "ms", "perInvocation", "")}}
	node.AdvancedMetrics = &protocol.ExplainNodeMetrics{Version: 1, ExecutionScope: "serial", RowComparison: "comparable", ExclusiveTime: ExplainExclusiveTime(node, "analyze", "serial", "postgresql"), Counters: map[string]protocol.ExplainMetric{}, Workers: []protocol.ExplainWorkerMetrics{}}
	parser := func(context.Context, string, string) ([]protocol.ExplainNode, []string, map[string]protocol.ExplainMetric, error) {
		return []protocol.ExplainNode{node}, []string{"0"}, map[string]protocol.ExplainMetric{}, nil
	}
	response := FinishExplain(context.Background(), protocol.Command{}, protocol.Response{Type: "execute.result", SQLCompleted: true}, prepared, &ExplainCapture{Raw: "[]"}, parser)
	if response.Explain.Status != "tree" || response.Explain.AdvancedMetrics == nil || !response.Explain.Valid() {
		t.Fatal("collector dropped advanced metrics")
	}
	// Exercise the collector's response budget with otherwise valid expanded evidence.
	for i := 0; i < 128; i++ {
		node.Details[strconv.Itoa(i)] = strings.Repeat("x", 65536)
	}
	response = FinishExplain(context.Background(), protocol.Command{}, protocol.Response{Type: "execute.result", SQLCompleted: true}, prepared, &ExplainCapture{Raw: "[]"}, parser)
	if response.Explain.Status != "rawOnly" || response.Explain.AdvancedMetrics != nil || len(response.Explain.Nodes) != 0 || !response.SQLCompleted || response.Explain.Raw != "[]" || !response.Explain.Valid() {
		t.Fatal("response budget retained stale advanced metadata or lost confirmed completion")
	}
	node.Details = map[string]string{}
	node.AdvancedMetrics.Version = 2
	response = FinishExplain(context.Background(), protocol.Command{}, protocol.Response{Type: "execute.result", SQLCompleted: true}, prepared, &ExplainCapture{Raw: "[]"}, parser)
	if response.Explain.Status != "rawOnly" || response.Explain.AdvancedMetrics != nil || response.Explain.Raw != "[]" {
		t.Fatal("invalid metrics must preserve raw completion")
	}
}

func TestExplainMetricsVerboseExactAuthorizedSQL(t *testing.T) {
	disabled := false
	for _, version := range []string{"14.25", "17.10"} {
		for _, mode := range []string{"plan", "analyze"} {
			request := protocol.ExplainRequest{SQL: "SELECT 1", Mode: mode}
			expected := "EXPLAIN (ANALYZE FALSE, COSTS TRUE, VERBOSE TRUE, FORMAT JSON)\nSELECT 1"
			if mode == "analyze" {
				expected = "EXPLAIN (ANALYZE TRUE, COSTS TRUE, TIMING TRUE, SUMMARY TRUE, BUFFERS TRUE, VERBOSE TRUE, FORMAT JSON)\nSELECT 1"
			}
			prepared, err := PrepareExplain(ExplainSupport("postgresql", version), request)
			if err != nil || prepared.Preview.SQL != expected {
				t.Fatalf("exact verbose preview %s %s", version, mode)
			}
		}
	}
	for _, item := range []struct {
		request  protocol.ExplainRequest
		expected string
	}{
		{protocol.ExplainRequest{SQL: "SELECT 1", Mode: "plan", PlanKind: "generic"}, "EXPLAIN (ANALYZE FALSE, GENERIC_PLAN TRUE, COSTS TRUE, VERBOSE TRUE, FORMAT JSON)\nSELECT 1"},
		{protocol.ExplainRequest{SQL: "SELECT 1", Mode: "analyze", Options: &protocol.ExplainOptions{PostgreSQL: &protocol.PostgresExplainOptions{Timing: &disabled}}}, "EXPLAIN (ANALYZE TRUE, COSTS TRUE, SUMMARY TRUE, BUFFERS TRUE, TIMING FALSE, VERBOSE TRUE, FORMAT JSON)\nSELECT 1"},
	} {
		prepared, err := PrepareExplain(ExplainSupport("postgresql", "17.10"), item.request)
		if err != nil || prepared.Preview.SQL != item.expected {
			t.Fatal("verbose changed explicit options or generic mode")
		}
	}
}
