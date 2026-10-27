package mcpbridge

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

func testContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	t.Cleanup(cancel)
	return ctx
}

func TestBridgeCorrelatesConcurrentReplies(t *testing.T) {
	client, native := net.Pipe()
	b := newBridge(client)
	t.Cleanup(b.close)
	t.Cleanup(func() { _ = native.Close() })
	go func() {
		decoder := json.NewDecoder(native)
		var first, second request
		if decoder.Decode(&first) != nil || decoder.Decode(&second) != nil {
			return
		}
		encoder := json.NewEncoder(native)
		_ = encoder.Encode(response{ID: second.ID, OK: true, QueryID: second.QueryID})
		_ = encoder.Encode(response{ID: first.ID, OK: true, QueryID: first.QueryID})
	}()
	ctx := testContext(t)
	var workers sync.WaitGroup
	for _, id := range []string{"first", "second"} {
		workers.Go(func() {
			reply, err := b.call(ctx, request{Method: "query", QueryID: id})
			if err != nil || reply.QueryID != id {
				t.Errorf("wrong correlation: %q, %v", reply.QueryID, err)
			}
		})
	}
	workers.Wait()
}

func TestBridgeCancellationUsesIndependentControlRequest(t *testing.T) {
	client, native := net.Pipe()
	b := newBridge(client)
	t.Cleanup(b.close)
	t.Cleanup(func() { _ = native.Close() })
	started := make(chan struct{})
	cancelled := make(chan request, 1)
	go func() {
		decoder := json.NewDecoder(native)
		var query, cancel request
		if decoder.Decode(&query) != nil {
			return
		}
		close(started)
		if decoder.Decode(&cancel) != nil {
			return
		}
		cancelled <- cancel
		_ = json.NewEncoder(native).Encode(response{ID: cancel.ID, OK: true, QueryID: cancel.QueryID})
	}()
	ctx, cancel := context.WithCancel(testContext(t))
	done := make(chan error, 1)
	go func() { _, err := b.call(ctx, request{Method: "query", QueryID: "owned-query"}); done <- err }()
	select {
	case <-started:
	case <-ctx.Done():
		t.Fatal("query not sent")
	}
	cancel()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("cancel succeeded as SQL completion")
		}
	case <-time.After(time.Second):
		t.Fatal("cancel call blocked")
	}
	select {
	case command := <-cancelled:
		if command.Method != "cancel" || command.QueryID != "owned-query" {
			t.Fatal("wrong cancellation target")
		}
	case <-time.After(time.Second):
		t.Fatal("no independent cancellation command")
	}
}

func TestBridgeRejectsOversizedRepliesAndRequests(t *testing.T) {
	for _, oversizedReply := range []bool{false, true} {
		t.Run(map[bool]string{false: "request", true: "reply"}[oversizedReply], func(t *testing.T) {
			client, native := net.Pipe()
			b := newBridge(client)
			t.Cleanup(b.close)
			t.Cleanup(func() { _ = native.Close() })
			if !oversizedReply {
				_, err := b.call(testContext(t), request{Method: "query", SQL: strings.Repeat("x", MaxRequestBytes)})
				if err == nil {
					t.Fatal("oversized request accepted")
				}
				return
			}
			go func() {
				_, _ = bufio.NewReader(native).ReadBytes('\n')
				_, _ = native.Write([]byte(strings.Repeat("x", MaxResponseBytes+2)))
			}()
			_, err := b.call(testContext(t), request{Method: "connections"})
			if !errors.Is(err, errTransport) {
				t.Fatalf("unsafe transport result: %v", err)
			}
		})
	}
}

func TestBridgeReservesAdmissionForCancellation(t *testing.T) {
	client, native := net.Pipe()
	b := &bridge{conn: client, pending: make(map[string]chan response), closed: make(chan struct{}), ordinary: make(chan outgoing, 24), controls: make(chan outgoing, 8)}
	t.Cleanup(b.close)
	t.Cleanup(func() { _ = native.Close() })
	ctx, cancel := context.WithCancel(testContext(t))
	defer cancel()
	for range 24 {
		go func() { _, _ = b.call(ctx, request{Method: "query"}) }()
	}
	deadline := time.After(time.Second)
	for len(b.ordinary) != 24 {
		select {
		case <-deadline:
			t.Fatal("ordinary admission did not fill")
		default:
			time.Sleep(time.Millisecond)
		}
	}
	if _, err := b.call(ctx, request{Method: "query"}); !errors.Is(err, errBusy) {
		t.Fatal("ordinary work consumed reserved control admission")
	}
	go func() { _, _ = b.call(ctx, request{Method: "cancel", QueryID: "owned"}) }()
	select {
	case command := <-b.controls:
		var parsed request
		if json.Unmarshal(command.data, &parsed) != nil || parsed.Method != "cancel" {
			t.Fatal("invalid control command")
		}
	case <-time.After(time.Second):
		t.Fatal("cancellation blocked by ordinary queue")
	}
}

func TestCancelledQueuedCallNeverSendsSQLLater(t *testing.T) {
	for _, method := range []string{"query", "catalog"} {
		t.Run(method, func(t *testing.T) {
			client, native := net.Pipe()
			// Hold transport output until cancellation has retired queued work.
			// This makes the queue state deterministic without scheduler timing.
			b := &bridge{conn: client, pending: make(map[string]chan response), closed: make(chan struct{}), ordinary: make(chan outgoing, 16), controls: make(chan outgoing, 8)}
			t.Cleanup(b.close)
			t.Cleanup(func() { _ = native.Close() })
			ctx, cancel := context.WithCancel(testContext(t))
			done := make(chan error, 1)
			go func() {
				_, err := b.call(ctx, request{Method: method, QueryID: "retired-query", SQL: "must not reach the app"})
				done <- err
			}()
			var queued outgoing
			select {
			case queued = <-b.ordinary:
			case <-ctx.Done():
				t.Fatal("operation did not queue")
			}
			b.ordinary <- queued
			cancel()
			select {
			case err := <-done:
				if err == nil {
					t.Fatal("cancelled work returned success")
				}
			case <-time.After(time.Second):
				t.Fatal("queued cancellation blocked")
			}
			b.mu.Lock()
			_, stillPending := b.pending[queued.id]
			b.mu.Unlock()
			if stillPending {
				t.Fatal("cancelled request remains eligible for transmission")
			}
			var control outgoing
			select {
			case control = <-b.controls:
			case <-time.After(time.Second):
				t.Fatal("cancellation was not queued")
			}
			b.controls <- control
			nativeDone := make(chan error, 1)
			go func() {
				decoder, encoder := json.NewDecoder(native), json.NewEncoder(native)
				for _, expected := range []string{"cancel", "connections"} {
					var command request
					if err := decoder.Decode(&command); err != nil {
						nativeDone <- err
						return
					}
					if command.Method != expected || command.SQL != "" {
						nativeDone <- errors.New("cancelled work reached the app after its cancellation")
						return
					}
					if err := encoder.Encode(response{ID: command.ID, OK: true}); err != nil {
						nativeDone <- err
						return
					}
				}
				nativeDone <- nil
			}()
			go b.read()
			go b.write()
			if _, err := b.call(testContext(t), request{Method: "connections"}); err != nil {
				t.Fatal(err)
			}
			if err := <-nativeDone; err != nil {
				t.Fatal(err)
			}
		})
	}
}
