package sqlite

import (
	"context"
	"dbeer/helper/internal/protocol"
	"testing"
)

func TestSQLiteExplainDMLNeverExecutesWrites(t *testing.T) {
	s := toolSession(t)
	ctx := context.Background()
	toolExec(t, s, "CREATE TEMP TABLE dbeer_f6_evidence(id INTEGER PRIMARY KEY,note TEXT)")
	toolExec(t, s, "BEGIN")
	toolExec(t, s, "INSERT INTO dbeer_f6_evidence VALUES(1,'NULL')")
	for _, sql := range []string{"INSERT INTO dbeer_f6_evidence VALUES(2,'estimated')", "UPDATE dbeer_f6_evidence SET note='estimated' WHERE id=1", "DELETE FROM dbeer_f6_evidence WHERE id=1", "WITH a AS (SELECT 1) UPDATE dbeer_f6_evidence SET note='estimated' WHERE id IN (SELECT * FROM a)"} {
		r := protocol.ExplainRequest{SQL: sql, Mode: "plan"}
		p, err := s.PrepareExplain(r)
		if err != nil {
			t.Fatal("estimated SQLite DML rejected")
		}
		out := s.ExecuteExplain(ctx, protocol.Command{Type: "explain.run", Explain: &r, PreparedExplainSQL: p.Preview.SQL})
		if out.Type != "explain.result" || !out.Explain.Valid() || out.Explain.DML == nil || out.Explain.DML.Execution != "estimated" || out.TransactionStatus != "transaction" {
			t.Fatal("SQLite DML plan not represented")
		}
		rows, _, err := s.query(ctx, "SELECT count(*),min(note) FROM dbeer_f6_evidence")
		if err != nil || cellText(rows[0][0]) != "1" || cellText(rows[0][1]) != "NULL" {
			t.Fatal("SQLite estimated DML executed")
		}
		r.Mode = "analyze"
		if _, err := s.PrepareExplain(r); err == nil {
			t.Fatal("SQLite actual DML admitted")
		}
	}
	toolExec(t, s, "ROLLBACK")
	rows, _, err := s.query(ctx, "SELECT count(*) FROM dbeer_f6_evidence")
	if err != nil || cellText(rows[0][0]) != "0" {
		t.Fatal("SQLite Explain changed user transaction")
	}
}
