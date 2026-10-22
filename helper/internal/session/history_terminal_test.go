package session

import (
	"context"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

func TestUnknownSessionExecutionWasNotSent(t *testing.T) {
	manager := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
		t.Fatal("missing session unexpectedly opened an adapter")
		return nil, nil
	})
	defer manager.Close()
	submit(t, manager, protocol.Command{Type: "execute", RequestID: "missing", SessionID: "missing", QueryID: "missing", SQL: "SELECT 1"})
	if response := receive(t, manager); response.Type != "error" || !response.SQLNotExecuted || response.OutcomeUnknown {
		t.Fatal("missing session was recorded as an executed or uncertain SQL command")
	}
}

func TestQueuedCancellationWasNotSent(t *testing.T) {
	physical := blockingSession()
	physical.run = func(context.Context, protocol.Command) protocol.Response {
		t.Error("cancelled queued command reached the adapter")
		return protocol.Response{}
	}
	manager := New(func(context.Context, protocol.Connection) (adapter.Session, error) { return physical, nil })
	defer manager.Close()
	id := openTestSession(t, manager, "connect")
	query := protocol.Command{Type: "execute", RequestID: "queued", SessionID: id, QueryID: "queued", SQL: "SELECT 1"}
	// Control may arrive after the input reader registered a query but before
	// the routing goroutine receives it. Preserve that exact order here.
	manager.markPending(query)
	ack := manager.Control(protocol.Command{Type: "cancel", RequestID: "cancel", SessionID: id, QueryID: query.QueryID})
	if ack == nil || ack.Status != "accepted" {
		t.Fatal("queued cancellation was not accepted")
	}
	manager.Commands() <- query
	if response := receive(t, manager); response.Category != "cancelled" || !response.SQLNotExecuted || response.OutcomeUnknown {
		t.Fatal("queued cancellation was confused with executed SQL")
	}
}

func TestClosingQueueRejectsUnsentExecutions(t *testing.T) {
	manager := &Manager{pendingQueries: make(map[string]pendingQuery)}
	owner := &owner{manager: manager, commands: make(chan protocol.Command, 1)}
	query := protocol.Command{Type: "execute", RequestID: "queued", SessionID: "closing", QueryID: "queued", SQL: "SELECT 1"}
	manager.markPending(query)
	owner.commands <- query
	rejected := owner.closeRouting()
	if len(rejected) != 1 || !rejected[0].SQLNotExecuted || rejected[0].OutcomeUnknown || len(manager.pendingQueries) != 0 {
		t.Fatal("closing session lost proof that its queued SQL was never sent")
	}
}

func TestExecutionContextEndingBeforeAdapterWasNotSent(t *testing.T) {
	physical := blockingSession()
	physical.run = func(context.Context, protocol.Command) protocol.Response {
		t.Error("expired command reached the adapter")
		return protocol.Response{}
	}
	for _, timeout := range []bool{false, true} {
		ctx, cancel := context.WithCancel(context.Background())
		category := "cancelled"
		if timeout {
			cancel()
			ctx, cancel = context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
			category = "timeout"
		}
		cancel()
		response := runExecution(ctx, physical, protocol.Command{Type: "execute", RequestID: "expired", SQL: "SELECT 1"}, nil)
		if response.Category != category || !response.SQLNotExecuted || response.OutcomeUnknown {
			t.Fatal("command expired before the adapter was incorrectly counted as executed")
		}
	}
}
