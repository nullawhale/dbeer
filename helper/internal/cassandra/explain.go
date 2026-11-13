package cassandra

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strconv"
	"sync"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/safety"
	gocql "github.com/apache/cassandra-gocql-driver/v2"
)

type diagnosticTraceKey struct{}
type diagnosticTraces struct {
	mu                sync.Mutex
	ids               []gocql.UUID
	limited           bool
	firstPageObserved bool
	firstPageHasMore  bool
}

// Interactive continuation may resume within the current page. Diagnostics
// retain the server's first-page boundary independently of display truncation.
func (t *diagnosticTraces) observeFirstPage(state []byte) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if !t.firstPageObserved {
		t.firstPageObserved = true
		t.firstPageHasMore = len(state) > 0
	}
}

func (t *diagnosticTraces) Trace(id []byte) {
	if len(id) != 16 {
		return
	}
	var value gocql.UUID
	copy(value[:], id)
	t.mu.Lock()
	defer t.mu.Unlock()
	for _, old := range t.ids {
		if old == value {
			return
		}
	}
	if len(t.ids) < 4 {
		t.ids = append(t.ids, value)
	} else {
		t.limited = true
	}
}
func (*Session) ExplainSupport() protocol.ExplainSupport {
	return protocol.ExplainSupport{Engine: "cassandra", ServerVersion: "Cassandra", Format: "cassandraTrace", DiagnosticModel: "cassandraTrace", Modes: []string{"analyze"}}
}
func (s *Session) PrepareExplain(r protocol.ExplainRequest) (adapter.PreparedExplain, error) {
	p := adapter.PreparedExplain{Request: r}
	if !r.Valid() || r.Mode != "analyze" || len(r.Parameters) != 0 || r.PlanKind != "" || !safety.CQLTraceTarget(r.SQL) {
		return p, errors.New("Cassandra provides tracing, not an estimated relational plan. Trace requires one known read-only SELECT without bound parameters; writes, batches, setup and unknown functions are unsupported.")
	}
	if r.Context != nil && r.Context.TransactionStatus != "unsupported" {
		return p, errors.New("The Cassandra diagnostic session state changed.")
	}
	// Review includes both the exact CQL and the fixed, bounded collection scope.
	p.Preview = protocol.ExplainPreview{SQL: "TRACE FIRST SERVER PAGE (200 rows); collect system_traces at consistency ONE for at most 2 seconds\n" + r.SQL, Mode: r.Mode, Support: s.ExplainSupport()}
	return p, nil
}
func (s *Session) ExecuteExplain(ctx context.Context, c protocol.Command) protocol.Response {
	started := time.Now()
	reject := func(message string) protocol.Response {
		r := s.failure(c, "validation", message)
		r.SQLNotExecuted = true
		return r
	}
	if c.Explain == nil {
		return reject("Missing Cassandra tracing request.")
	}
	p, err := s.PrepareExplain(*c.Explain)
	if err != nil {
		return reject(err.Error())
	}
	if p.Preview.SQL != c.PreparedExplainSQL {
		return reject("Cassandra tracing requires the exact reviewed CQL and collection scope.")
	}
	traces := &diagnosticTraces{}
	traceCtx := context.WithValue(ctx, diagnosticTraceKey{}, traces)
	// Reuse the normal physical-session query path. One bounded server page is
	// observed; later pages are not fetched to collect or format diagnostics.
	_, _, _, failure := s.query(traceCtx, c, c.Explain.SQL, nil, 0, nil, &displayBudget{}, false, true, nil, 0, false)
	if failure != nil {
		return *failure
	}
	traces.mu.Lock()
	ids := append([]gocql.UUID(nil), traces.ids...)
	limited := traces.limited
	hasMorePages := traces.firstPageHasMore
	traces.mu.Unlock()
	diagnostic := &protocol.CassandraDiagnostic{Scope: "firstServerPage", CollectionConsistency: "ONE", PageSize: pageRows, HasMorePages: hasMorePages, TraceSessions: []protocol.CassandraTraceSession{}, CollectionStatus: "partial"}
	collectionCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	traceBytes := 0
	anyObserved, anyUnavailable := false, false
	for _, id := range ids {
		trace, status := s.collectTrace(collectionCtx, id, protocol.MaxTraceEvents-totalTraceEvents(diagnostic.TraceSessions), &traceBytes)
		diagnostic.TraceSessions = append(diagnostic.TraceSessions, trace)
		if trace.Duration.Value != nil || len(trace.Events) > 0 {
			anyObserved = true
		}
		if status == "unavailable" {
			anyUnavailable = true
		}
		if status == "limited" {
			limited = true
		}
	}
	if len(ids) == 0 || anyUnavailable && !anyObserved {
		diagnostic.CollectionStatus = "unavailable"
	}
	if ctx.Err() != nil {
		diagnostic.CollectionStatus = "cancelled"
	}
	if limited {
		diagnostic.CollectionStatus = "limited"
	}
	raw, _ := json.MarshalIndent(diagnostic, "", "  ")
	result := protocol.ExplainResult{Support: p.Preview.Support, Mode: "analyze", Status: "diagnostic", Complete: false, Raw: string(raw), Roots: []string{}, Nodes: []protocol.ExplainNode{}, Metrics: map[string]protocol.ExplainMetric{}, EngineDiagnostic: &protocol.EngineDiagnostic{Kind: "cassandraTrace", Cassandra: diagnostic}, Diagnostic: "Cassandra traced only the first server page (up to 200 rows). Preparation and execution can have separate trace sessions. Trace events are written asynchronously; this bounded observation can miss late events. Coordinator duration and each source node's elapsed microseconds are distinct; do not add, subtract, or treat them as exclusive or global time. No user statement was repeated."}
	if len(raw) > protocol.MaxExplainRawBytes {
		result.Raw = ""
		diagnostic.CollectionStatus = "limited"
	}
	// Preserve confirmed page acknowledgement even if collection was cancelled or
	// trace permissions/retention prevented metadata from becoming available.
	return protocol.Response{Type: "explain.result", RequestID: c.RequestID, SessionID: c.SessionID, QueryID: c.QueryID, Connected: true, TransactionStatus: "unsupported", SQLCompleted: true, DurationMS: float64(time.Since(started)) / float64(time.Millisecond), Explain: &result}
}
func totalTraceEvents(sessions []protocol.CassandraTraceSession) int {
	n := 0
	for _, s := range sessions {
		n += len(s.Events)
	}
	return n
}
func traceMetric(value *int, basis string) protocol.DiagnosticMetric {
	m := protocol.DiagnosticMetric{Unit: "us", Basis: basis, UnavailableReason: "notReported"}
	if value != nil && *value >= 0 {
		text := strconv.Itoa(*value)
		m.Value = &text
		m.UnavailableReason = ""
	}
	return m
}
func (s *Session) collectTrace(ctx context.Context, id gocql.UUID, remaining int, retainedBytes *int) (protocol.CassandraTraceSession, string) {
	trace := protocol.CassandraTraceSession{ID: id.String(), Duration: traceMetric(nil, "coordinator"), Events: []protocol.CassandraTraceEvent{}}
	status := "partial"
	// A fixed small polling budget tolerates eventual trace-session publication.
	// Metadata reads are never traced and never re-execute the user's SELECT.
	for attempt := 0; attempt < 4; attempt++ {
		var coordinator net.IP
		var duration *int
		var started time.Time
		var command string
		query := ConfigureQuery(s.driver.Query("SELECT command, coordinator, duration, started_at FROM system_traces.sessions WHERE session_id = ?", id), s.keyspace).Trace(nil).Consistency(gocql.One)
		err := query.ScanContext(ctx, &command, &coordinator, &duration, &started)
		if err == nil {
			if len(command) > 256 {
				return trace, "limited"
			}
			trace.Command = command
			trace.Coordinator = coordinator.String()
			if !started.IsZero() {
				trace.StartedAt = started.UTC().Format(time.RFC3339Nano)
			}
			trace.Duration = traceMetric(duration, "coordinator")
			if duration != nil {
				status = "observed"
				break
			}
		} else if !errors.Is(err, gocql.ErrNotFound) {
			return trace, "unavailable"
		}
		if attempt < 3 {
			timer := time.NewTimer(150 * time.Millisecond)
			select {
			case <-ctx.Done():
				timer.Stop()
				return trace, "partial"
			case <-timer.C:
			}
		}
	}
	if remaining <= 0 {
		return trace, "limited"
	}
	if remaining > protocol.MaxTraceEvents {
		remaining = protocol.MaxTraceEvents
	}
	// LIMIT bounds rows at the server. One additional row detects truncation.
	query := ConfigureQuery(s.driver.Query(fmt.Sprintf("SELECT event_id, activity, source, source_elapsed, thread FROM system_traces.events WHERE session_id = ? LIMIT %d", remaining+1), id), s.keyspace).Trace(nil).Consistency(gocql.One).PageSize(remaining + 1)
	iter := query.IterContext(ctx)
	var eventID gocql.UUID
	var activity, thread string
	var source net.IP
	var elapsed *int
	for iter.Scan(&eventID, &activity, &source, &elapsed, &thread) {
		if len(trace.Events) >= remaining {
			status = "limited"
			break
		}
		if len(activity) > 16384 || len(thread) > 1024 {
			status = "limited"
			continue
		}
		event := protocol.CassandraTraceEvent{ID: eventID.String(), Timestamp: eventID.Time().UTC().Format(time.RFC3339Nano), Activity: activity, Source: source.String(), Thread: thread, SourceElapsed: traceMetric(elapsed, "sourceElapsed")}
		encoded, _ := json.Marshal(event)
		if *retainedBytes+len(encoded) > 1024*1024 {
			status = "limited"
			break
		}
		*retainedBytes += len(encoded)
		trace.Events = append(trace.Events, event)
	}
	if err := iter.Close(); err != nil {
		return trace, "partial"
	}
	return trace, status
}
