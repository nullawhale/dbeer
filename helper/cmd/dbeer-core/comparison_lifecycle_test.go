package main

import (
	"context"
	"encoding/json"
	"io"
	"sync"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/comparisonjob"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/resultcompare"
)

type comparisonPipeSource struct {
	begun, cancelled, closed chan struct{}
	once                     sync.Once
}

func (s *comparisonPipeSource) Metadata() resultcompare.Metadata {
	return resultcompare.Metadata{Columns: []resultcompare.Column{{Index: 0, Name: "value", Engine: "postgresql", NativeType: "text"}}, RowCount: 1, Complete: true}
}
func (s *comparisonPipeSource) Scan(ctx context.Context, _ func(resultcompare.RowRef, []*string) error) error {
	close(s.begun)
	<-ctx.Done()
	close(s.cancelled)
	return ctx.Err()
}
func (s *comparisonPipeSource) ReadRow(context.Context, resultcompare.RowRef) ([]*string, error) {
	panic("blocked comparison never pages")
}
func (s *comparisonPipeSource) Close() error { s.once.Do(func() { close(s.closed) }); return nil }
func pipeComparisonStart() protocol.Command {
	return protocol.Command{Type: "compare.start", RequestID: "start", Comparison: &protocol.ComparisonRequest{Left: &protocol.ArtifactReference{Kind: "snapshot", ID: "11111111-1111-1111-1111-111111111111"}, Right: &protocol.ArtifactReference{Kind: "snapshot", ID: "22222222-2222-2222-2222-222222222222"}, Mode: "rowOrder", Columns: []resultcompare.Mapping{{}}}}
}
func TestComparisonEOFShutdownAndStopDoNotDependOnOutput(t *testing.T) {
	for _, operation := range []string{"EOF", "shutdown", "cancel"} {
		t.Run(operation, func(t *testing.T) {
			left, right := &comparisonPipeSource{begun: make(chan struct{}), cancelled: make(chan struct{}), closed: make(chan struct{})}, &comparisonPipeSource{begun: make(chan struct{}), cancelled: make(chan struct{}), closed: make(chan struct{})}
			var openCount int
			manager, e := comparisonjob.New(func(context.Context, protocol.ArtifactReference) (resultcompare.Source, error) {
				openCount++
				if openCount == 1 {
					return left, nil
				}
				return right, nil
			}, comparisonjob.Options{Root: t.TempDir()})
			if e != nil {
				t.Fatal(e)
			}
			defer manager.Close()
			input, inputWriter := io.Pipe()
			outputReader, output := io.Pipe()
			defer input.Close()
			defer inputWriter.Close()
			defer outputReader.Close()
			defer output.Close()
			done := make(chan error, 1)
			go func() {
				done <- runWithManagers(input, output, func(context.Context, protocol.Connection) (adapter.Session, error) {
					panic("offline comparison opened a database")
				}, nil, nil, manager)
			}()
			encoder := json.NewEncoder(inputWriter)
			if encoder.Encode(protocol.Command{Type: "hello", RequestID: "hello", ProtocolVersion: protocol.Version}) != nil {
				t.Fatal("handshake input failed")
			}
			if encoder.Encode(pipeComparisonStart()) != nil {
				t.Fatal("comparison input failed")
			}
			select {
			case <-left.begun:
			case <-time.After(time.Second):
				t.Fatal("blocked output prevented comparison start")
			}
			select {
			case <-right.begun:
			case <-time.After(time.Second):
				t.Fatal("second source not streaming")
			}
			if operation == "shutdown" {
				if encoder.Encode(protocol.Command{Type: "shutdown", RequestID: "shutdown"}) != nil {
					t.Fatal("shutdown input failed")
				}
			} else if operation == "cancel" {
				// Only the handshake response is read; leave the start response blocked.
				reader := json.NewDecoder(outputReader)
				var hello protocol.Response
				if reader.Decode(&hello) != nil {
					t.Fatal("cannot read hello")
				}
				found := false
				for _, cap := range hello.Capabilities {
					found = found || cap == protocol.ResultComparisonCapability
				}
				if !found {
					t.Fatal("comparison capability missing")
				}
				// The job ID is intentionally only returned through the normal output.
				var started protocol.Response
				if reader.Decode(&started) != nil || started.Comparison == nil {
					t.Fatal("cannot read start response")
				}
				if encoder.Encode(protocol.Command{Type: "compare.cancel", RequestID: "stop", Comparison: &protocol.ComparisonRequest{JobID: started.Comparison.JobID}}) != nil {
					t.Fatal("stop input failed")
				}
			} else {
				_ = inputWriter.Close()
			}
			for _, s := range []*comparisonPipeSource{left, right} {
				select {
				case <-s.cancelled:
				case <-time.After(time.Second):
					t.Fatal("blocked output prevented source cancellation")
				}
				select {
				case <-s.closed:
				case <-time.After(time.Second):
					t.Fatal("blocked output prevented source cleanup")
				}
			}
			if operation == "cancel" {
				_ = inputWriter.Close()
			}
			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatal("comparison transport did not shut down")
			}
		})
	}
}
func TestComparisonRoutingWorksOfflineAndIsBounded(t *testing.T) {
	// The real managed store may be absent; a start still admits asynchronously
	// without connecting or leaking an arbitrary path through the wire.
	input, inputWriter := io.Pipe()
	outputReader, output := io.Pipe()
	defer input.Close()
	defer inputWriter.Close()
	defer output.Close()
	defer outputReader.Close()
	done := make(chan error, 1)
	go func() {
		done <- runWithFactory(input, output, func(context.Context, protocol.Connection) (adapter.Session, error) {
			panic("comparison must remain offline")
		})
	}()
	encoder := json.NewEncoder(inputWriter)
	decoder := json.NewDecoder(outputReader)
	for _, c := range []protocol.Command{{Type: "hello", RequestID: "h", ProtocolVersion: protocol.Version}, pipeComparisonStart()} {
		if encoder.Encode(c) != nil {
			t.Fatal("input failed")
		}
		var response protocol.Response
		if decoder.Decode(&response) != nil {
			t.Fatal("response failed")
		}
		if c.Type == "compare.start" && (response.Type != "compare.start.result" || response.Comparison == nil) {
			t.Fatal("comparison routed into database owner")
		}
	}
	_ = inputWriter.Close()
	select {
	case e := <-done:
		if e != nil {
			t.Fatal(e)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("EOF did not finish")
	}
}
