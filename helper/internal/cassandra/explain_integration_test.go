package cassandra_test

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestCassandraDiagnosticLiveTraceFirstPageAndMetrics(t *testing.T) {
	c := liveConnection(t)
	physical := liveOpen(t, c)
	diagnostics, ok := physical.(adapter.ExplainSession)
	if !ok {
		t.Fatal("actual session did not advertise tracing")
	}
	liveSQL(t, physical, "CREATE TABLE IF NOT EXISTS dbeer.diagnostic_items (pk int, id int, note text, PRIMARY KEY(pk,id))")
	liveSQL(t, physical, "TRUNCATE dbeer.diagnostic_items")
	var batch strings.Builder
	batch.WriteString("BEGIN UNLOGGED BATCH ")
	for i := 0; i < 230; i++ {
		fmt.Fprintf(&batch, "INSERT INTO dbeer.diagnostic_items(pk,id,note) VALUES(1,%d,'fixture');", i)
	}
	batch.WriteString("APPLY BATCH")
	liveSQL(t, physical, batch.String())
	request := protocol.ExplainRequest{SQL: "SELECT id,note FROM dbeer.diagnostic_items WHERE pk=1", Mode: "analyze"}
	p, err := diagnostics.PrepareExplain(request)
	if err != nil {
		t.Fatal("trace preparation failed")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	r := diagnostics.ExecuteExplain(ctx, protocol.Command{Type: "explain.run", RequestID: "trace", SessionID: "fixture", QueryID: "trace", Explain: &request, PreparedExplainSQL: p.Preview.SQL})
	if r.Type != "explain.result" || !r.SQLCompleted || r.Explain == nil || !r.Explain.Valid() || r.Explain.Complete {
		t.Fatalf("trace result invalid: %s %s", r.Type, r.Category)
	}
	trace := r.Explain.EngineDiagnostic.Cassandra
	if trace.Scope != "firstServerPage" || trace.PageSize != 200 || !trace.HasMorePages || len(trace.TraceSessions) == 0 {
		t.Fatal("real tracing lost first-page scope or trace IDs")
	}
	measured, events := false, 0
	for _, session := range trace.TraceSessions {
		measured = measured || session.Duration.Value != nil
		for _, event := range session.Events {
			events++
			if event.SourceElapsed.Value != nil && event.SourceElapsed.Basis != "sourceElapsed" {
				t.Fatal("source elapsed misrepresented")
			}
		}
	}
	if !measured || events == 0 {
		t.Fatalf("real trace fixture did not expose coordinator duration and events: status=%s sessions=%d measured=%t events=%d", trace.CollectionStatus, len(trace.TraceSessions), measured, events)
	}
	if _, err := diagnostics.PrepareExplain(protocol.ExplainRequest{SQL: request.SQL, Mode: "plan"}); err == nil {
		t.Fatal("Cassandra invented an estimated relational plan")
	}
	cancelled, stop := context.WithCancel(context.Background())
	stop()
	r = diagnostics.ExecuteExplain(cancelled, protocol.Command{Explain: &request, PreparedExplainSQL: p.Preview.SQL})
	if r.Type != "error" || r.SQLCompleted {
		t.Fatal("cancelled trace falsely completed")
	}
}

// The normal display cursor can resume inside a page. Trace page evidence must
// describe the server page even when its values exceed the display budget.
func TestCassandraDiagnosticLiveLargeRowPageProvenance(t *testing.T) {
	physical := liveOpen(t, liveConnection(t))
	diagnostics, ok := physical.(adapter.ExplainSession)
	if !ok {
		t.Fatal("actual session did not advertise tracing")
	}
	liveSQL(t, physical, "CREATE TABLE IF NOT EXISTS dbeer.diagnostic_large_items (pk int, id int, note text, note2 text, PRIMARY KEY(pk,id))")
	liveSQL(t, physical, "TRUNCATE dbeer.diagnostic_large_items")
	medium := strings.Repeat("x", 4*1024*1024)
	for id := 0; id < 2; id++ {
		liveSQL(t, physical, fmt.Sprintf("INSERT INTO dbeer.diagnostic_large_items(pk,id,note) VALUES(1,%d,'%s')", id, medium))
	}
	// Keep fixture SQL below the server prepared-statement size limit while
	// producing a single result row whose two text columns exceed 7 MiB.
	liveSQL(t, physical, "INSERT INTO dbeer.diagnostic_large_items(pk,id,note) VALUES(2,0,'"+medium+"')")
	liveSQL(t, physical, "UPDATE dbeer.diagnostic_large_items SET note2='"+medium+"' WHERE pk=2 AND id=0")
	var batch strings.Builder
	batch.WriteString("BEGIN UNLOGGED BATCH ")
	for id := 1; id <= 200; id++ {
		fmt.Fprintf(&batch, "INSERT INTO dbeer.diagnostic_large_items(pk,id,note) VALUES(2,%d,'fixture');", id)
	}
	batch.WriteString("APPLY BATCH")
	liveSQL(t, physical, batch.String())
	for _, item := range []struct {
		name      string
		partition int
		hasMore   bool
	}{{"terminal page above display budget", 1, false}, {"oversize first row with next server page", 2, true}} {
		t.Run(item.name, func(t *testing.T) {
			request := protocol.ExplainRequest{SQL: fmt.Sprintf("SELECT id,note,note2 FROM dbeer.diagnostic_large_items WHERE pk=%d", item.partition), Mode: "analyze"}
			p, err := diagnostics.PrepareExplain(request)
			if err != nil {
				t.Fatal("trace preparation failed")
			}
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			r := diagnostics.ExecuteExplain(ctx, protocol.Command{Type: "explain.run", RequestID: "large-trace", SessionID: "fixture", QueryID: "large-trace", Explain: &request, PreparedExplainSQL: p.Preview.SQL})
			if r.Type != "explain.result" || !r.SQLCompleted || r.Explain == nil || !r.Explain.Valid() || r.Explain.Complete {
				t.Fatalf("bounded trace failed: type=%s category=%s", r.Type, r.Category)
			}
			trace := r.Explain.EngineDiagnostic.Cassandra
			if trace.HasMorePages != item.hasMore {
				t.Fatalf("server page continuation was replaced by display resume: wantMore=%t observedMore=%t", item.hasMore, trace.HasMorePages)
			}
			if trace.Scope != "firstServerPage" || trace.PageSize != 200 || len(trace.TraceSessions) == 0 {
				t.Fatal("trace scope or observed physical execution missing")
			}
		})
	}
}
