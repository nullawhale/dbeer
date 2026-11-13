package mysql

import (
	"context"
	"dbeer/helper/internal/protocol"
	"testing"
	"time"
)

func TestExplainParametersMySQLLive(t *testing.T) {
	s := integrationSession(t)
	ctx := context.Background()
	run(t, s, "CREATE TEMPORARY TABLE explain_evidence(id integer PRIMARY KEY,note text)")
	run(t, s, "BEGIN")
	run(t, s, "INSERT INTO explain_evidence VALUES(1,'uncommitted')")
	one := "1"
	text := "NULL ' ; DELETE FROM explain_evidence; --"
	empty := ""
	decimal := "9007199254740993.125"
	request := protocol.ExplainRequest{SQL: "SELECT * FROM explain_evidence WHERE id=:id AND :text=:text AND :empty='' AND :null IS NULL AND :decimal=9007199254740993.125", Mode: "plan", Parameters: []protocol.QueryParameter{{Name: "id", Type: "integer", Value: &one}, {Name: "text", Type: "text", Value: &text}, {Name: "empty", Type: "text", Value: &empty}, {Name: "null", Type: "text"}, {Name: "decimal", Type: "decimal", Value: &decimal}}}
	explain := func(r protocol.ExplainRequest, ctx context.Context) protocol.Response {
		p, err := s.PrepareExplain(r)
		if err != nil {
			t.Fatal("cannot prepare bound MySQL Explain")
		}
		return s.ExecuteExplain(ctx, protocol.Command{Type: "explain.run", RequestID: "r", SessionID: "s", QueryID: "q", Explain: &r, PreparedExplainSQL: p.Preview.SQL})
	}
	for _, mode := range s.ExplainSupport().Modes {
		request.Mode = mode
		result := explain(request, ctx)
		if result.Type != "explain.result" || !result.Explain.Valid() || !result.SQLCompleted || result.TransactionStatus != "transaction" {
			t.Fatal("bound MySQL Explain lost typed values, temp table or transaction")
		}
		if mode == "analyze" && (len(result.Explain.Nodes) == 0 || result.Explain.Nodes[0].Metrics["actualRows"].Value == nil || *result.Explain.Nodes[0].Metrics["actualRows"].Value != "1") {
			t.Fatal("MySQL Analyze did not use exact bindings")
		}
	}
	retained := run(t, s, "SELECT count(*),min(note) FROM explain_evidence")
	if len(retained.Rows) != 1 || *retained.Rows[0][0] != "1" || *retained.Rows[0][1] != "uncommitted" {
		t.Fatal("Explain changed data or caller transaction")
	}
	run(t, s, "ROLLBACK")
	retained = run(t, s, "SELECT count(*) FROM explain_evidence")
	if *retained.Rows[0][0] != "0" {
		t.Fatal("Explain committed caller transaction")
	}
	if len(s.ExplainSupport().Modes) == 1 {
		return
	}
	delay := "5.0"
	sleep := protocol.ExplainRequest{SQL: "SELECT SLEEP(:delay)", Mode: "analyze", Parameters: []protocol.QueryParameter{{Name: "delay", Type: "decimal", Value: &delay}}}
	cancelled, cancel := context.WithCancel(ctx)
	timer := time.AfterFunc(150*time.Millisecond, cancel)
	defer timer.Stop()
	defer cancel()
	result := explain(sleep, cancelled)
	if result.OutcomeUnknown || (result.Type != "error" || result.Category != "cancelled") && (result.Type != "explain.result" || !result.SQLCompleted) {
		t.Fatalf("bound MySQL Explain cancellation: type=%s category=%s state=%s connected=%t unknown=%t completed=%t", result.Type, result.Category, result.SQLState, result.Connected, result.OutcomeUnknown, result.SQLCompleted)
	}
	if result.Connected {
		run(t, s, "SELECT 1")
	}
}
