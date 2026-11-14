package postgres

import (
	"context"
	"dbeer/helper/internal/protocol"
	"testing"
	"unicode/utf16"
)

func TestExplainDMLPostgresLive(t *testing.T) {
	fixture := newChangeFixture(t)
	opened, err := Open(context.Background(), fixture.settings)
	if err != nil {
		t.Fatal("cannot open owned DML fixture")
	}
	s := opened.(*Session)
	defer s.Close()
	ctx := context.Background()
	exec := func(sql string) protocol.Response {
		t.Helper()
		r := s.Execute(ctx, protocol.Command{Type: "execute", RequestID: "f6-user", SessionID: "f6", QueryID: "f6-user", SQL: sql})
		if r.Type != "query.result" {
			t.Fatalf("owned DML fixture user action failed: %s/%s", r.Category, r.SQLState)
		}
		return r
	}
	exec("CREATE TEMP TABLE dbeer_f6_evidence(id bigint PRIMARY KEY,note text,empty text,nullable text,amount numeric,payload bytea)")
	explain := func(sql, mode string, parameters []protocol.QueryParameter) protocol.Response {
		t.Helper()
		r := protocol.ExplainRequest{SQL: sql, Mode: mode, Parameters: parameters}
		if mode == "analyze" {
			status := s.TransactionStatus()
			r.WriteIntent = &protocol.ExplainWriteIntent{Disposition: "currentSession", ExpectedTransactionStatus: status}
			r.Context = &protocol.ExplainContext{DocumentID: "source", TargetDocumentID: "target", ProfileID: "profile", SessionID: "f6", TransactionStatus: status, RangeLength: len(utf16.Encode([]rune(sql)))}
		}
		p, err := s.PrepareExplain(r)
		if err != nil {
			t.Fatal("owned DML Explain preparation rejected")
		}
		out := s.ExecuteExplain(ctx, protocol.Command{Type: "explain.run", RequestID: "f6-run", SessionID: "f6", QueryID: "f6-run", Explain: &r, PreparedExplainSQL: p.Preview.SQL})
		if out.Type != "explain.result" || out.Explain == nil || !out.Explain.Valid() || out.Explain.DML == nil || !out.SQLCompleted {
			t.Fatalf("owned DML Explain failed: %s/%s", out.Category, out.SQLState)
		}
		return out
	}
	missing := protocol.ExplainRequest{SQL: "UPDATE pg_temp.dbeer_f6_missing_target SET id=2", Mode: "plan"}
	missingPrepared, err := s.PrepareExplain(missing)
	if err != nil {
		t.Fatal("estimated rejection fixture preparation failed")
	}
	rejected := s.ExecuteExplain(ctx, protocol.Command{Type: "explain.run", Explain: &missing, PreparedExplainSQL: missingPrepared.Preview.SQL})
	if rejected.Type != "error" || rejected.ExplainDML != nil || rejected.SQLCompleted || rejected.OutcomeUnknown {
		t.Fatal("estimated server rejection emitted an Analyze outcome")
	}
	count := func() string { t.Helper(); r := exec("SELECT count(*) FROM dbeer_f6_evidence"); return *r.Rows[0][0] }
	for _, sql := range []string{"INSERT INTO dbeer_f6_evidence(id,note) VALUES(1,'estimated')", "UPDATE dbeer_f6_evidence SET note='estimated' WHERE id=1", "DELETE FROM dbeer_f6_evidence WHERE id=1", "WITH changed AS (INSERT INTO dbeer_f6_evidence(id,note) VALUES(2,'estimated') RETURNING *) SELECT * FROM changed"} {
		out := explain(sql, "plan", nil)
		if out.Explain.DML.Execution != "estimated" || count() != "0" {
			t.Fatal("estimated DML executed a write")
		}
	}
	id, note, empty, amount := "9007199254740993", "NULL", "", "9007199254740993.125"
	parameters := []protocol.QueryParameter{{Name: "id", Type: "integer", Value: &id}, {Name: "note", Type: "text", Value: &note}, {Name: "empty", Type: "text", Value: &empty}, {Name: "null", Type: "text"}, {Name: "amount", Type: "decimal", Value: &amount}}
	out := explain("INSERT INTO dbeer_f6_evidence VALUES(:id,:note,:empty,:null,:amount,decode('00ff','hex'))", "analyze", parameters)
	if out.Explain.DML.Execution != "completed" || out.Explain.DML.Persistence != "committed" || out.Explain.DML.TransactionAfter != "idle" || count() != "1" {
		t.Fatal("autocommit DML outcome not acknowledged")
	}
	r := exec("SELECT id::text,note,empty,nullable,amount::text,encode(payload,'hex') FROM dbeer_f6_evidence")
	if *r.Rows[0][0] != id || *r.Rows[0][1] != "NULL" || *r.Rows[0][2] != "" || r.Rows[0][3] != nil || *r.Rows[0][4] != amount || *r.Rows[0][5] != "00ff" {
		t.Fatal("DML changed exact numeric/null/empty/text/binary values")
	}
	exec("BEGIN")
	out = explain("UPDATE dbeer_f6_evidence SET note='pending' WHERE id=9007199254740993", "analyze", nil)
	if out.Explain.DML.Persistence != "transactionPending" || out.TransactionStatus != "transaction" {
		t.Fatal("existing transaction was not preserved")
	}
	out = explain("WITH changed AS (DELETE FROM dbeer_f6_evidence RETURNING *) SELECT count(*) FROM changed", "analyze", nil)
	if !out.Explain.DML.Target.DataModifyingCTE || out.Explain.DML.Persistence != "transactionPending" || count() != "0" {
		t.Fatal("data-changing CTE was treated as a read")
	}
	exec("ROLLBACK")
	if count() != "1" || *exec("SELECT note FROM dbeer_f6_evidence").Rows[0][0] != "NULL" {
		t.Fatal("DML Analyze committed or rolled back the user's transaction")
	}
	t.Logf("F6 PostgreSQL %s: estimated I/U/D+CTE unchanged; exact values; autocommit and user rollback acknowledged", s.ExplainSupport().ServerVersion)
}
