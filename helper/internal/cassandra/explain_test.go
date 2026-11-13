package cassandra

import (
	"context"
	"dbeer/helper/internal/protocol"
	"testing"
)

func TestCassandraDiagnosticExactReadScopeAndPreparation(t *testing.T) {
	s := &Session{}
	request := protocol.ExplainRequest{SQL: "SELECT * FROM fixture.items WHERE id=1", Mode: "analyze"}
	p, err := s.PrepareExplain(request)
	if err != nil || !p.Preview.Support.Valid() || p.Preview.Support.Modes[0] != "analyze" {
		t.Fatal("trace read rejected")
	}
	for _, sql := range []string{"SELECT * FROM fixture.items; SELECT * FROM fixture.items", "INSERT INTO fixture.items(id) VALUES(1)", "BEGIN BATCH INSERT INTO fixture.items(id) VALUES(1); APPLY BATCH", "USE fixture", "SELECT fixture.custom_fn(x) FROM fixture.items", "SELECT * FROM fixture.items WHERE id=?", "SELECT * FROM fixture.items LIMIT :limit"} {
		if _, err := s.PrepareExplain(protocol.ExplainRequest{SQL: sql, Mode: "analyze"}); err == nil {
			t.Fatal("non-read or ambiguous input admitted")
		}
	}
	if _, err := s.PrepareExplain(protocol.ExplainRequest{SQL: request.SQL, Mode: "plan"}); err == nil {
		t.Fatal("estimated CQL plan invented")
	}
	r := s.ExecuteExplain(context.Background(), protocol.Command{Explain: &request, PreparedExplainSQL: p.Preview.SQL + " "})
	if !r.SQLNotExecuted || r.Type != "error" {
		t.Fatal("changed scope reached driver")
	}
}
func TestCassandraDiagnosticTraceIDsAndMissingMetrics(t *testing.T) {
	traces := &diagnosticTraces{}
	for i := 0; i < 6; i++ {
		id := make([]byte, 16)
		id[15] = byte(i)
		traces.Trace(id)
		traces.Trace(id)
	}
	if len(traces.ids) != 4 || !traces.limited {
		t.Fatal("trace capture unbounded or not distinct")
	}
	zero := 0
	negative := -1
	for _, m := range []protocol.DiagnosticMetric{traceMetric(nil, "sourceElapsed"), traceMetric(&zero, "coordinator"), traceMetric(&negative, "sourceElapsed")} {
		if !m.Valid() {
			t.Fatal("invalid trace metric")
		}
	}
	if traceMetric(nil, "sourceElapsed").Value != nil || *traceMetric(&zero, "coordinator").Value != "0" || traceMetric(&negative, "sourceElapsed").Value != nil {
		t.Fatal("missing/negative elapsed became zero")
	}
}

func TestCassandraDiagnosticFirstServerPageIsIndependentOfDisplayResume(t *testing.T) {
	for _, hasMore := range []bool{false, true} {
		traces := &diagnosticTraces{}
		var state []byte
		if hasMore {
			state = []byte("opaque-next-page")
		}
		traces.observeFirstPage(state)
		traces.observeFirstPage([]byte("later-observation"))
		if !traces.firstPageObserved || traces.firstPageHasMore != hasMore {
			t.Fatal("first server-page evidence changed after observation")
		}
	}
}
