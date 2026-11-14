package sqlite

import (
	"context"
	"dbeer/helper/internal/protocol"
	"testing"
)

func TestSQLiteExplainBoundParametersRetainTransactionAndTempObjects(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	toolExec(t, s, "CREATE TEMP TABLE evidence(id INTEGER PRIMARY KEY,note TEXT)")
	toolExec(t, s, "BEGIN")
	toolExec(t, s, "INSERT INTO evidence VALUES(1,'uncommitted')")
	text := "NULL ' ; DELETE FROM evidence; --"
	empty := ""
	one := "1"
	decimal := "9007199254740993.125"
	request := protocol.ExplainRequest{SQL: "SELECT * FROM evidence WHERE id=:id AND :text IS NOT NULL AND :empty='' AND :null IS NULL AND :decimal IS NOT NULL", Mode: "plan", Parameters: []protocol.QueryParameter{{Name: "id", Type: "integer", Value: &one}, {Name: "text", Type: "text", Value: &text}, {Name: "empty", Type: "text", Value: &empty}, {Name: "null", Type: "text"}, {Name: "decimal", Type: "decimal", Value: &decimal}}}
	p, err := s.PrepareExplain(request)
	if err != nil {
		t.Fatal("cannot prepare bound SQLite Explain")
	}
	result := s.ExecuteExplain(ctx, protocol.Command{Type: "explain.run", RequestID: "r", SessionID: "s", QueryID: "q", Explain: &request, PreparedExplainSQL: p.Preview.SQL})
	if result.Type != "explain.result" || !result.Explain.Valid() || !result.SQLCompleted || result.TransactionStatus != "transaction" {
		t.Fatal("bound SQLite Explain lost owning session")
	}
	rows, _, err := s.query(ctx, "SELECT count(*),note FROM evidence")
	if err != nil || cellText(rows[0][0]) != "1" || cellText(rows[0][1]) != "uncommitted" {
		t.Fatal("bound text escaped or transaction was changed")
	}
	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	result = s.ExecuteExplain(cancelled, protocol.Command{Type: "explain.run", Explain: &request, PreparedExplainSQL: p.Preview.SQL})
	if result.Type != "error" {
		t.Fatal("cancelled Explain unexpectedly ran")
	}
	toolExec(t, s, "ROLLBACK")
	rows, _, err = s.query(ctx, "SELECT count(*) FROM evidence")
	if err != nil || cellText(rows[0][0]) != "0" {
		t.Fatal("Explain committed the caller transaction")
	}
}
