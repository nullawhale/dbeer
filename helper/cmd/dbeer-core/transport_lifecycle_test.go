package main

import (
	"context"
	"encoding/json"
	"io"
	"sync"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

type pipeTestSession struct {
	closed chan struct{}
	once   sync.Once
}

func (session *pipeTestSession) Execute(context.Context, protocol.Command) protocol.Response {
	panic("this transport fixture never executes SQL")
}
func (session *pipeTestSession) TransactionStatus() string { return "idle" }
func (session *pipeTestSession) Close()                    { session.once.Do(func() { close(session.closed) }) }

func TestEOFAndShutdownCloseDatabaseWhenOutputConsumerIsBlocked(t *testing.T) {
	for _, shutdown := range []bool{false, true} {
		name := "stdin EOF"
		if shutdown {
			name = "shutdown"
		}
		t.Run(name, func(t *testing.T) {
			input, inputWriter := io.Pipe()
			outputReader, output := io.Pipe()
			defer input.Close()
			defer inputWriter.Close()
			defer output.Close()
			defer outputReader.Close()
			physical := &pipeTestSession{closed: make(chan struct{})}
			opened := make(chan struct{})
			done := make(chan error, 1)
			go func() {
				done <- runWithFactory(input, output, func(context.Context, protocol.Connection) (adapter.Session, error) {
					close(opened)
					return physical, nil
				})
			}()
			encoder := json.NewEncoder(inputWriter)
			for _, command := range []protocol.Command{
				{Type: "hello", RequestID: "hello", ProtocolVersion: protocol.Version},
				{Type: "connect", RequestID: "connect", Connection: &protocol.Connection{Host: "localhost", Port: 5432, Database: "db", User: "user", Password: "", SSLMode: "disable"}},
			} {
				if encoder.Encode(command) != nil {
					t.Fatal("cannot write transport fixture")
				}
			}
			select {
			case <-opened:
			case <-time.After(time.Second):
				t.Fatal("blocked output prevented another input command from connecting")
			}
			if shutdown {
				if encoder.Encode(protocol.Command{Type: "shutdown", RequestID: "shutdown"}) != nil {
					t.Fatal("cannot write shutdown command")
				}
			} else {
				_ = inputWriter.Close()
			}
			select {
			case <-physical.closed:
			case <-time.After(time.Second):
				t.Fatal("blocked output consumer prevented database cleanup")
			}
			if shutdown {
				// A client that still wants an acknowledgement must read stdout.
				// A failed output transport ends this fixture without reading it.
				_ = outputReader.Close()
			}
			select {
			case err := <-done:
				if !shutdown && err != nil {
					t.Fatal("EOF returned an unexpected transport error")
				}
			case <-time.After(2 * time.Second):
				t.Fatal("helper did not exit after its database connections closed")
			}
		})
	}
}
