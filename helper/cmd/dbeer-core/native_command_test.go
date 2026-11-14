package main

import (
	"context"
	"encoding/json"
	"io"
	"slices"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

type nativeCommandPipeSession struct{ *pipeTestSession }

func (s *nativeCommandPipeSession) ClassifyNativeCommand(protocol.NativeCommand) string {
	return "read"
}
func (s *nativeCommandPipeSession) Execute(ctx context.Context, c protocol.Command) protocol.Response {
	<-ctx.Done()
	r := protocol.ErrorResponse(c, "cancelled", "Fixture operation cancelled.")
	r.Connected = true
	return r
}
func (s *nativeCommandPipeSession) ExecuteNativeCommand(ctx context.Context, c protocol.Command) protocol.Response {
	return s.Execute(ctx, c)
}

func TestNativeCommandActiveAndRetiredIDsShareSQLRegistry(t *testing.T) {
	for _, pair := range [][2]string{{"command.execute", "execute"}, {"execute", "command.execute"}} {
		t.Run(pair[0]+"/"+pair[1], func(t *testing.T) {
			input, writer := io.Pipe()
			reader, output := io.Pipe()
			defer input.Close()
			defer writer.Close()
			defer reader.Close()
			defer output.Close()
			done := make(chan error, 1)
			go func() {
				done <- runWithFactory(input, output, func(context.Context, protocol.Connection) (adapter.Session, error) {
					return &nativeCommandPipeSession{&pipeTestSession{closed: make(chan struct{})}}, nil
				})
			}()
			responses := make(chan protocol.Response, 8)
			go func() {
				decoder := json.NewDecoder(reader)
				for {
					var r protocol.Response
					if decoder.Decode(&r) != nil {
						return
					}
					responses <- r
				}
			}()
			send := func(c protocol.Command) {
				t.Helper()
				if json.NewEncoder(writer).Encode(c) != nil {
					t.Fatal("cannot send command fixture")
				}
			}
			receive := func() protocol.Response {
				t.Helper()
				select {
				case r := <-responses:
					return r
				case <-time.After(2 * time.Second):
					t.Fatal("command fixture timeout")
					return protocol.Response{}
				}
			}
			send(protocol.Command{Type: "hello", RequestID: "hello", ProtocolVersion: protocol.Version})
			_ = receive()
			send(protocol.Command{Type: "connect", RequestID: "connect", Connection: &protocol.Connection{Host: "fixture.invalid", Port: 5432, Database: "fixture", User: "fixture", SSLMode: "disable"}})
			sid := receive().SessionID
			if sid == "" {
				t.Fatal("fake owner did not connect")
			}
			command := func(kind, id string) protocol.Command {
				c := protocol.Command{Type: kind, RequestID: id, SessionID: sid, QueryID: "shared-operation", SQL: "SELECT 1"}
				if kind == "command.execute" {
					c.SQL = ""
					c.NativeCommand = &protocol.NativeCommand{Name: "READ", Arguments: []protocol.NativeCommandArgument{}}
					c.ResultValues = protocol.NativeResultValuesFormat
				}
				return c
			}
			first := command(pair[0], "first")
			if first.Type == "command.execute" {
				send(protocol.Command{Type: "operation.assess", RequestID: "assess", SessionID: sid, QueryID: "assessment", Operations: []protocol.OperationRequest{{Type: first.Type, QueryID: first.QueryID, NativeCommand: first.NativeCommand}}})
				assessment := receive().Assessment
				if assessment == nil {
					t.Fatal("command assessment missing")
				}
				first.Authorization = assessment.Authorization
			}
			send(first)
			if receive().Type != "query.started" {
				t.Fatal("fake owner did not start")
			}
			send(command(pair[1], "duplicate-active"))
			if r := receive(); r.RequestID != "duplicate-active" || r.Category != "protocol" {
				t.Fatal("active operation ID was reused")
			}
			send(protocol.Command{Type: "cancel", RequestID: "cancel", SessionID: sid, QueryID: first.QueryID})
			for range 2 {
				_ = receive()
			}
			send(command(pair[1], "duplicate-retired"))
			if r := receive(); r.RequestID != "duplicate-retired" || r.Category != "protocol" {
				t.Fatal("retired operation ID was reused")
			}
			send(protocol.Command{Type: "shutdown", RequestID: "shutdown"})
			if receive().Type != "shutdown.ack" {
				t.Fatal("shutdown")
			}
			select {
			case err := <-done:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(2 * time.Second):
				t.Fatal("helper did not exit")
			}
		})
	}
}

func TestNativeCommandIdentifiersCannotBeReused(t *testing.T) {
	for _, pair := range [][2]string{{"command.execute", "command.execute"}, {"command.execute", "execute"}, {"execute", "command.execute"}} {
		t.Run(pair[0]+"/"+pair[1], func(t *testing.T) {
			operation := func(kind, requestID, sessionID string) string {
				payload := `,"nativeCommand":{"name":"READ","arguments":[]},"resultValues":"nativeV1","authorization":"unused"`
				if kind == "execute" {
					payload = `,"sql":"SELECT 1"`
				}
				return `{"type":"` + kind + `","requestId":"` + requestID + `","sessionId":"` + sessionID + `","queryId":"native-operation"` + payload + "}\n"
			}
			input := `{"type":"hello","requestId":"hello","protocolVersion":6}` + "\n" + operation(pair[0], "first", "missing") + operation(pair[1], "second", "different") + `{"type":"shutdown","requestId":"shutdown"}` + "\n"
			responses := runMessages(t, input)
			if len(responses) != 4 || !slices.Contains(responses[0].Capabilities, protocol.NativeCommandsCapability) {
				t.Fatal("command protocol not negotiated")
			}
			for _, response := range responses {
				if response.RequestID == "second" {
					if response.Type != "error" || response.Category != "protocol" || !strings.Contains(response.Message, "already been used") {
						t.Fatal("command/SQL identifier reused across sessions")
					}
					return
				}
			}
			t.Fatal("duplicate identifier was not rejected")
		})
	}
}
