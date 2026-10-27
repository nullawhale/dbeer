package main

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	"encoding/json"
	"io"
	"sync"
	"testing"
	"time"
)

type schemaPipeSession struct {
	begun, closed chan struct{}
	once          sync.Once
}

func (s *schemaPipeSession) Execute(context.Context, protocol.Command) protocol.Response {
	panic("schema worker executed SQL")
}
func (s *schemaPipeSession) TransactionStatus() string               { return "idle" }
func (s *schemaPipeSession) SetReadOnly(context.Context, bool) error { return nil }
func (s *schemaPipeSession) Close()                                  { s.once.Do(func() { close(s.closed) }) }
func (s *schemaPipeSession) ReadSchema(ctx context.Context, _ sc.CaptureSpec, _ sc.Sink) error {
	close(s.begun)
	<-ctx.Done()
	return ctx.Err()
}
func TestSchemaEOFShutdownAndCancelReleaseOwnersWithBlockedOutput(t *testing.T) {
	for _, operation := range []string{"EOF", "shutdown", "cancel"} {
		t.Run(operation, func(t *testing.T) {
			input, inputWriter := io.Pipe()
			outputReader, output := io.Pipe()
			defer input.Close()
			defer inputWriter.Close()
			defer outputReader.Close()
			defer output.Close()
			sessions := make(chan *schemaPipeSession, 2)
			done := make(chan error, 1)
			go func() {
				done <- runWithFactory(input, output, func(context.Context, protocol.Connection) (adapter.Session, error) {
					s := &schemaPipeSession{begun: make(chan struct{}), closed: make(chan struct{})}
					sessions <- s
					return s, nil
				})
			}()
			encoder := json.NewEncoder(inputWriter)
			if encoder.Encode(protocol.Command{Type: "hello", RequestID: "hello", ProtocolVersion: protocol.Version}) != nil {
				t.Fatal("hello input failed")
			}
			connection := protocol.Connection{Host: "localhost", Port: 5432, Database: "fixture", User: "fixture", SSLMode: "disable"}
			request := protocol.SchemaComparisonRequest{Source: &protocol.SchemaSide{Connection: connection}, Target: &protocol.SchemaSide{Connection: connection}, Mappings: &sc.Mappings{Schemas: []sc.NamePair{{Source: "a", Target: "b"}}, Tables: []sc.TablePair{}, Types: []sc.ObjectPair{}}}
			if encoder.Encode(protocol.Command{Type: "schema.start", RequestID: "start", SchemaComparison: &request}) != nil {
				t.Fatal("schema input failed")
			}
			owners := []*schemaPipeSession{}
			for range 2 {
				select {
				case s := <-sessions:
					owners = append(owners, s)
					select {
					case <-s.begun:
					case <-time.After(time.Second):
						t.Fatal("metadata did not start")
					}
				case <-time.After(time.Second):
					t.Fatal("blocked output prevented open")
				}
			}
			switch operation {
			case "EOF":
				_ = inputWriter.Close()
			case "shutdown":
				if encoder.Encode(protocol.Command{Type: "shutdown", RequestID: "shutdown"}) != nil {
					t.Fatal("shutdown input failed")
				}
			case "cancel":
				decoder := json.NewDecoder(outputReader)
				var hello, started protocol.Response
				if decoder.Decode(&hello) != nil || decoder.Decode(&started) != nil || started.SchemaComparison == nil {
					t.Fatal("schema start response unavailable")
				}
				if encoder.Encode(protocol.Command{Type: "schema.cancel", RequestID: "cancel", SchemaComparison: &protocol.SchemaComparisonRequest{JobID: started.SchemaComparison.JobID}}) != nil {
					t.Fatal("cancel input failed")
				}
			}
			for _, s := range owners {
				select {
				case <-s.closed:
				case <-time.After(time.Second):
					t.Fatal("blocked output prevented session cleanup")
				}
			}
			_ = inputWriter.Close()
			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatal("schema transport did not exit")
			}
		})
	}
}
