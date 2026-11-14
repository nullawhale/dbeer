package postgres

import (
	"context"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

func TestExplainMetricsPostgresLive(t *testing.T) {
	fixture := newChangeFixture(t)
	opened, err := Open(context.Background(), fixture.settings)
	if err != nil {
		t.Fatal("cannot open owned advanced-plan fixture")
	}
	session := opened.(*Session)
	defer session.Close()
	t.Logf("F5 PostgreSQL verified server %s", session.ExplainSupport().ServerVersion)
	execute := func(sql string) protocol.Response {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		response := session.Execute(ctx, protocol.Command{Type: "execute", RequestID: "f5-setup", SessionID: "f5", QueryID: "f5-setup", SQL: sql})
		if response.Type != "query.result" {
			t.Fatal("owned advanced-plan fixture setup failed")
		}
		return response
	}
	explain := func(sql, mode string, timing *bool) *protocol.ExplainResult {
		t.Helper()
		request := protocol.ExplainRequest{SQL: sql, Mode: mode}
		if timing != nil {
			request.Options = &protocol.ExplainOptions{PostgreSQL: &protocol.PostgresExplainOptions{Timing: timing}}
		}
		prepared, err := session.PrepareExplain(request)
		if err != nil || !strings.Contains(prepared.Preview.SQL, "VERBOSE TRUE") {
			t.Fatal("verbose evidence absent from authorized SQL")
		}
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		response := session.ExecuteExplain(ctx, protocol.Command{Type: "explain.run", RequestID: "f5-run", SessionID: "f5", QueryID: "f5-run", Explain: &request, PreparedExplainSQL: prepared.Preview.SQL})
		if response.Type != "explain.result" || !response.SQLCompleted || response.Explain == nil || !response.Explain.Valid() || response.Explain.Status != "tree" || response.Explain.AdvancedMetrics == nil {
			t.Fatal("advanced-plan capture failed")
		}
		return response.Explain
	}
	execute("CREATE TEMP TABLE dbeer_f5_counter (n integer NOT NULL)")
	execute("INSERT INTO pg_temp.dbeer_f5_counter VALUES (0)")
	execute("CREATE FUNCTION pg_temp.dbeer_f5_once() RETURNS integer LANGUAGE plpgsql VOLATILE AS $$ BEGIN UPDATE pg_temp.dbeer_f5_counter SET n=n+1; RETURN 1; END $$")
	count := func() string {
		t.Helper()
		response := execute("SELECT n FROM pg_temp.dbeer_f5_counter")
		if len(response.Rows) != 1 || len(response.Rows[0]) != 1 || response.Rows[0][0] == nil {
			t.Fatal("single-execution witness missing")
		}
		return *response.Rows[0][0]
	}
	explain("SELECT pg_temp.dbeer_f5_once()", "plan", nil)
	if count() != "0" {
		t.Fatal("estimated verbose plan executed target")
	}
	serial := explain("SELECT pg_temp.dbeer_f5_once()", "analyze", nil)
	if count() != "1" || serial.Nodes[0].AdvancedMetrics.ExclusiveTime.Value == nil {
		t.Fatal("serial leaf evidence or single execution missing")
	}
	disabled := false
	serial = explain("SELECT pg_temp.dbeer_f5_once()", "analyze", &disabled)
	if count() != "2" || serial.Nodes[0].AdvancedMetrics.ExclusiveTime.UnavailableReason != "disabled" {
		t.Fatal("disabled timing lost single-execution semantics")
	}

	table := fixture.table("dbeer_f5_parallel")
	fixture.exec("CREATE TABLE " + table + " AS SELECT generate_series(1,50000) AS n")
	fixture.exec("ALTER TABLE " + table + " SET (parallel_workers=2)")
	fixture.exec("ANALYZE " + table)
	for _, sql := range []string{"SET max_parallel_workers_per_gather=2", "SET min_parallel_table_scan_size=0", "SET parallel_setup_cost=0", "SET parallel_tuple_cost=0", "SET track_io_timing=on", "SET jit=on", "SET jit_above_cost=0", "SET jit_inline_above_cost=0", "SET jit_optimize_above_cost=0"} {
		execute(sql)
	}
	parallel := explain("SELECT sum(n) FROM "+table, "analyze", nil)
	workers, measuredWorkers, jit, io := 0, 0, false, false
	for _, node := range parallel.Nodes {
		advanced := node.AdvancedMetrics
		if advanced.ExecutionScope != "parallel" || advanced.ExclusiveTime.Value != nil {
			t.Fatal("parallel work presented as exclusive serial time")
		}
		workers += len(advanced.Workers)
		if advanced.Counters["ioReadTime"].Value != nil || advanced.Counters["sharedIOReadTime"].Value != nil {
			io = true
		}
		if advanced.JIT != nil {
			jit = true
			if advanced.JIT.Scope != "queryAggregate" {
				t.Fatal("global JIT scope")
			}
		}
		for _, worker := range advanced.Workers {
			if worker.Metrics["actualRows"].Value != nil || worker.Metrics["loops"].Value != nil {
				if worker.Metrics["actualRows"].Value == nil || worker.Metrics["loops"].Value == nil {
					t.Fatal("inconsistent verbose worker rows/loops")
				}
				measuredWorkers++
			}
		}
	}
	if measuredWorkers == 0 || !io {
		t.Fatal("verified parallel fixture did not report verbose worker evidence")
	}
	t.Logf("F5 captured %d per-node worker observations (%d with rows/loops); I/O counters reported: %t; query aggregate JIT reported: %t", workers, measuredWorkers, io, jit)
	parallel = explain("SELECT sum(n) FROM "+table, "analyze", &disabled)
	for _, node := range parallel.Nodes {
		if node.Metrics["totalTime"].Value != nil || node.Metrics["totalTime"].UnavailableReason != "disabled" {
			t.Fatal("parallel TIMING FALSE node semantics")
		}
		for _, worker := range node.AdvancedMetrics.Workers {
			if value := worker.Metrics["totalTime"]; value.Value != nil || value.UnavailableReason != "disabled" {
				t.Fatal("parallel TIMING FALSE worker semantics")
			}
		}
	}
}
