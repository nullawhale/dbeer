// dbeer-core is bundled with DBeer and communicates exclusively over its pipes.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/cassandra"
	"dbeer/helper/internal/mysql"
	"dbeer/helper/internal/postgres"
	"dbeer/helper/internal/productidentity"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/session"
	"dbeer/helper/internal/sqllsp"
)

// Native GPUI product builds set these explicit -X main.* link values from the
// same canonical identity and root VERSION/BUILD_NUMBER as their paired GUI.
// Ordinary macOS and development helpers leave all three empty. Environment
// variables are never product authority. Keep the plain compact JSON marker:
// the native packager verifies its exact bytes before invoking --build-info.
var productBuildIdentity string
var productVersion string
var productBuildNumber string

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
	case "cassandra":
		return cassandra.Open(ctx, connection)
	default:
		return nil, &adapter.ConnectionError{Category: "connection", Message: "Database engine is unavailable."}
	}
}

func run(input io.Reader, output io.Writer) error {
	return runProduct(input, output, nil)
}

func runProduct(input io.Reader, output io.Writer, identity *productidentity.Identity) error {
	postgres.PrepareEnvironment()
	return runWithFactoryAndIdentity(input, output, openDatabase, identity)
}

// The input reader owns protocol guards and never waits for result output.
// Ordinary admission is bounded; overflow is a transport failure, rather than
// indefinitely hiding Stop/EOF behind an unresponsive output consumer.
func readCommands(input io.Reader, manager *session.Manager, local chan<- protocol.Response, ended chan<- inputEnd, stop <-chan struct{}, identity *productidentity.Identity) {
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
				response = protocol.ErrorResponse(command, "protocol", "Incompatible protocol version; version 3 is required.")
			} else if handshaken {
				response = protocol.ErrorResponse(command, "protocol", "Protocol handshake has already completed.")
			} else {
				handshaken = true
				response = protocol.Response{Type: "hello.ack", RequestID: command.RequestID, ProtocolVersion: protocol.Version, Capabilities: []string{"capturedExportV1"}, BuildIdentity: identity}
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
	return runWithFactoryAndIdentity(input, output, opener, nil)
}

func runWithFactoryAndIdentity(input io.Reader, output io.Writer, opener adapter.OpenFunc, identity *productidentity.Identity) error {
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
	go readCommands(input, manager, local, ended, stopIO, identity)
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

// Dispatch metadata before reading stdin or initializing PostgreSQL, framed
// transport, sessions or the language server. Mixed/unknown metadata options
// refuse here and can never fall through into an ordinary helper process.
func runCommand(args []string, input io.Reader, output io.Writer, rawIdentity, version, build string) error {
	for _, argument := range args {
		if strings.HasPrefix(argument, "--build-info") {
			if len(args) != 1 || argument != "--build-info" {
				return productidentity.ErrInvalid
			}
			data, err := productidentity.HelperJSON(rawIdentity, version, build)
			if err != nil {
				return productidentity.ErrInvalid
			}
			_, err = output.Write(data)
			return err
		}
	}
	identity, err := productidentity.OptionalCompiled(rawIdentity, version, build)
	if err != nil {
		return productidentity.ErrInvalid
	}
	if len(args) == 1 && args[0] == "--language-server" {
		return sqllsp.Run(input, output)
	}
	return runProduct(input, output, identity)
}

func main() {
	if err := runCommand(os.Args[1:], os.Stdin, os.Stdout, productBuildIdentity, productVersion, productBuildNumber); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
