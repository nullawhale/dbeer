package main

import (
	"context"
	"encoding/json"
	"io"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/sshtunnel"
)

type delayedCloseSession struct {
	*pipeTestSession
	delay     time.Duration
	closeOnce sync.Once
}

func (physical *delayedCloseSession) Close() {
	physical.closeOnce.Do(func() { time.Sleep(physical.delay); physical.pipeTestSession.Close() })
}

func TestSSHCapableShutdownSeparatesCleanupAndStalledWriterDeadlines(t *testing.T) {
	for _, stalled := range []bool{false, true} {
		name := "graceful-cleanup"
		if stalled {
			name = "stalled-writer"
		}
		t.Run(name, func(t *testing.T) {
			tunnels, err := sshtunnel.NewManagerWithOptions(sshtunnel.Options{KnownHostsPath: filepath.Join(t.TempDir(), "known_hosts")})
			if err != nil {
				t.Fatal(err)
			}
			defer tunnels.Close()
			physical := &delayedCloseSession{pipeTestSession: &pipeTestSession{closed: make(chan struct{})}}
			if !stalled {
				physical.delay = 1250 * time.Millisecond
			}
			input, inputWriter := io.Pipe()
			outputReader, output := io.Pipe()
			defer input.Close()
			defer inputWriter.Close()
			defer outputReader.Close()
			defer output.Close()
			done := make(chan error, 1)
			go func() {
				done <- runWithSSH(input, output, func(context.Context, protocol.Connection) (adapter.Session, error) { return physical, nil }, nil, tunnels)
			}()
			encoder, decoder := json.NewEncoder(inputWriter), json.NewDecoder(outputReader)
			send := func(command protocol.Command) {
				t.Helper()
				if encoder.Encode(command) != nil {
					t.Fatal("cannot send shutdown fixture command")
				}
			}
			roundtrip := func(command protocol.Command) protocol.Response {
				t.Helper()
				send(command)
				var response protocol.Response
				if decoder.Decode(&response) != nil {
					t.Fatal("cannot read shutdown fixture response")
				}
				return response
			}
			hello := roundtrip(protocol.Command{Type: "hello", RequestID: "hello", ProtocolVersion: protocol.Version})
			if len(hello.Capabilities) < 2 {
				t.Fatal("fixture did not enable SSH shutdown bounds")
			}
			roundtrip(protocol.Command{Type: "connect", RequestID: "connect", Connection: &protocol.Connection{Host: "localhost", Port: 5432, Database: "test", User: "test", SSLMode: "disable"}})
			if stalled {
				send(protocol.Command{Type: "disconnect", RequestID: "unread", SessionID: "absent"})
			}
			send(protocol.Command{Type: "shutdown", RequestID: "shutdown"})
			if !stalled {
				var response protocol.Response
				if decoder.Decode(&response) != nil || response.Type != "shutdown.ack" {
					t.Fatal("bounded SSH cleanup lost graceful shutdown acknowledgement")
				}
			}
			select {
			case err := <-done:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(2 * time.Second):
				t.Fatal("stalled output used the longer SSH cleanup deadline")
			}
			select {
			case <-physical.closed:
			default:
				t.Fatal("shutdown left the physical session open")
			}
		})
	}
}
