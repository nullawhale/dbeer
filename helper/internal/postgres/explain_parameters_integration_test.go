package postgres

import (
	"context"
	"dbeer/helper/internal/protocol"
	"strings"
	"testing"
	"time"
)

func TestExplainParametersPostgresLive(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	opened, err := Open(ctx, f.settings)
	if err != nil {
		t.Fatal("cannot open Explain fixture")
	}
	s := opened.(*Session)
	defer s.Close()
	exec := func(sql string) protocol.Response {
		r := s.Execute(ctx, protocol.Command{Type: "execute", RequestID: "setup", SessionID: "s", QueryID: "setup", SQL: sql})
		if r.Type != "query.result" {
			t.Fatal("Explain fixture setup failed")
		}
		return r
	}
	exec("CREATE TEMP TABLE explain_evidence(id integer PRIMARY KEY,note text)")
	exec("BEGIN")
	exec("INSERT INTO explain_evidence VALUES(1,'uncommitted')")
	exec("SET LOCAL plan_cache_mode='force_generic_plan'")
	one := "1"
	text := "NULL ' ; DELETE FROM explain_evidence; --"
	empty := ""
	decimal := "9007199254740993.125"
	request := protocol.ExplainRequest{SQL: "SELECT * FROM explain_evidence WHERE id=:id AND :text=:text AND :empty='' AND :null IS NULL AND :decimal=9007199254740993.125", Mode: "plan", PlanKind: "custom", Parameters: []protocol.QueryParameter{{Name: "id", Type: "integer", Value: &one}, {Name: "text", Type: "text", Value: &text}, {Name: "empty", Type: "text", Value: &empty}, {Name: "null", Type: "text"}, {Name: "decimal", Type: "decimal", Value: &decimal}}}
	run := func(r protocol.ExplainRequest, ctx context.Context) protocol.Response {
		p, err := s.PrepareExplain(r)
		if err != nil {
			t.Fatal("cannot prepare selected Explain kind")
		}
		return s.ExecuteExplain(ctx, protocol.Command{Type: "explain.run", RequestID: "r", SessionID: "s", QueryID: "q", Explain: &r, PreparedExplainSQL: p.Preview.SQL})
	}
	custom := run(request, ctx)
	if custom.Type != "explain.result" || !custom.Explain.Valid() || !custom.SQLCompleted || custom.TransactionStatus != "transaction" || strings.Contains(custom.Explain.Raw, "$1") {
		t.Fatal("custom bound Explain lost values or caller session")
	}
	if strings.HasPrefix(s.ExplainSupport().ServerVersion, "14.") || strings.HasPrefix(s.ExplainSupport().ServerVersion, "15.") {
		if _, err := s.PrepareExplain(protocol.ExplainRequest{SQL: request.SQL, Mode: "plan", PlanKind: "generic", Parameters: request.Parameters}); err == nil {
			t.Fatal("generic Explain accepted by old server")
		}
	} else {
		request.PlanKind = "generic"
		generic := run(request, ctx)
		if generic.Type != "explain.result" || !generic.Explain.Valid() || !strings.Contains(generic.Explain.Raw, "$1") || generic.TransactionStatus != "transaction" {
			t.Fatalf("generic Explain failed: type=%s category=%s state=%s transaction=%s", generic.Type, generic.Category, generic.SQLState, generic.TransactionStatus)
		}
	}
	request.PlanKind = "custom"
	request.Mode = "analyze"
	analyze := run(request, ctx)
	if analyze.Type != "explain.result" || !analyze.SQLCompleted || analyze.Explain.Nodes[0].Metrics["actualRows"].Value == nil || *analyze.Explain.Nodes[0].Metrics["actualRows"].Value != "1" {
		t.Fatal("Analyze did not use exact bound decimal/text/null/empty values")
	}
	retained := exec("SELECT count(*),min(note),current_setting('plan_cache_mode') FROM explain_evidence")
	if len(retained.Rows) != 1 || *retained.Rows[0][0] != "1" || *retained.Rows[0][1] != "uncommitted" || *retained.Rows[0][2] != "force_generic_plan" {
		t.Fatal("Explain changed session settings, data or transaction")
	}
	exec("ROLLBACK")
	retained = exec("SELECT count(*) FROM explain_evidence")
	if *retained.Rows[0][0] != "0" {
		t.Fatal("Explain committed caller transaction")
	}
	if len(s.ExplainSupport().PlanKinds) > 1 {
		// A generic plan must use the same cancellable owner while catalog locks
		// block planning, without executing a setup or probe on another session.
		f.exec("CREATE TABLE " + f.table("generic_lock") + "(id integer)")
		f.exec("BEGIN")
		f.exec("LOCK TABLE " + f.table("generic_lock") + " IN ACCESS EXCLUSIVE MODE")
		genericLock := protocol.ExplainRequest{SQL: "SELECT * FROM " + f.table("generic_lock") + " WHERE id=:id", Mode: "plan", PlanKind: "generic", Parameters: []protocol.QueryParameter{{Name: "id", Type: "integer", Value: &one}}}
		lockCtx, lockCancel := context.WithCancel(ctx)
		lockTimer := time.AfterFunc(150*time.Millisecond, lockCancel)
		locked := run(genericLock, lockCtx)
		lockTimer.Stop()
		lockCancel()
		f.exec("ROLLBACK")
		if locked.Type != "error" || locked.Category != "cancelled" || locked.OutcomeUnknown || !locked.Connected {
			t.Fatal("generic Explain cancellation lost the owning session")
		}
		exec("SELECT 1")

	}

	delay := "5.0"
	sleep := protocol.ExplainRequest{SQL: "SELECT pg_sleep(:delay)", Mode: "analyze", Parameters: []protocol.QueryParameter{{Name: "delay", Type: "decimal", Value: &delay}}}
	cancelled, cancel := context.WithCancel(ctx)
	timer := time.AfterFunc(150*time.Millisecond, cancel)
	defer timer.Stop()
	defer cancel()
	result := run(sleep, cancelled)
	if result.Type != "error" || result.OutcomeUnknown || !result.Connected || result.Category != "cancelled" {
		t.Fatal("bound Explain cancellation lost authoritative session outcome")
	}
	exec("SELECT 1")
}
