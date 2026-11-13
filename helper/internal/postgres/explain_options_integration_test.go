package postgres

import (
	"context"
	"dbeer/helper/internal/protocol"
	"testing"
	"time"
)

func TestExplainOptionsLiveVersionAndSingleExecution(t *testing.T) {
	f := newChangeFixture(t)
	opened, err := Open(context.Background(), f.settings)
	if err != nil {
		t.Fatal("cannot open owned PostgreSQL Explain fixture")
	}
	s := opened.(*Session)
	defer s.Close()
	support := s.ExplainSupport()
	if !support.Valid() || support.Options == nil || support.Options.PostgreSQL == nil {
		t.Fatal("live PostgreSQL options missing")
	}
	t.Logf("F3 PostgreSQL verified server %s", support.ServerVersion)
	execute := func(sql string) protocol.Response {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		r := s.Execute(ctx, protocol.Command{Type: "execute", RequestID: "f3-setup", SessionID: "f3", QueryID: "f3-setup", SQL: sql})
		if r.Type != "query.result" {
			t.Fatal("owned PostgreSQL fixture command failed")
		}
		return r
	}
	execute("CREATE TEMP TABLE dbeer_f3_counter (n integer NOT NULL)")
	execute("INSERT INTO pg_temp.dbeer_f3_counter VALUES (0)")
	execute("CREATE TEMP TABLE dbeer_f3_input (n integer NOT NULL)")
	execute("INSERT INTO pg_temp.dbeer_f3_input VALUES (1),(2)")
	execute("CREATE FUNCTION pg_temp.dbeer_f3_once() RETURNS integer LANGUAGE plpgsql VOLATILE AS $$ BEGIN UPDATE pg_temp.dbeer_f3_counter SET n=n+1; RETURN 1; END $$")
	count := func() string {
		t.Helper()
		r := execute("SELECT n FROM pg_temp.dbeer_f3_counter")
		if len(r.Rows) != 1 || r.Rows[0][0] == nil {
			t.Fatal("single-execution witness missing")
		}
		return *r.Rows[0][0]
	}
	b := func(v bool) *bool { return &v }
	explain := func(mode string, pg *protocol.PostgresExplainOptions) protocol.Response {
		t.Helper()
		request := protocol.ExplainRequest{SQL: "SELECT pg_temp.dbeer_f3_once() FROM pg_temp.dbeer_f3_input", Mode: mode, Options: &protocol.ExplainOptions{PostgreSQL: pg}}
		p, err := s.PrepareExplain(request)
		if err != nil {
			t.Fatal("live options preparation rejected")
		}
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		return s.ExecuteExplain(ctx, protocol.Command{Type: "explain.run", RequestID: "f3-run", SessionID: "f3", QueryID: "f3-run", Explain: &request, PreparedExplainSQL: p.Preview.SQL})
	}
	check := func(r protocol.Response) {
		t.Helper()
		if r.Type != "explain.result" || !r.SQLCompleted || r.Explain == nil || !r.Explain.Valid() || r.Explain.Status != "tree" || r.Explain.Format != "json" {
			t.Fatal("live PostgreSQL option collection failed")
		}
	}
	planOptions := &protocol.PostgresExplainOptions{Buffers: b(true), Settings: b(true)}
	for _, option := range support.Options.PostgreSQL.Plan {
		if option == "memory" {
			planOptions.Memory = b(true)
		}
	}
	check(explain("plan", planOptions))
	if count() != "0" {
		t.Fatal("estimated PostgreSQL plan executed target")
	}
	pg := &protocol.PostgresExplainOptions{Buffers: b(true), Settings: b(true), WAL: b(true), Timing: b(false)}
	for _, option := range support.Options.PostgreSQL.Analyze {
		if option == "memory" {
			pg.Memory = b(true)
		}
		if option == "serialize" {
			pg.Serialize = "binary"
		}
	}
	r := explain("analyze", pg)
	check(r)
	if count() != "2" {
		t.Fatal("PostgreSQL Analyze execution was delivered more or less than once")
	}
	if r.Explain.Nodes[0].Metrics["totalTime"].UnavailableReason != "disabled" || r.Explain.Nodes[0].Metrics["actualRows"].Value == nil || r.Explain.Metrics["executionTime"].Value == nil {
		t.Fatal("TIMING FALSE confused with missing counts or summary")
	}
	execute("UPDATE pg_temp.dbeer_f3_counter SET n=0")
	pg.Timing = b(true)
	if pg.Serialize != "" {
		pg.Serialize = "text"
	}
	r = explain("analyze", pg)
	check(r)
	if count() != "2" || r.Explain.Nodes[0].Metrics["totalTime"].Value == nil {
		t.Fatal("TIMING TRUE single execution/time missing")
	}
	if pg.Serialize != "" {
		execute("UPDATE pg_temp.dbeer_f3_counter SET n=0")
		pg.Serialize = "none"
		r = explain("analyze", pg)
		check(r)
		if count() != "2" {
			t.Fatal("SERIALIZE NONE target execution count")
		}
	}
	t.Log("F3 PostgreSQL applicable version options and single execution passed")
}
