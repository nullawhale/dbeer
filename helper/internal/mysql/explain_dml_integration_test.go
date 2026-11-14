package mysql

import (
	"context"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/safety"
	"fmt"
	"testing"
	"unicode/utf16"
)

func TestExplainDMLMySQLLive(t *testing.T) {
	s := integrationSession(t)
	ctx := context.Background()
	run(t, s, "CREATE TEMPORARY TABLE dbeer_f6_evidence(id BIGINT PRIMARY KEY,note TEXT,empty_value TEXT,nullable TEXT,amount DECIMAL(30,3),payload VARBINARY(10)) ENGINE=InnoDB")
	run(t, s, "CREATE TEMPORARY TABLE dbeer_f6_join(id BIGINT PRIMARY KEY) ENGINE=InnoDB")
	run(t, s, "INSERT INTO dbeer_f6_evidence VALUES(1,'NULL','',NULL,9007199254740993.125,X'00FF')")
	run(t, s, "INSERT INTO dbeer_f6_join VALUES(1)")
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
			t.Fatal("owned MySQL DML Explain preparation rejected")
		}
		out := s.ExecuteExplain(ctx, protocol.Command{Type: "explain.run", RequestID: "f6-run", SessionID: "f6", QueryID: "f6-run", Explain: &r, PreparedExplainSQL: p.Preview.SQL})
		if out.Type != "explain.result" || out.Explain == nil || !out.Explain.Valid() || out.Explain.DML == nil || !out.SQLCompleted {
			t.Fatalf("owned MySQL DML Explain failed: %s/%s", out.Category, out.SQLState)
		}
		return out
	}
	missing := protocol.ExplainRequest{SQL: "UPDATE " + QuoteIdentifier(fmt.Sprintf("dbeer_f6_missing_target_%d", s.connectionID)) + " SET id=2", Mode: "plan"}
	missingPrepared, err := s.PrepareExplain(missing)
	if err != nil {
		t.Fatal("estimated rejection fixture preparation failed")
	}
	rejected := s.ExecuteExplain(ctx, protocol.Command{Type: "explain.run", Explain: &missing, PreparedExplainSQL: missingPrepared.Preview.SQL})
	if rejected.Type != "error" || rejected.ExplainDML != nil || rejected.SQLCompleted || rejected.OutcomeUnknown {
		t.Fatal("estimated server rejection emitted an Analyze outcome")
	}
	for _, sql := range []string{"INSERT INTO dbeer_f6_evidence(id,note) VALUES(2,'estimated')", "UPDATE dbeer_f6_evidence SET note='estimated' WHERE id=1", "DELETE FROM dbeer_f6_evidence WHERE id=1"} {
		out := explain(sql, "plan", nil)
		r := run(t, s, "SELECT count(*),min(note) FROM dbeer_f6_evidence")
		if out.Explain.DML.Execution != "estimated" || *r.Rows[0][0] != "1" || *r.Rows[0][1] != "NULL" {
			t.Fatal("estimated MySQL DML executed a write")
		}
	}
	if len(s.ExplainSupport().DML.Analyze) == 0 {
		t.Skip("actual multitable DML Analyze requires MySQL 8.0.18+")
	}
	pending := "pending"
	update := "UPDATE dbeer_f6_evidence a JOIN dbeer_f6_join b ON a.id=b.id SET a.note=:note"
	parameters := []protocol.QueryParameter{{Name: "note", Type: "text", Value: &pending}}
	out := explain(update, "analyze", parameters)
	if out.Explain.DML.Persistence != "notExecuted" || out.Explain.DML.TargetExecution != "suppressed" || out.Explain.DML.TransactionAfter != "idle" {
		t.Fatal("MySQL autocommit outcome not acknowledged")
	}
	if *run(t, s, "SELECT note FROM dbeer_f6_evidence").Rows[0][0] != "NULL" {
		t.Fatal("MySQL native diagnostic unexpectedly applied target UPDATE")
	}
	run(t, s, "UPDATE dbeer_f6_evidence SET note='NULL'")
	// Explicit user setup: idle does not imply autocommit in the reviewed session.
	run(t, s, "SET autocommit=0")
	if s.TransactionStatus() != "idle" {
		t.Fatal("owned MySQL setup did not begin idle")
	}
	out = explain(update, "analyze", parameters)
	if out.Explain.DML.TransactionBefore != "idle" || out.Explain.DML.TransactionAfter != "transaction" || out.Explain.DML.Persistence != "notExecuted" || out.Explain.DML.TargetExecution != "suppressed" {
		t.Fatal("autocommit=0 was falsely reported committed")
	}
	run(t, s, "ROLLBACK")
	if *run(t, s, "SELECT note FROM dbeer_f6_evidence").Rows[0][0] != "NULL" {
		t.Fatal("Analyze committed pending transactional rows")
	}
	run(t, s, "ROLLBACK")
	run(t, s, "SET autocommit=1")
	run(t, s, "BEGIN")
	out = explain("DELETE a FROM dbeer_f6_evidence a JOIN dbeer_f6_join b ON a.id=b.id", "analyze", nil)
	if out.Explain.DML.Persistence != "notExecuted" || out.Explain.DML.TargetExecution != "suppressed" || out.TransactionStatus != "transaction" {
		t.Fatal("existing transaction changed by DML Analyze")
	}
	if *run(t, s, "SELECT count(*) FROM dbeer_f6_evidence").Rows[0][0] != "1" {
		t.Fatal("MySQL native diagnostic unexpectedly applied target DELETE")
	}
	run(t, s, "ROLLBACK")
	r := run(t, s, "SELECT count(*),min(note),min(empty_value),min(nullable),min(amount),HEX(min(payload)) FROM dbeer_f6_evidence")
	if *r.Rows[0][0] != "1" || *r.Rows[0][1] != "NULL" || *r.Rows[0][2] != "" || r.Rows[0][3] != nil || *r.Rows[0][4] != "9007199254740993.125" || *r.Rows[0][5] != "00FF" {
		t.Fatal("DML Analyze changed exact values or user rollback")
	}
	t.Logf("F6 Oracle MySQL %s: estimated I/U/D unchanged; multitable actual autocommit, autocommit=0 and existing transaction acknowledged", s.ExplainSupport().ServerVersion)
}

func TestExplainDMLMySQLCleanupFailurePreservesAcknowledgedDisposition(t *testing.T) {
	for _, transaction := range []bool{false, true} {
		t.Run(map[bool]string{false: "autocommit", true: "existingTransaction"}[transaction], func(t *testing.T) {
			s, observer := integrationSession(t), integrationSession(t)
			table := QuoteIdentifier(fmt.Sprintf("dbeer_f6_close_%d", s.connectionID))
			joined := QuoteIdentifier(fmt.Sprintf("dbeer_f6_close_join_%d", s.connectionID))
			run(t, observer, "CREATE TABLE "+table+" (id BIGINT PRIMARY KEY,note TEXT) ENGINE=InnoDB")
			run(t, observer, "CREATE TABLE "+joined+" (id BIGINT PRIMARY KEY) ENGINE=InnoDB")
			t.Cleanup(func() {
				run(t, observer, "DROP TABLE IF EXISTS "+joined)
				run(t, observer, "DROP TABLE IF EXISTS "+table)
			})
			run(t, observer, "INSERT INTO "+table+" VALUES(1,'original')")
			run(t, observer, "INSERT INTO "+joined+" VALUES(1)")
			if transaction {
				run(t, s, "BEGIN")
			}
			status := s.TransactionStatus()
			value := "changed"
			sql := "UPDATE " + table + " a JOIN " + joined + " b ON a.id=b.id SET a.note=:note"
			request := protocol.ExplainRequest{SQL: sql, Mode: "analyze", Parameters: []protocol.QueryParameter{{Name: "note", Type: "text", Value: &value}}, Context: &protocol.ExplainContext{DocumentID: "doc", TargetDocumentID: "doc", ProfileID: "profile", SessionID: "session", RangeLength: len(sql), TransactionStatus: status}, WriteIntent: &protocol.ExplainWriteIntent{Disposition: "currentSession", ExpectedTransactionStatus: status}}
			p, err := s.PrepareExplain(request)
			if err != nil {
				t.Fatal("cleanup fixture DML preparation failed")
			}
			s.work.client.Conn.Conn = failPreparedCloseTransport{s.work.client.Conn.Conn}
			out := s.ExecuteExplain(context.Background(), protocol.Command{Type: "explain.run", Explain: &request, PreparedExplainSQL: p.Preview.SQL})
			persistence := "notExecuted"
			if out.Type != "error" || !out.SQLCompleted || out.OutcomeUnknown || out.Connected || !s.closed.Load() || out.TransactionStatus != "" || out.ExplainDML == nil || out.ExplainDML.Execution != "completed" || out.ExplainDML.Persistence != persistence || out.ExplainDML.TargetExecution != "suppressed" || out.ExplainDML.TransactionAfter != status {
				t.Fatal("post-ack cleanup erased the known DML disposition or claimed a usable session")
			}
			observed := run(t, observer, "SELECT note FROM "+table)
			expected := "original"
			if *observed.Rows[0][0] != expected {
				t.Fatal("acknowledged transactional boundary changed during cleanup")
			}
		})
	}
}

func TestEstimatedExplainDMLMySQLRoutinePlanningPositiveControl(t *testing.T) {
	s := integrationSession(t)
	prefix := fmt.Sprintf("dbeer_f6_optimizer_%d", s.connectionID)
	source, target, counter, function := QuoteIdentifier(prefix+"_source"), QuoteIdentifier(prefix+"_target"), QuoteIdentifier(prefix+"_counter"), QuoteIdentifier(prefix+"_function")
	run(t, s, "CREATE TABLE "+source+" (id INT PRIMARY KEY)")
	run(t, s, "CREATE TABLE "+target+" (id INT,n INT)")
	run(t, s, "CREATE TABLE "+counter+" (n INT)")
	t.Cleanup(func() {
		run(t, s, "DROP FUNCTION IF EXISTS "+function)
		for _, table := range []string{counter, target, source} {
			run(t, s, "DROP TABLE IF EXISTS "+table)
		}
	})
	run(t, s, "INSERT INTO "+source+" VALUES(1)")
	run(t, s, "CREATE FUNCTION "+function+"(n INT) RETURNS INT MODIFIES SQL DATA BEGIN INSERT INTO "+counter+" VALUES(n); RETURN n; END")
	run(t, s, "SELECT "+function+"(5)")
	if *run(t, s, "SELECT count(*) FROM "+counter).Rows[0][0] != "1" {
		t.Fatal("owned routine mutation positive control failed")
	}
	run(t, s, "DELETE FROM "+counter)
	sql := "INSERT INTO " + target + " SELECT a.id,b.n FROM " + source + " a JOIN (SELECT " + function + "(5) AS n) b"
	assessment := safety.ClassifyEstimatedExplain("mysql", sql)
	if len(assessment) != 1 || assessment[0].Kind != safety.Unknown {
		t.Fatal("optimizer routine bypassed unknown-function policy")
	}
	r := protocol.ExplainRequest{SQL: sql, Mode: "plan"}
	p, err := s.PrepareExplain(r)
	if err != nil {
		t.Fatal("owned optimizer control rejected")
	}
	out := s.ExecuteExplain(context.Background(), protocol.Command{Type: "explain.run", Explain: &r, PreparedExplainSQL: p.Preview.SQL})
	if out.Type != "explain.result" || !out.SQLCompleted || !out.Explain.Valid() {
		t.Fatal("owned optimizer Explain control failed")
	}
	if *run(t, s, "SELECT count(*) FROM "+target).Rows[0][0] != "0" {
		t.Fatal("estimated INSERT target executed")
	}
	calls := *run(t, s, "SELECT count(*) FROM "+counter).Rows[0][0]
	if calls == "0" {
		// The documented equivalent read shape is an additional positive control;
		// optimizer versions may defer the INSERT form's constant evaluation.
		run(t, s, "EXPLAIN FORMAT=JSON SELECT * FROM "+source+" a JOIN (SELECT "+function+"(5) AS n) b")
		calls = *run(t, s, "SELECT count(*) FROM "+counter).Rows[0][0]
	}
	if calls != "0" {
		t.Log("F6 positive control: estimated Explain evaluated the owned data-changing routine; policy remains unknown/confirmed or readonly-denied")
	} else {
		t.Log("F6 optimizer deferred this server's owned routine controls; policy remains conservatively unknown/confirmed or readonly-denied")
	}
}
