package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"sync"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

type stalledSession struct {
	started, stopped, closed       chan struct{}
	startOnce, stopOnce, closeOnce sync.Once
}

func (physical *stalledSession) TransactionStatus() string { return "idle" }
func (physical *stalledSession) Close()                    { physical.closeOnce.Do(func() { close(physical.closed) }) }
func (physical *stalledSession) Execute(ctx context.Context, command protocol.Command) protocol.Response {
	return physical.ExecuteWithSink(ctx, command, nil)
}
func (physical *stalledSession) ExecuteWithSink(ctx context.Context, command protocol.Command, sink adapter.ResultSink) protocol.Response {
	physical.startOnce.Do(func() { close(physical.started) })
	if sink != nil {
		_ = sink.Begin(0, []protocol.Column{{Index: 0, Name: "value", Engine: "postgresql", NativeType: "text"}})
	}
	<-ctx.Done()
	physical.stopOnce.Do(func() { close(physical.stopped) })
	response := protocol.ErrorResponse(command, "cancelled", "Query was cancelled.")
	response.Connected, response.TransactionStatus = true, "idle"
	return response
}

func TestFullDataQueuesDoNotHideStopShutdownOrEOF(t *testing.T) {
	for _, shutdown := range []bool{false, true} {
		t.Run(fmt.Sprint("shutdown=", shutdown), func(t *testing.T) {
			input, inputWriter := io.Pipe()
			outputReader, output := io.Pipe()
			defer input.Close()
			defer inputWriter.Close()
			defer outputReader.Close()
			defer output.Close()
			var physicals []*stalledSession
			done := make(chan error, 1)
			go func() {
				done <- runWithFactory(input, output, func(context.Context, protocol.Connection) (adapter.Session, error) {
					physical := &stalledSession{started: make(chan struct{}), stopped: make(chan struct{}), closed: make(chan struct{})}
					physicals = append(physicals, physical)
					return physical, nil
				})
			}()
			encoder := json.NewEncoder(inputWriter)
			decoder := json.NewDecoder(outputReader)
			encode := func(command protocol.Command) {
				t.Helper()
				if encoder.Encode(command) != nil {
					t.Fatal("cannot send backpressure fixture command")
				}
			}
			roundtrip := func(command protocol.Command) protocol.Response {
				t.Helper()
				encode(command)
				var response protocol.Response
				if decoder.Decode(&response) != nil || response.RequestID != command.RequestID {
					t.Fatal("backpressure fixture lost its setup reply")
				}
				return response
			}
			roundtrip(protocol.Command{Type: "hello", RequestID: "hello", ProtocolVersion: protocol.Version})
			var sessions []string
			for index := range 16 {
				response := roundtrip(protocol.Command{Type: "connect", RequestID: fmt.Sprint("connect-", index), Connection: &protocol.Connection{Host: "localhost", Port: 5432, Database: "db", User: "user", SSLMode: "disable"}})
				if response.Type != "connect.result" {
					t.Fatal("cannot open fixture session")
				}
				sessions = append(sessions, response.SessionID)
			}
			// Stop reading completely. Sixteen starts plus sixteen metadata chunks
			// exceed every shared output/routing window, and no credit is returned.
			for index, id := range sessions {
				encode(protocol.Command{Type: "execute", RequestID: fmt.Sprint("run-", index), SessionID: id, QueryID: fmt.Sprint("query-", index), SQL: "slow", Stream: true})
			}
			for _, physical := range physicals[:2] {
				select {
				case <-physical.started:
				case <-time.After(time.Second):
					t.Fatal("fixture did not start its first executions")
				}
			}
			encode(protocol.Command{Type: "cancel", RequestID: "stop-first", SessionID: sessions[0], QueryID: "query-0"})
			select {
			case <-physicals[0].stopped:
			case <-time.After(time.Second):
				t.Fatal("full output queues hid Stop behind data")
			}
			select {
			case <-physicals[1].stopped:
				t.Fatal("Stop cancelled another session")
			default:
			}
			if shutdown {
				encode(protocol.Command{Type: "shutdown", RequestID: "shutdown"})
			} else {
				_ = inputWriter.Close()
			}
			for _, physical := range physicals {
				select {
				case <-physical.closed:
				case <-time.After(2 * time.Second):
					t.Fatal("full output queues hid shutdown/EOF cleanup")
				}
			}
			select {
			case err := <-done:
				if err != nil {
					t.Fatal("backpressure cleanup returned an error")
				}
			case <-time.After(2 * time.Second):
				t.Fatal("helper did not exit with a permanently stopped consumer")
			}
		})
	}
}
