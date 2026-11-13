package mysql

import (
	"context"
	"dbeer/helper/internal/protocol"
	"testing"
	"time"
)

func TestExplainOptionsLiveVersionFormatAndSingleExecution(t *testing.T) {
	s := integrationSession(t)
	support := s.ExplainSupport()
	if !support.Valid() || support.Options == nil || support.Options.MySQL == nil {
		t.Fatal("live version capability missing")
	}
	t.Logf("F3 MySQL verified server %s", support.ServerVersion)
	execute := func(sql string) protocol.Response {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		r := s.Execute(ctx, protocol.Command{Type: "execute", RequestID: "f3-setup", SessionID: "f3", QueryID: "f3-setup", SQL: sql})
		if r.Type != "query.result" {
			t.Fatalf("owned fixture command failed: type=%s category=%s state=%s connected=%t unknown=%t", r.Type, r.Category, r.SQLState, r.Connected, r.OutcomeUnknown)
		}
		return r
	}
	execute("CREATE TABLE dbeer_f3_counter (n INT NOT NULL)")
	execute("INSERT INTO dbeer_f3_counter VALUES (0)")
	execute("CREATE TABLE dbeer_f3_input (n INT NOT NULL)")
	execute("INSERT INTO dbeer_f3_input VALUES (1),(2)")
	execute("CREATE FUNCTION dbeer_f3_once() RETURNS INT MODIFIES SQL DATA BEGIN UPDATE dbeer_f3_counter SET n=n+1; RETURN 1; END")
	t.Cleanup(func() {
		for _, sql := range []string{"DROP FUNCTION IF EXISTS dbeer_f3_once", "DROP TABLE IF EXISTS dbeer_f3_input", "DROP TABLE IF EXISTS dbeer_f3_counter"} {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			r := s.Execute(ctx, protocol.Command{Type: "execute", RequestID: "f3-cleanup", SessionID: "f3", QueryID: "f3-cleanup", SQL: sql})
			cancel()
			if r.Type != "query.result" {
				t.Error("owned MySQL fixture cleanup failed")
			}
		}
	})
	count := func() string {
		t.Helper()
		r := execute("SELECT (SELECT n FROM dbeer_f3_counter)")
		if len(r.Rows) != 1 || len(r.Rows[0]) != 1 || r.Rows[0][0] == nil {
			t.Fatal("single-execution witness missing")
		}
		return *r.Rows[0][0]
	}
	explain := func(mode, format string) protocol.Response {
		t.Helper()
		request := protocol.ExplainRequest{SQL: "SELECT n FROM dbeer_f3_input WHERE dbeer_f3_once()=1", Mode: mode, Options: &protocol.ExplainOptions{MySQL: &protocol.MySQLExplainOptions{Format: format}}}
		p, err := s.PrepareExplain(request)
		if err != nil {
			t.Fatal("live format preparation rejected")
		}
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		return s.ExecuteExplain(ctx, protocol.Command{Type: "explain.run", RequestID: "f3-run", SessionID: "f3", QueryID: "f3-run", Explain: &request, PreparedExplainSQL: p.Preview.SQL})
	}
	check := func(r protocol.Response, format string) {
		t.Helper()
		if r.Type != "explain.result" || !r.SQLCompleted || r.Explain == nil || !r.Explain.Valid() || r.Explain.Status != "tree" || r.Explain.Format != format {
			t.Fatalf("live %s format/completion normalization failed", format)
		}
	}
	check(explain("plan", "json"), "jsonV1")
	if count() != "0" {
		t.Fatal("estimated JSON plan executed its target")
	}
	if support.Format == "tree" {
		check(explain("plan", "tree"), "tree")
		if count() != "0" {
			t.Fatal("estimated TREE plan executed its target")
		}
	}
	if len(support.Modes) == 1 {
		if support.AnalyzeUnavailableReason == "" {
			t.Fatal("older server Analyze reason missing")
		}
		_, err := s.PrepareExplain(protocol.ExplainRequest{SQL: "SELECT 1", Mode: "analyze"})
		if err == nil {
			t.Fatal("older server admitted Analyze")
		}
	} else {
		check(explain("analyze", "tree"), "tree")
		if count() != "2" {
			t.Fatal("TREE Analyze execution was delivered more or less than once")
		}
		execute("UPDATE dbeer_f3_counter SET n=0")
	}
	if support.Options.MySQL.JSONAnalyzeRequiresVersion2 {
		// Only the owned disposable session is explicitly configured by this test.
		original := execute("SELECT @@SESSION.explain_json_format_version")
		if len(original.Rows) != 1 || original.Rows[0][0] == nil {
			t.Fatal("JSON format setting missing")
		}
		originalVersion := *original.Rows[0][0]
		if originalVersion != "1" && originalVersion != "2" {
			t.Fatal("unknown JSON format setting")
		}
		defer execute("SET @@SESSION.explain_json_format_version=" + originalVersion)
		execute("SET @@SESSION.explain_json_format_version=1")
		rejected := explain("analyze", "json")
		if rejected.Type != "error" || !rejected.SQLNotExecuted || rejected.OutcomeUnknown || !rejected.Connected || count() != "0" {
			t.Fatal("JSON v1 preflight executed analyzed SQL or lost known outcome")
		}
		execute("SET @@SESSION.explain_json_format_version=2")
		check(explain("plan", "json"), "jsonV2")
		if count() != "0" {
			t.Fatal("estimated JSON v2 ran target")
		}
		check(explain("analyze", "json"), "jsonV2")
		if count() != "2" {
			t.Fatal("JSON v2 Analyze execution was delivered more or less than once")
		}
		current := execute("SELECT @@SESSION.explain_json_format_version")
		if current.Rows[0][0] == nil || *current.Rows[0][0] != "2" {
			t.Fatal("Explain changed user session settings")
		}
	}
	t.Log("F3 MySQL applicable version formats, preflight and single execution passed")
}
