package session

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

type testSession struct {
	closed chan struct{}
	once   sync.Once
	run    func(context.Context, protocol.Command) protocol.Response
}

func (session *testSession) Close()                    { session.once.Do(func() { close(session.closed) }) }
func (session *testSession) TransactionStatus() string { return "idle" }
func (session *testSession) Execute(ctx context.Context, command protocol.Command) protocol.Response {
	return session.run(ctx, command)
}

func fakeResult(command protocol.Command) protocol.Response {
	return protocol.Response{Type: "query.result", RequestID: command.RequestID, SessionID: command.SessionID, QueryID: command.QueryID, TransactionStatus: "idle", CommandTag: "SELECT 1", RowCount: 1}
}

func blockingSession() *testSession {
	return &testSession{closed: make(chan struct{}), run: func(ctx context.Context, command protocol.Command) protocol.Response {
		if command.SQL == "SELECT 'fast'" {
			return fakeResult(command)
		}
		<-ctx.Done()
		response := protocol.ErrorResponse(command, "cancelled", "Query was cancelled.")
		response.Connected, response.TransactionStatus = true, "idle"
		return response
	}}
}

func receive(t *testing.T, manager *Manager) protocol.Response {
	t.Helper()
	select {
	case response, ok := <-manager.Responses():
		if !ok {
			t.Fatal("session manager closed unexpectedly")
		}
		return response
	case <-time.After(2 * time.Second):
		t.Fatal("session manager did not respond promptly")
		return protocol.Response{}
	}
}

func submit(t *testing.T, manager *Manager, command protocol.Command) {
	t.Helper()
	if !manager.Submit(command) {
		t.Fatal("manager stopped before accepting command")
	}
}

func openTestSession(t *testing.T, manager *Manager, id string) string {
	t.Helper()
	submit(t, manager, protocol.Command{Type: "connect", RequestID: id, Connection: &protocol.Connection{Database: id}})
	response := receive(t, manager)
	if response.Type != "connect.result" || response.Engine != "postgresql" || len(response.Capabilities) == 0 || !protocol.ValidID(response.SessionID) {
		t.Fatal("session did not connect with engine capabilities")
	}
	return response.SessionID
}

func startTestQuery(t *testing.T, manager *Manager, session, id, sql string) protocol.Command {
	t.Helper()
	command := protocol.Command{Type: "execute", RequestID: id, SessionID: session, QueryID: "query-" + id, SQL: sql}
	submit(t, manager, command)
	response := receive(t, manager)
	if response.Type != "query.started" || response.RequestID != id || response.SessionID != session || response.QueryID != command.QueryID {
		t.Fatal("query start lost correlation")
	}
	return command
}

func TestConcurrentSessionsConnectExecuteAndStopIndependently(t *testing.T) {
	manager := New(func(context.Context, protocol.Connection) (adapter.Session, error) { return blockingSession(), nil })
	defer manager.Close()
	a := openTestSession(t, manager, "a")
	qa := startTestQuery(t, manager, a, "slow-a", "SELECT 'slow'")
	b := openTestSession(t, manager, "b") // Connecting must not wait for a's SQL.
	qb := startTestQuery(t, manager, b, "fast-b", "SELECT 'fast'")
	if response := receive(t, manager); response.Type != "query.result" || response.RequestID != qb.RequestID {
		t.Fatal("one slow session blocked another session")
	}
	qb = startTestQuery(t, manager, b, "slow-b", "SELECT 'slow'")
	submit(t, manager, protocol.Command{Type: "cancel", RequestID: "wrong-stop", SessionID: a, QueryID: qb.QueryID})
	if response := receive(t, manager); response.Type != "cancel.ack" || response.Status != "alreadyFinished" {
		t.Fatal("cancellation did not require the matching session and query")
	}
	submit(t, manager, protocol.Command{Type: "cancel", RequestID: "stop-a", SessionID: a, QueryID: qa.QueryID})
	seen := make(map[string]bool)
	for range 2 {
		response := receive(t, manager)
		if seen[response.RequestID] {
			t.Fatal("execution produced duplicate terminal responses")
		}
		seen[response.RequestID] = true
		if response.RequestID == qa.RequestID {
			if response.Type != "error" || response.Category != "cancelled" || response.SessionID != a || response.QueryID != qa.QueryID {
				t.Fatal("Stop did not terminate exactly its selected execution")
			}
		} else if response.RequestID != "stop-a" || response.Status != "accepted" {
			t.Fatal("Stop affected another session")
		}
	}
	// A late Stop must not cancel a's next command.
	submit(t, manager, protocol.Command{Type: "cancel", RequestID: "late-stop", SessionID: a, QueryID: qa.QueryID})
	if response := receive(t, manager); response.Status != "alreadyFinished" {
		t.Fatal("late Stop was accepted")
	}
	startTestQuery(t, manager, a, "after-stop", "SELECT 'fast'")
	if response := receive(t, manager); response.Type != "query.result" {
		t.Fatal("session was not reusable after Stop")
	}
	submit(t, manager, protocol.Command{Type: "disconnect", RequestID: "close-b", SessionID: b})
	terminal := receive(t, manager)
	ack := receive(t, manager)
	if terminal.RequestID != qb.RequestID || terminal.Type != "error" || ack.Type != "disconnect.ack" || ack.SessionID != b {
		t.Fatal("disconnect did not cancel its query before closing its session")
	}
	startTestQuery(t, manager, a, "after-other-close", "SELECT 'fast'")
	if response := receive(t, manager); response.Type != "query.result" {
		t.Fatal("disconnect affected another session")
	}
}

func TestCancellationKeepsSessionBusyUntilRecoveryFinishes(t *testing.T) {
	recover := make(chan struct{})
	started := make(chan struct{})
	var recoverOnce sync.Once
	release := func() { recoverOnce.Do(func() { close(recover) }) }
	var executions atomic.Int32
	manager := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
		physical := blockingSession()
		physical.run = func(ctx context.Context, command protocol.Command) protocol.Response {
			if executions.Add(1) == 1 {
				close(started)
				<-ctx.Done()
				<-recover
				response := protocol.ErrorResponse(command, "cancelled", "Query was cancelled.")
				response.Connected, response.TransactionStatus = true, "idle"
				return response
			}
			return fakeResult(command)
		}
		return physical, nil
	})
	defer manager.Close()
	defer release()
	id := openTestSession(t, manager, "a")
	query := startTestQuery(t, manager, id, "recovering", "SELECT 'slow'")
	<-started
	submit(t, manager, protocol.Command{Type: "cancel", RequestID: "stop", SessionID: id, QueryID: query.QueryID})
	if receive(t, manager).Status != "accepted" {
		t.Fatal("Stop was not accepted")
	}
	submit(t, manager, protocol.Command{Type: "execute", RequestID: "too-early", SessionID: id, QueryID: "too-early", SQL: "SELECT 'fast'"})
	if response := receive(t, manager); response.Category != "busy" || executions.Load() != 1 {
		t.Fatal("another query ran before transaction recovery completed")
	}
	release()
	if response := receive(t, manager); response.RequestID != query.RequestID || response.Category != "cancelled" {
		t.Fatal("recovering query did not finish")
	}
	startTestQuery(t, manager, id, "after-recovery", "SELECT 'fast'")
	if receive(t, manager).Type != "query.result" {
		t.Fatal("recovered session was not reusable")
	}
}

func TestCloseAndShutdownReleaseSessionsWithBlockedConsumer(t *testing.T) {
	for _, graceful := range []bool{false, true} {
		t.Run(fmt.Sprint("graceful=", graceful), func(t *testing.T) {
			var physicals []*testSession
			manager := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
				physical := blockingSession()
				physicals = append(physicals, physical) // open/receive synchronizes this test's access.
				return physical, nil
			})
			defer manager.Close()
			for index := range 16 {
				id := openTestSession(t, manager, fmt.Sprint("session-", index))
				startTestQuery(t, manager, id, fmt.Sprint("slow-", index), "SELECT 'slow'")
			}
			if graceful {
				submit(t, manager, protocol.Command{Type: "shutdown", RequestID: "shutdown"})
			} else {
				manager.Close()
			}
			// Do not consume a single cancellation response. Every physical
			// connection must close even after the shared output queue fills.
			for _, physical := range physicals {
				select {
				case <-physical.closed:
				case <-time.After(2 * time.Second):
					t.Fatal("blocked consumer prevented a physical session from closing")
				}
			}
		})
	}
}

func TestConnectionFailureIsSafeAndDoesNotBlockOtherSessions(t *testing.T) {
	blocked := make(chan struct{})
	manager := New(func(ctx context.Context, connection protocol.Connection) (adapter.Session, error) {
		if connection.Database == "blocked" {
			close(blocked)
			<-ctx.Done()
			return nil, ctx.Err()
		}
		if connection.Database == "error" {
			return nil, errors.New("driver accidentally includes secret-password")
		}
		return blockingSession(), nil
	})
	defer manager.Close()
	submit(t, manager, protocol.Command{Type: "connect", RequestID: "blocked", Connection: &protocol.Connection{Database: "blocked"}})
	<-blocked
	openTestSession(t, manager, "works")
	submit(t, manager, protocol.Command{Type: "connect", RequestID: "error", Connection: &protocol.Connection{Database: "error"}})
	response := receive(t, manager)
	if response.Type != "error" || response.Message != "Cannot connect to the database. Check the address, TLS settings, and server availability." {
		t.Fatal("connection leaked a raw driver diagnostic")
	}
}
