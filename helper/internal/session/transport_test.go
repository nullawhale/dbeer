package session

import (
	"context"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

type tunnelTestSession struct {
	*testSession
	failed chan struct{}
}

func (session *tunnelTestSession) TransportDone() <-chan struct{} { return session.failed }

func TestTunnelLossInvalidatesIdleAndActiveSessionsWithoutReplay(t *testing.T) {
	failed := make(chan struct{})
	idle := &tunnelTestSession{testSession: blockingSession(), failed: failed}
	active := &tunnelTestSession{testSession: blockingSession(), failed: failed}
	dispatched := make(chan struct{})
	active.run = func(ctx context.Context, command protocol.Command) protocol.Response {
		close(dispatched)
		<-ctx.Done()
		response := protocol.ErrorResponse(command, "connection", "The command outcome is unknown.")
		response.OutcomeUnknown = true
		return response
	}
	other := blockingSession()
	sessions := []adapter.Session{idle, active, other}
	manager := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
		next := sessions[0]
		sessions = sessions[1:]
		return next, nil
	})
	defer manager.Close()
	openTestSession(t, manager, "idle")
	activeID := openTestSession(t, manager, "active")
	otherID := openTestSession(t, manager, "other")
	query := startTestQuery(t, manager, activeID, "write", "INSERT INTO test VALUES (1)")
	<-dispatched
	close(failed)
	response := receive(t, manager)
	if response.RequestID != query.RequestID || !response.OutcomeUnknown || response.Connected {
		t.Fatal("transport loss changed unknown outcome")
	}
	for _, closed := range []<-chan struct{}{idle.closed, active.closed} {
		select {
		case <-closed:
		case <-time.After(time.Second):
			t.Fatal("failed generation retained a session")
		}
	}
	startTestQuery(t, manager, otherID, "unaffected", "SELECT 'fast'")
	if response := receive(t, manager); response.Type != "query.result" {
		t.Fatal("transport loss affected another profile")
	}
}
