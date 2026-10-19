// dbeer-core is bundled with DBeer and communicates exclusively over its pipes.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/mysql"
	"dbeer/helper/internal/postgres"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/session"
)

type writeResult struct {
	response protocol.Response
	err      error
}
type inputEnd struct {
	err      error
	shutdown bool
}

func openDatabase(ctx context.Context, connection protocol.Connection) (adapter.Session, error) {
	switch connection.DatabaseEngine() {
	case "postgresql":
		return postgres.Open(ctx, connection)
	case "mysql":
		return mysql.Open(ctx, connection)
	default:
		return nil, &adapter.ConnectionError{Category: "connection", Message: "Database engine is unavailable."}
	}
}

func run(input io.Reader, output io.Writer) error {
	postgres.PrepareEnvironment()
	return runWithFactory(input, output, openDatabase)
}

// The input reader owns protocol guards and never waits for result output.
// Ordinary admission is bounded; overflow is a transport failure, rather than
// indefinitely hiding Stop/EOF behind an unresponsive output consumer.
func readCommands(input io.Reader, manager *session.Manager, local chan<- protocol.Response, ended chan<- inputEnd, stop <-chan struct{}) {
	reader := protocol.NewReader(input)
	requests, queries := make(map[string]bool), make(map[string]string)
	handshaken := false
	finish := func(err error, shutdown bool) {
		if !shutdown {
			manager.Close()
		}
		select {
		case ended <- inputEnd{err: err, shutdown: shutdown}:
		case <-stop:
		}
	}
	emit := func(response protocol.Response) bool {
		select {
		case local <- response:
			return true
		case <-stop:
			return false
		default:
			finish(errors.New("Protocol control queue exceeded its bounded capacity."), false)
			return false
		}
	}
	for {
		command, err := reader.Read()
		if err != nil {
			if errors.Is(err, io.EOF) {
				finish(nil, false)
				return
			}
			var invalid *protocol.ProtocolError
			if !errors.As(err, &invalid) {
				finish(err, false)
				return
			}
			if invalid.RequestID != "" {
				requests[invalid.RequestID] = true
			}
			if !emit(protocol.Response{Type: "error", RequestID: invalid.RequestID, SessionID: invalid.SessionID, QueryID: invalid.QueryID, Category: "protocol", Message: invalid.Message}) {
				return
			}
			continue
		}
		if requests[command.RequestID] {
			if !emit(protocol.ErrorResponse(command, "protocol", "Request identifier has already been used.")) {
				return
			}
			continue
		}
		requests[command.RequestID] = true
		if command.Type == "shutdown" {
			manager.Control(command)
			if !manager.TrySubmit(command) {
				finish(errors.New("Protocol command queue exceeded its bounded capacity."), false)
				return
			}
			finish(nil, true)
			return
		}
		if command.Type == "hello" {
			var response protocol.Response
			if command.ProtocolVersion != protocol.Version {
				response = protocol.ErrorResponse(command, "protocol", "Incompatible protocol version; version 2 is required.")
			} else if handshaken {
				response = protocol.ErrorResponse(command, "protocol", "Protocol handshake has already completed.")
			} else {
				handshaken = true
				response = protocol.Response{Type: "hello.ack", RequestID: command.RequestID, ProtocolVersion: protocol.Version}
			}
			if !emit(response) {
				return
			}
			continue
		}
		if !handshaken {
			if !emit(protocol.ErrorResponse(command, "protocol", "A successful hello handshake is required.")) {
				return
			}
			continue
		}
		if command.Type == "execute" || command.Type == "catalog" || command.Type == "changes.preview" || command.Type == "changes.apply" {
			if queries[command.QueryID] != "" {
				if !emit(protocol.ErrorResponse(command, "protocol", "Query identifier has already been used.")) {
					return
				}
				continue
			}
			queries[command.QueryID] = command.SessionID
		}
		if command.Type == "stream.ack" && queries[command.QueryID] != command.SessionID {
			if !emit(protocol.ErrorResponse(command, "protocol", "Stream credit does not match an admitted execution.")) {
				return
			}
			continue
		}
		if command.Type == "cancel" || command.Type == "disconnect" || command.Type == "stream.ack" {
			if response := manager.Control(command); response != nil {
				if !emit(*response) {
					return
				}
			}
			continue
		}
		if !manager.TrySubmit(command) {
			finish(errors.New("Protocol command queue exceeded its bounded capacity."), false)
			return
		}
	}
}

func runWithFactory(input io.Reader, output io.Writer, opener adapter.OpenFunc) error {
	manager := session.New(opener)
	defer manager.Close()
	local := make(chan protocol.Response, 256)
	ended := make(chan inputEnd, 1)
	writeRequests := make(chan protocol.Response)
	writeResults := make(chan writeResult, 1)
	stopIO := make(chan struct{})
	defer close(stopIO)
	defer func() {
		if closer, ok := output.(io.Closer); ok {
			_ = closer.Close()
		}
	}()
	go readCommands(input, manager, local, ended, stopIO)
	writer := protocol.NewWriter(output)
	go func() {
		for {
			select {
			case response := <-writeRequests:
				err := writer.Write(response)
				select {
				case writeResults <- writeResult{response: response, err: err}:
				case <-stopIO:
					return
				}
				if err != nil {
					return
				}
			case <-stopIO:
				return
			}
		}
	}()
	outgoing := make([]protocol.Response, 0, 8)
	responses := manager.Responses()
	inputClosed, writerBusy := false, false
	var drain <-chan time.Time
	var timer *time.Timer
	defer func() {
		if timer != nil {
			timer.Stop()
		}
	}()
	for {
		if inputClosed && responses == nil && len(outgoing) == 0 && !writerBusy && len(local) == 0 {
			return nil
		}
		if len(outgoing) < 8 {
			select {
			case response := <-local:
				outgoing = append(outgoing, response)
				continue
			default:
			}
		}
		readResponses := responses
		readLocal := local
		if len(outgoing) >= 8 {
			readResponses = nil
			readLocal = nil
		}
		var send chan<- protocol.Response
		var next protocol.Response
		if len(outgoing) > 0 && !writerBusy {
			send, next = writeRequests, outgoing[0]
		}
		select {
		case ending := <-ended:
			if ending.err != nil {
				return ending.err
			}
			inputClosed = !ending.shutdown
			ended = nil
			timer = time.NewTimer(time.Second)
			drain = timer.C
		case <-drain:
			return nil
		case send <- next:
			writerBusy = true
			outgoing[0] = protocol.Response{}
			outgoing = outgoing[1:]
		case written := <-writeResults:
			writerBusy = false
			if written.err != nil {
				return written.err
			}
			if written.response.Type == "shutdown.ack" {
				return nil
			}
		case response := <-readLocal:
			outgoing = append(outgoing, response)
		case response, ok := <-readResponses:
			if !ok {
				responses = nil
				continue
			}
			outgoing = append(outgoing, response)
		}
	}
}

func main() {
	if err := run(os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
