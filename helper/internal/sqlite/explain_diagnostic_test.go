package sqlite

import (
	"context"
	"dbeer/helper/internal/protocol"
	"strings"
	"testing"
)

func TestSQLiteDiagnosticExposesNativeEQPAndUnavailableActuals(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	toolExec(t, s, "CREATE TEMP TABLE diagnostic_items(id INTEGER PRIMARY KEY, category TEXT, note TEXT)")
	toolExec(t, s, "CREATE INDEX diagnostic_category ON diagnostic_items(category)")
	toolExec(t, s, "BEGIN")
	toolExec(t, s, "INSERT INTO diagnostic_items VALUES(1,'a','uncommitted')")
	request := protocol.ExplainRequest{SQL: "SELECT category,note FROM diagnostic_items WHERE category='a' ORDER BY note", Mode: "plan"}
	p, err := s.PrepareExplain(request)
	if err != nil {
		t.Fatal("prepare failed")
	}
	r := s.ExecuteExplain(ctx, protocol.Command{Explain: &request, PreparedExplainSQL: p.Preview.SQL})
	if r.Type != "explain.result" || !r.SQLCompleted || !r.Explain.Valid() || r.TransactionStatus != "transaction" {
		t.Fatal("EQP lost physical transaction")
	}
	foundIndex, foundSort := false, false
	for _, node := range r.Explain.Nodes {
		if node.Details["Node ID"] != node.ID || node.Details["Parent ID"] == "" || node.Details["Auxiliary (unused by SQLite)"] == "" {
			t.Fatal("raw EQP fields missing")
		}
		foundIndex = foundIndex || strings.Contains(node.Operation, "diagnostic_category")
		foundSort = foundSort || strings.Contains(node.Operation, "TEMP B-TREE")
		for _, m := range node.Metrics {
			if m.Value != nil || m.UnavailableReason != "unsupported" {
				t.Fatal("EQP invented actual metrics")
			}
		}
	}
	if !foundIndex || !foundSort {
		t.Fatal("actual EQP index and sorting evidence missing")
	}
	toolExec(t, s, "ROLLBACK")
	rows, _, err := s.query(ctx, "SELECT count(*) FROM diagnostic_items")
	if err != nil || cellText(rows[0][0]) != "0" {
		t.Fatal("EQP changed transaction")
	}
}
