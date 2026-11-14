package mysql

import (
	"context"
	"encoding/json"
	"os"
	"testing"
)

func TestExplainAdvancedMetrics(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/explain-metrics-v1/contract.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Plans []struct {
			ID, Engine, Mode, Raw string
			Expected              []struct{ Scope, RowComparison, ExclusiveValue, ExclusiveReason string }
		}
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	for _, plan := range fixture.Plans {
		if plan.Engine != "mysql" {
			continue
		}
		t.Run(plan.ID, func(t *testing.T) {
			nodes, _, _, err := parseExplainPlan(context.Background(), plan.Raw, plan.Mode)
			if err != nil || len(nodes) != len(plan.Expected) {
				t.Fatalf("parse: %v, nodes %d", err, len(nodes))
			}
			for i, expected := range plan.Expected {
				advanced := nodes[i].AdvancedMetrics
				if advanced == nil || !advanced.Valid("mysql", nodes[i], plan.Mode) || advanced.ExecutionScope != expected.Scope || advanced.RowComparison != expected.RowComparison {
					t.Fatalf("node %d annotations: %+v", i, advanced)
				}
				if expected.ExclusiveValue == "" {
					if advanced.ExclusiveTime.Value != nil || advanced.ExclusiveTime.UnavailableReason != expected.ExclusiveReason {
						t.Fatalf("exclusive unavailable: %+v", advanced.ExclusiveTime)
					}
				} else if advanced.ExclusiveTime.Value == nil || *advanced.ExclusiveTime.Value != expected.ExclusiveValue {
					t.Fatalf("exclusive value: %+v", advanced.ExclusiveTime)
				}
				if len(advanced.Counters) != 0 || len(advanced.Workers) != 0 || advanced.JIT != nil {
					t.Fatal("invented unsupported counters")
				}
			}
		})
	}
}
