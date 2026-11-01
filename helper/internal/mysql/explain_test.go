package mysql

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
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
		if p.Engine != "mysql" {
			continue
		}
		t.Run(p.ID, func(t *testing.T) {
			nodes, roots, _, err := parseExplainTree(context.Background(), p.Raw, p.Mode)
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
	if _, _, _, err := parseExplainTree(ctx, strings.Repeat(" ", 20), "plan"); err == nil {
		t.Fatal("parse cancellation")
	}
}

func TestExplainMySQLIdentitySurvivesMetadataBufferReuseAndCancellation(t *testing.T) {
	session := integrationSession(t)
	t.Logf("MySQL metadata retention server %s", session.work.client.GetServerVersion())
	identity, vendor := strings.Clone(session.serverUUID), strings.Clone(session.explainVendor)
	if identity == "" || vendor == "" {
		t.Fatal("server identity metadata missing")
	}
	queries := []string{"SELECT REPEAT('x', 16)", "SELECT REPEAT('x', 32)", "SELECT REPEAT('x', 64)", "SELECT REPEAT('x', 256)"}
	for i := 0; i < 16; i++ {
		response := session.Execute(context.Background(), protocol.Command{Type: "execute", RequestID: "warm", SessionID: "identity-fixture", QueryID: "warm", SQL: queries[i%len(queries)]})
		if response.Type != "query.result" || session.serverUUID != identity || session.explainVendor != vendor || len(session.ExplainSupport().Modes) == 0 {
			t.Fatal("pooled metadata storage changed the cached server identity/vendor")
		}
	}
	request := protocol.ExplainRequest{SQL: "SELECT SLEEP(5)", Mode: "analyze"}
	prepared, err := session.PrepareExplain(request)
	if err != nil {
		t.Fatal("cannot prepare fixture plan")
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	timer := time.AfterFunc(150*time.Millisecond, cancel)
	defer timer.Stop()
	response := session.ExecuteExplain(ctx, protocol.Command{Type: "explain.run", RequestID: "identity-cancel", SessionID: "identity-fixture", QueryID: "identity-cancel", Explain: &request, PreparedExplainSQL: prepared.Preview.SQL})
	if response.OutcomeUnknown || session.closed.Load() {
		t.Fatal("stable-identity cancellation unexpectedly lost the controlled fixture session")
	}
	if response.Type != "error" && (response.Type != "explain.result" || !response.SQLCompleted) {
		t.Fatal("cancellation lacks an authoritative terminal outcome")
	}
	if session.serverUUID != identity || session.explainVendor != vendor {
		t.Fatal("cancellation changed retained identity metadata")
	}
	if response := session.Execute(context.Background(), protocol.Command{Type: "execute", RequestID: "after-cancel", SessionID: "identity-fixture", QueryID: "after-cancel", SQL: "SELECT 1"}); response.Type != "query.result" {
		t.Fatal("session did not recover after cancellation")
	}
}
