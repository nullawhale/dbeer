package main

import (
	"context"
	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	tc "dbeer/helper/internal/tablecapture"
	"encoding/json"
	"io"
	"sync"
	"testing"
	"time"
)

type dataPipeSession struct {
	begun, closed chan struct{}
	once          sync.Once
}

func (s *dataPipeSession) Execute(context.Context, protocol.Command) protocol.Response {
	panic("data capture executed user SQL")
}
func (s *dataPipeSession) TransactionStatus() string               { return "idle" }
func (s *dataPipeSession) SetReadOnly(context.Context, bool) error { return nil }
func (s *dataPipeSession) Close()                                  { s.once.Do(func() { close(s.closed) }) }
func dataPipeDescriptor(table tc.Table) tc.Descriptor {
	d := tc.Descriptor{Engine: "postgresql", Table: table, Columns: []tc.Column{{Index: 0, Name: "id", NativeType: "int8", TypeLabel: "int8", Definition: json.RawMessage(`{}`)}}, Definition: json.RawMessage(`{}`)}
	_ = d.Seal()
	return d
}
func (s *dataPipeSession) DescribeTable(_ context.Context, table tc.Table) (tc.Descriptor, error) {
	return dataPipeDescriptor(table), nil
}
func (s *dataPipeSession) CaptureTable(ctx context.Context, spec tc.Spec, _ tc.Sink) (tc.Descriptor, tc.Outcome, error) {
	close(s.begun)
	<-ctx.Done()
	return dataPipeDescriptor(spec.Table), tc.Outcome{}, ctx.Err()
}
func TestDataEOFShutdownAndCancelDoNotDependOnStdout(t *testing.T) {
	for _, operation := range []string{"EOF", "shutdown", "cancel"} {
		t.Run(operation, func(t *testing.T) {
			input, inputWriter := io.Pipe()
			outputReader, output := io.Pipe()
			defer input.Close()
			defer inputWriter.Close()
			defer outputReader.Close()
			defer output.Close()
			sessions := make(chan *dataPipeSession, 2)
			done := make(chan error, 1)
			go func() {
				done <- runWithFactory(input, output, func(context.Context, protocol.Connection) (adapter.Session, error) {
					s := &dataPipeSession{begun: make(chan struct{}), closed: make(chan struct{})}
					sessions <- s
					return s, nil
				})
			}()
			encoder := json.NewEncoder(inputWriter)
			if encoder.Encode(protocol.Command{Type: "hello", RequestID: "hello", ProtocolVersion: protocol.Version}) != nil {
				t.Fatal("hello failed")
			}
			table := tc.Table{Schema: "public", Name: "fixture"}
			filters := []tc.Filter{}
			side := protocol.DataReadSide{Connection: protocol.Connection{Host: "localhost", Port: 5432, Database: "fixture", User: "fixture", SSLMode: "disable"}, Table: table, DescriptorDigest: dataPipeDescriptor(table).Digest, Filters: &filters, ReadLimit: 10000}
			request := protocol.DataComparisonRequest{Source: &side, Target: &side, Columns: []tc.Mapping{{Source: "id", Target: "id", Key: true}}, Originals: "allColumns"}
			if encoder.Encode(protocol.Command{Type: "data.start", RequestID: "start", DataComparison: &request}) != nil {
				t.Fatal("start failed")
			}
			owners := []*dataPipeSession{}
			for range 2 {
				select {
				case s := <-sessions:
					owners = append(owners, s)
					select {
					case <-s.begun:
					case <-time.After(time.Second):
						t.Fatal("capture did not start")
					}
				case <-time.After(time.Second):
					t.Fatal("output blocked capture admission")
				}
			}
			switch operation {
			case "EOF":
				_ = inputWriter.Close()
			case "shutdown":
				if encoder.Encode(protocol.Command{Type: "shutdown", RequestID: "shutdown"}) != nil {
					t.Fatal("shutdown failed")
				}
			case "cancel":
				decoder := json.NewDecoder(outputReader)
				var hello, start protocol.Response
				if decoder.Decode(&hello) != nil || decoder.Decode(&start) != nil || start.DataComparison == nil {
					t.Fatal("start response unavailable")
				}
				if encoder.Encode(protocol.Command{Type: "data.cancel", RequestID: "cancel", DataComparison: &protocol.DataComparisonRequest{JobID: start.DataComparison.JobID}}) != nil {
					t.Fatal("cancel failed")
				}
			}
			for _, s := range owners {
				select {
				case <-s.closed:
				case <-time.After(time.Second):
					t.Fatal("stdout blocked owner cleanup")
				}
			}
			_ = inputWriter.Close()
			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatal("data transport did not finish")
			}
		})
	}
}
