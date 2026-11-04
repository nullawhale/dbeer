package main

import (
	"context"
	"encoding/json"
	"io"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

type monitorPipeSession struct {
	closed, started, cancelled chan struct{}
	closeOnce                  sync.Once
	calls                      atomic.Int32
	readonly                   atomic.Bool
}

func (physical *monitorPipeSession) TransactionStatus() string { return "idle" }
func (physical *monitorPipeSession) Close()                    { physical.closeOnce.Do(func() { close(physical.closed) }) }
func (physical *monitorPipeSession) SetReadOnly(_ context.Context, value bool) error {
	physical.readonly.Store(value)
	return nil
}
func (physical *monitorPipeSession) Execute(_ context.Context, command protocol.Command) protocol.Response {
	return protocol.ErrorResponse(command, "policy", "User execution must not reach the monitor adapter.")
}
func (physical *monitorPipeSession) MonitorSnapshot(ctx context.Context, command protocol.Command) protocol.Response {
	if physical.calls.Add(1) == 2 {
		close(physical.started)
		<-ctx.Done()
		close(physical.cancelled)
		response := protocol.ErrorResponse(command, "cancelled", "Monitor cancelled.")
		response.Connected, response.TransactionStatus = true, "idle"
		return response
	}
	return protocol.Response{Type: "monitor.result", Connected: true, TransactionStatus: "idle", Monitor: &protocol.SessionMonitorSnapshot{
		Engine: "postgresql", CollectionStartedAt: "2026-01-02T03:04:05Z", CollectedAt: "2026-01-02T03:04:05Z", Sessions: []protocol.MonitoredSession{}, Waits: []protocol.MonitorWait{}, SessionsComplete: true, WaitsComplete: true, Notices: []string{},
	}}
}

func TestSessionMonitorClosedProtocolLifecycleAndQueryIDs(t *testing.T) {
	input, writer := io.Pipe()
	reader, output := io.Pipe()
	defer input.Close()
	defer writer.Close()
	defer reader.Close()
	defer output.Close()
	physical := &monitorPipeSession{closed: make(chan struct{}), started: make(chan struct{}), cancelled: make(chan struct{})}
	done := make(chan error, 1)
	go func() {
		done <- runWithFactory(input, output, func(context.Context, protocol.Connection) (adapter.Session, error) { return physical, nil })
	}()
	responses := make(chan protocol.Response, 8)
	go func() {
		defer close(responses)
		decoder := json.NewDecoder(reader)
		for {
			var response protocol.Response
			if decoder.Decode(&response) != nil {
				return
			}
			responses <- response
		}
	}()
	encoder := json.NewEncoder(writer)
	send := func(value any) {
		t.Helper()
		if encoder.Encode(value) != nil {
			t.Fatal("cannot send monitor protocol fixture")
		}
	}
	receive := func() protocol.Response {
		t.Helper()
		select {
		case response, ok := <-responses:
			if !ok {
				t.Fatal("monitor protocol closed unexpectedly")
			}
			return response
		case <-time.After(2 * time.Second):
			t.Fatal("monitor protocol did not respond")
			return protocol.Response{}
		}
	}
	send(protocol.Command{Type: "hello", RequestID: "hello", ProtocolVersion: protocol.Version})
	if response := receive(); response.Type != "hello.ack" || !slices.Contains(response.Capabilities, protocol.SessionMonitorCapability) {
		t.Fatal("hello did not advertise the optional monitor contract")
	}
	send(protocol.Command{Type: "connect", RequestID: "open-monitor", Connection: &protocol.Connection{Host: "fixture.invalid", Port: 5432, Database: "fixture", User: "fixture", SSLMode: "disable", SessionPurpose: "monitor"}})
	connected := receive()
	if connected.Type != "connect.result" || !physical.readonly.Load() {
		t.Fatal("closed protocol did not create a physical readonly monitor")
	}
	snapshot := protocol.Command{Type: "monitor.snapshot", RequestID: "snapshot", SessionID: connected.SessionID, QueryID: "query-one"}
	send(snapshot)
	started, result := receive(), receive()
	if started.Type != "query.started" || result.Type != "monitor.result" || result.Monitor == nil || !result.Monitor.Valid() ||
		result.SessionID != snapshot.SessionID || result.QueryID != snapshot.QueryID || result.RequestID != snapshot.RequestID {
		t.Fatal("monitor observation did not survive the real main framing/serialization loop")
	}
	snapshot.RequestID = "duplicate-query"
	send(snapshot)
	if response := receive(); response.Type != "error" || response.Category != "protocol" || physical.calls.Load() != 1 {
		t.Fatal("monitor query identifier was reused")
	}
	send(map[string]any{"type": "monitor.snapshot", "requestId": "smuggled", "sessionId": connected.SessionID, "queryId": "smuggled-query", "sql": "SELECT private_fixture"})
	if response := receive(); response.Type != "error" || response.Category != "protocol" || physical.calls.Load() != 1 {
		t.Fatal("monitor command accepted arbitrary SQL")
	}
	snapshot.RequestID, snapshot.QueryID = "cancel-snapshot", "query-two"
	send(snapshot)
	if response := receive(); response.Type != "query.started" {
		t.Fatal("second monitor observation did not start")
	}
	select {
	case <-physical.started:
	case <-time.After(time.Second):
		t.Fatal("monitor adapter did not enter its cancellable collection")
	}
	send(protocol.Command{Type: "cancel", RequestID: "stop", SessionID: connected.SessionID, QueryID: snapshot.QueryID})
	seenAck, seenTerminal := false, false
	for range 2 {
		response := receive()
		if response.Type == "cancel.ack" && response.RequestID == "stop" && response.Status == "accepted" {
			seenAck = true
		} else if response.Type == "error" && response.RequestID == snapshot.RequestID && response.Category == "cancelled" && response.QueryID == snapshot.QueryID {
			seenTerminal = true
		} else {
			t.Fatal("monitor Stop produced an unrelated response")
		}
	}
	if !seenAck || !seenTerminal {
		t.Fatal("monitor Stop lost an acknowledgement or terminal response")
	}
	send(protocol.Command{Type: "shutdown", RequestID: "shutdown"})
	if response := receive(); response.Type != "shutdown.ack" {
		t.Fatal("monitor shutdown acknowledgement missing")
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal("monitor main loop failed to shut down")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("monitor main loop did not finish shutdown")
	}
	select {
	case <-physical.closed:
	default:
		t.Fatal("monitor shutdown leaked its physical connection")
	}
}
