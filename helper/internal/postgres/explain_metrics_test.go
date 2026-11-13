package postgres

import (
	"context"
	"encoding/json"
	"os"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestExplainAdvancedMetrics(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/explain-metrics-v1/contract.json")
	if err != nil {
		t.Fatal(err)
	}
	type expectedWorker struct {
		Number       int
		Metrics, JIT map[string]string
	}
	type expectedNode struct {
		Scope, RowComparison, ExclusiveValue, ExclusiveReason string
		Counters, JIT                                         map[string]string
		Workers                                               []expectedWorker
		JITDisabled                                           bool
	}
	var fixture struct {
		Plans []struct {
			ID, Engine, Mode, Raw string
			TimingDisabled        bool
			Expected              []expectedNode
		}
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	assertMetrics := func(t *testing.T, actual map[string]protocol.ExplainMetric, expected map[string]string) {
		t.Helper()
		for key, value := range expected {
			if actual[key].Value == nil || *actual[key].Value != value {
				t.Fatalf("metric %s exact value: got %+v, want %s", key, actual[key], value)
			}
		}
	}
	for _, plan := range fixture.Plans {
		if plan.Engine != "postgresql" {
			continue
		}
		t.Run(plan.ID, func(t *testing.T) {
			var options *protocol.ExplainOptions
			if plan.TimingDisabled {
				disabled := false
				options = &protocol.ExplainOptions{PostgreSQL: &protocol.PostgresExplainOptions{Timing: &disabled}}
			}
			nodes, _, _, err := parseExplainJSONWithOptions(context.Background(), plan.Raw, plan.Mode, options)
			if err != nil || len(nodes) != len(plan.Expected) {
				t.Fatalf("parse: %v, nodes %d", err, len(nodes))
			}
			for i, expected := range plan.Expected {
				advanced := nodes[i].AdvancedMetrics
				if advanced == nil || !advanced.Valid("postgresql", nodes[i], plan.Mode) || advanced.ExecutionScope != expected.Scope || advanced.RowComparison != expected.RowComparison {
					t.Fatalf("node %d annotations: %+v", i, advanced)
				}
				if expected.ExclusiveValue == "" {
					if advanced.ExclusiveTime.Value != nil || advanced.ExclusiveTime.UnavailableReason != expected.ExclusiveReason {
						t.Fatalf("exclusive unavailable: %+v", advanced.ExclusiveTime)
					}
				} else if advanced.ExclusiveTime.Value == nil || *advanced.ExclusiveTime.Value != expected.ExclusiveValue {
					t.Fatalf("exclusive value: %+v", advanced.ExclusiveTime)
				}
				assertMetrics(t, advanced.Counters, expected.Counters)
				if len(expected.JIT) > 0 {
					if advanced.JIT == nil || advanced.JIT.Scope != "queryAggregate" {
						t.Fatal("query aggregate JIT")
					}
					assertMetrics(t, advanced.JIT.Metrics, expected.JIT)
				}
				if expected.JITDisabled {
					for _, key := range []string{"generationTime", "totalTime"} {
						if advanced.JIT.Metrics[key].Value != nil || advanced.JIT.Metrics[key].UnavailableReason != "disabled" {
							t.Fatal("JIT timing not disabled")
						}
					}
				}
				if len(advanced.Workers) != len(expected.Workers) {
					t.Fatalf("workers: got %d, want %d", len(advanced.Workers), len(expected.Workers))
				}
				for wi, worker := range expected.Workers {
					actual := advanced.Workers[wi]
					if actual.Number != worker.Number {
						t.Fatal("worker identity")
					}
					assertMetrics(t, actual.Metrics, worker.Metrics)
					if len(worker.JIT) > 0 {
						if actual.JIT == nil || actual.JIT.Scope != "worker" {
							t.Fatal("worker JIT")
						}
						assertMetrics(t, actual.JIT.Metrics, worker.JIT)
					}
				}
			}
		})
	}
}
func TestExplainAdvancedMetricMalformedEvidence(t *testing.T) {
	for _, raw := range []string{
		`[{"Plan":{"Node Type":"Seq Scan","Parallel Aware":false,"Shared Hit Blocks":"0"}}]`,
		`[{"Plan":{"Node Type":"Seq Scan","Parallel Aware":false,"Workers":[{"Worker Number":0},{"Worker Number":0}]}}]`,
		`[{"Plan":{"Node Type":"Seq Scan","Parallel Aware":false},"JIT":{"Functions":-1}}]`,
		`[{"Plan":{"Node Type":"Seq Scan","Parallel Aware":false},"JIT":{"Functions":1,"Timing":{"Generation":{"Deform":"1","Total":1}}}}]`,
	} {
		if _, _, _, err := parseExplainJSON(context.Background(), raw, "analyze"); err == nil {
			t.Fatal("accepted malformed advanced evidence")
		}
	}
}
