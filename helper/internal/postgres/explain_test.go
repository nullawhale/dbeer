package postgres

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestExplainParserSharedFixtures(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/explain-v1/contract.json")
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Plans []struct {
			ID, Engine, Mode, Raw, RootCost, Execution, Loops string
			Nodes                                             int
		}
	}
	if json.Unmarshal(data, &f) != nil {
		t.Fatal("fixture")
	}
	for _, p := range f.Plans {
		if p.Engine != "postgresql" {
			continue
		}
		t.Run(p.ID, func(t *testing.T) {
			nodes, roots, _, err := parseExplainJSON(context.Background(), p.Raw, p.Mode)
			if err != nil || len(nodes) != p.Nodes || len(roots) != 1 {
				t.Fatal("plan parse")
			}
			if p.RootCost != "" && (nodes[0].Metrics["totalCost"].Value == nil || *nodes[0].Metrics["totalCost"].Value != p.RootCost) {
				t.Fatal("exact cost")
			}
			if p.Loops != "" && (nodes[0].Metrics["loops"].Value == nil || *nodes[0].Metrics["loops"].Value != p.Loops) {
				t.Fatal("loops zero/precision")
			}
			if p.Execution != "" && nodes[0].Execution != p.Execution {
				t.Fatal("execution state")
			}
		})
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, _, err := parseExplainJSON(ctx, strings.Repeat(" ", 20), "plan"); err == nil {
		t.Fatal("parse cancellation")
	}
}
