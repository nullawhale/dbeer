package session

import (
	"context"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

type monitorTestSession struct {
	*testSession
	readonly atomic.Bool
	monitor  func(context.Context, protocol.Command) protocol.Response
}

func (physical *monitorTestSession) SetReadOnly(_ context.Context, readonly bool) error {
	physical.readonly.Store(readonly)
	return nil
}

func (physical *monitorTestSession) MonitorSnapshot(ctx context.Context, command protocol.Command) protocol.Response {
	return physical.monitor(ctx, command)
}

func monitorTestResult() protocol.Response {
	return protocol.Response{Type: "monitor.result", Connected: true, TransactionStatus: "idle", Monitor: &protocol.SessionMonitorSnapshot{
		Engine: "postgresql", CollectionStartedAt: "2026-01-02T03:04:05Z", CollectedAt: "2026-01-02T03:04:05Z",
		Sessions: []protocol.MonitoredSession{}, Waits: []protocol.MonitorWait{}, Notices: []string{}, SessionsComplete: true, WaitsComplete: true,
	}}
}

func connectMonitorTestSession(t *testing.T, manager *Manager) string {
	t.Helper()
	submit(t, manager, protocol.Command{Type: "connect", RequestID: "monitor-connect", Connection: &protocol.Connection{SessionPurpose: "monitor", Policy: &protocol.ExecutionPolicy{Environment: "production"}}})
	response := receive(t, manager)
	if response.Type != "connect.result" || !slices.Contains(response.Capabilities, protocol.SessionMonitorCapability) {
		t.Fatal("dedicated monitor did not connect with its capability")
	}
	return response.SessionID
}

func TestMonitorManagerUsesDedicatedPhysicalReadonlySession(t *testing.T) {
	var userCalls, monitorCalls atomic.Int32
	var monitorPhysical *monitorTestSession
	manager := New(func(_ context.Context, connection protocol.Connection) (adapter.Session, error) {
		physical := &monitorTestSession{testSession: &testSession{closed: make(chan struct{}), run: func(_ context.Context, command protocol.Command) protocol.Response {
			userCalls.Add(1)
			return fakeResult(command)
		}}, monitor: func(context.Context, protocol.Command) protocol.Response {
			monitorCalls.Add(1)
			return monitorTestResult()
		}}
		if connection.SessionPurpose == "monitor" {
			if connection.Policy == nil || !connection.Policy.ReadOnly {
				return nil, &adapter.ConnectionError{Category: "policy", Message: "Monitor was not opened readonly."}
			}
			monitorPhysical = physical
		}
		return physical, nil
	})
	defer manager.Close()
	sqlID := openTestSession(t, manager, "ordinary")
	monitorID := connectMonitorTestSession(t, manager)
	if monitorPhysical == nil || !monitorPhysical.readonly.Load() {
		t.Fatal("monitor did not enable physical readonly")
	}
	submit(t, manager, protocol.Command{Type: "monitor.snapshot", RequestID: "wrong-owner", SessionID: sqlID, QueryID: "wrong-owner"})
	if response := receive(t, manager); response.Type != "error" || response.Category != "policy" {
		t.Fatal("ordinary SQL tab accepted monitor work")
	}
	for _, kind := range []string{"execute", "catalog", "changes.preview", "changes.apply", "explain.run", "import.preview", "structure.load", "operation.assess"} {
		submit(t, manager, protocol.Command{Type: kind, RequestID: kind, SessionID: monitorID, QueryID: kind, SQL: "SELECT 1", Operations: []protocol.OperationRequest{{Type: "execute", SQL: "SELECT 1"}}})
		if response := receive(t, manager); response.Type != "error" || response.Category != "policy" {
			t.Fatal("user operation reached the dedicated monitor")
		}
	}
	command := protocol.Command{Type: "monitor.snapshot", RequestID: "snapshot", SessionID: monitorID, QueryID: "snapshot-query"}
	submit(t, manager, command)
	started, terminal := receive(t, manager), receive(t, manager)
	if started.Type != "query.started" || terminal.Type != "monitor.result" || started.RequestID != command.RequestID || terminal.RequestID != command.RequestID ||
		started.SessionID != monitorID || terminal.SessionID != monitorID || started.QueryID != command.QueryID || terminal.QueryID != command.QueryID || terminal.Monitor == nil || !terminal.Monitor.Valid() {
		t.Fatal("monitor lost its started/terminal correlation")
	}
	if userCalls.Load() != 0 || monitorCalls.Load() != 1 {
		t.Fatal("monitor replayed or dispatched user SQL")
	}
	o := owner{monitorOnly: true}
	if o.assess(protocol.Command{Operations: []protocol.OperationRequest{{Type: "execute", SQL: "SELECT 1"}}}, "postgresql", protocol.ExecutionPolicy{}).Type != "error" ||
		o.authorize(protocol.Command{Type: "execute", SQL: "SELECT 1"}, "postgresql", protocol.ExecutionPolicy{}) {
		t.Fatal("monitor policy boundary accepted an assessed user operation")
	}
}

func TestMonitorCancellationDoesNotAffectSQLAndAllowsFreshSnapshot(t *testing.T) {
	var monitorCalls atomic.Int32
	userCancelled := make(chan struct{})
	monitorStarted := make(chan struct{})
	manager := New(func(_ context.Context, connection protocol.Connection) (adapter.Session, error) {
		if connection.SessionPurpose != "monitor" {
			return &testSession{closed: make(chan struct{}), run: func(ctx context.Context, command protocol.Command) protocol.Response {
				<-ctx.Done()
				close(userCancelled)
				response := protocol.ErrorResponse(command, "cancelled", "SQL execution cancelled.")
				response.Connected, response.TransactionStatus = true, "idle"
				return response
			}}, nil
		}
		return &monitorTestSession{testSession: &testSession{closed: make(chan struct{})}, monitor: func(ctx context.Context, command protocol.Command) protocol.Response {
			if monitorCalls.Add(1) == 1 {
				close(monitorStarted)
				<-ctx.Done()
				response := protocol.ErrorResponse(command, "cancelled", "Monitor cancelled.")
				response.Connected, response.TransactionStatus = true, "idle"
				return response
			}
			return monitorTestResult()
		}}, nil
	})
	defer manager.Close()
	sqlID := openTestSession(t, manager, "sql")
	startTestQuery(t, manager, sqlID, "user-execution", "SELECT 1")
	monitorID := connectMonitorTestSession(t, manager)
	snapshot := protocol.Command{Type: "monitor.snapshot", RequestID: "snapshot", SessionID: monitorID, QueryID: "monitor-query"}
	submit(t, manager, snapshot)
	if response := receive(t, manager); response.Type != "query.started" {
		t.Fatal("monitor did not start while SQL remained active")
	}
	select {
	case <-monitorStarted:
	case <-time.After(time.Second):
		t.Fatal("monitor adapter did not start")
	}
	wrong := manager.Control(protocol.Command{Type: "cancel", RequestID: "wrong", SessionID: sqlID, QueryID: snapshot.QueryID})
	if wrong == nil || wrong.Status != "alreadyFinished" {
		t.Fatal("monitor cancellation did not require the matching physical session")
	}
	ack := manager.Control(protocol.Command{Type: "cancel", RequestID: "stop-monitor", SessionID: monitorID, QueryID: snapshot.QueryID})
	if ack == nil || ack.Status != "accepted" {
		t.Fatal("monitor Stop was not accepted out of band")
	}
	if response := receive(t, manager); response.Type != "error" || response.Category != "cancelled" || response.RequestID != snapshot.RequestID || response.QueryID != snapshot.QueryID || response.SessionID != monitorID {
		t.Fatal("monitor Stop lost its terminal response")
	}
	select {
	case <-userCancelled:
		t.Fatal("monitor Stop cancelled independent user SQL")
	default:
	}
	snapshot.RequestID, snapshot.QueryID = "fresh-snapshot", "fresh-query"
	submit(t, manager, snapshot)
	started, terminal := receive(t, manager), receive(t, manager)
	if started.Type != "query.started" || terminal.Type != "monitor.result" || monitorCalls.Load() != 2 {
		t.Fatal("monitor could not collect a fresh observation after cancellation")
	}
	submit(t, manager, protocol.Command{Type: "disconnect", RequestID: "disconnect-monitor", SessionID: monitorID})
	if response := receive(t, manager); response.Type != "disconnect.ack" || response.SessionID != monitorID {
		t.Fatal("monitor disconnect did not close its dedicated session")
	}
	select {
	case <-userCancelled:
		t.Fatal("monitor disconnect cancelled user SQL")
	default:
	}
}

func TestMonitorRejectsUnsupportedAdaptersAndMalformedObservations(t *testing.T) {
	var opens atomic.Int32
	manager := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
		opens.Add(1)
		return blockingSession(), nil
	})
	for _, engine := range []string{"sqlite", "cassandra", "mongodb"} {
		submit(t, manager, protocol.Command{Type: "connect", RequestID: engine, Connection: &protocol.Connection{Engine: engine, SessionPurpose: "monitor"}})
		if response := receive(t, manager); response.Type != "error" || response.Category != "capability" {
			t.Fatal("unsupported engine opened a monitor")
		}
	}
	if opens.Load() != 0 {
		t.Fatal("unsupported monitor opened a physical connection")
	}
	submit(t, manager, protocol.Command{Type: "connect", RequestID: "unsupported", Connection: &protocol.Connection{SessionPurpose: "monitor"}})
	if response := receive(t, manager); response.Type != "error" || response.Category != "capability" {
		t.Fatal("adapter without monitor support connected")
	}
	manager.Close()
	physical := &monitorTestSession{testSession: &testSession{closed: make(chan struct{})}, monitor: func(context.Context, protocol.Command) protocol.Response {
		response := monitorTestResult()
		response.Monitor.Engine = "mysql"
		return response
	}}
	response := runMonitor(context.Background(), physical, protocol.Command{Type: "monitor.snapshot"}, "postgresql")
	if response.Type != "error" || response.Category != "protocol" || !response.Connected {
		t.Fatal("monitor accepted a snapshot from the wrong engine")
	}
}

func TestMonitorUsesTheManagerTimeout(t *testing.T) {
	manager := newWithTimeout(func(context.Context, protocol.Connection) (adapter.Session, error) {
		return &monitorTestSession{testSession: &testSession{closed: make(chan struct{})}, monitor: func(ctx context.Context, command protocol.Command) protocol.Response {
			<-ctx.Done()
			response := protocol.ErrorResponse(command, "timeout", "Monitor timed out.")
			response.Connected, response.TransactionStatus = true, "idle"
			return response
		}}, nil
	}, 20*time.Millisecond)
	defer manager.Close()
	id := connectMonitorTestSession(t, manager)
	submit(t, manager, protocol.Command{Type: "monitor.snapshot", RequestID: "deadline", SessionID: id, QueryID: "deadline-query"})
	started, terminal := receive(t, manager), receive(t, manager)
	if started.Type != "query.started" || terminal.Type != "error" || terminal.Category != "timeout" {
		t.Fatal("monitor did not use the bounded query lifecycle")
	}
}
