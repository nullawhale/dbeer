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
	"dbeer/helper/internal/comparisonjob"
	"dbeer/helper/internal/datacomparisonjob"
	"dbeer/helper/internal/mysql"
	"dbeer/helper/internal/postgres"
	"dbeer/helper/internal/productidentity"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/resultartifact"
	"dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/schemajob"
	"dbeer/helper/internal/session"
	"dbeer/helper/internal/sqllsp"
	"dbeer/helper/internal/sshtunnel"
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

func renderSchemaDefinition(ctx context.Context, capture schemacompare.Capture, ref schemacompare.Ref) (schemacompare.Definition, error) {
	switch capture.Context.Engine {
	case "postgresql":
		return postgres.RenderSchemaDefinition(ctx, capture, ref)
	case "mysql":
		return mysql.RenderSchemaDefinition(ctx, capture, ref)
	case "cassandra":
		return cassandra.RenderSchemaDefinition(ctx, capture, ref)
	default:
		return schemacompare.Definition{SQL: "-- SQL definition unavailable for this engine.\n", Limited: true}, nil
	}
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
	tunnels, err := sshtunnel.NewManager()
	if err != nil {
		return err
	}
	defer tunnels.Close()
	opener := func(ctx context.Context, connection protocol.Connection) (adapter.Session, error) {
		if connection.SSH == nil {
			return openDatabase(ctx, connection)
		}
		lease, err := tunnels.Acquire(ctx, connection.SSH)
		if err != nil {
			return nil, safeSSHError(err)
		}
		ssh := *connection.SSH
		ssh.Password, ssh.Passphrase = "", ""
		connection.SSH = &ssh
		physical, err := openDatabase(adapter.WithTransport(ctx, lease), connection)
		if err != nil {
			_ = lease.Close()
		}
		return physical, err
	}
	return runWithSSH(input, output, opener, identity, tunnels)
}

func safeSSHError(err error) *adapter.ConnectionError {
	var safe *sshtunnel.Error
	if errors.As(err, &safe) {
		return &adapter.ConnectionError{Category: safe.Code, Message: safe.Message}
	}
	if errors.Is(err, context.Canceled) {
		return &adapter.ConnectionError{Category: "cancelled", Message: "SSH connection was cancelled."}
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return &adapter.ConnectionError{Category: "timeout", Message: "SSH connection timed out."}
	}
	return &adapter.ConnectionError{Category: "ssh", Message: "Cannot establish the SSH connection."}
}

// The input reader owns protocol guards and never waits for result output.
// Ordinary admission is bounded; overflow is a transport failure, rather than
// indefinitely hiding Stop/EOF behind an unresponsive output consumer.
func readCommands(input io.Reader, manager *session.Manager, local chan<- protocol.Response, ended chan<- inputEnd, stop <-chan struct{}, identity *productidentity.Identity, tunnels *sshtunnel.Manager, controlContext context.Context, controls chan struct{}, comparisons *comparisonjob.Manager, schemas *schemajob.Manager, dataComparisons *datacomparisonjob.Manager) {
	reader := protocol.NewReader(input)
	requests, queries := make(map[string]bool), make(map[string]string)
	handshaken := false
	comparisonReads := make(chan struct{}, 2)
	finish := func(err error, shutdown bool) {
		comparisons.Close()
		schemas.Close()
		dataComparisons.Close()
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
			comparisons.Close()
			schemas.Close()
			dataComparisons.Close()
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
				response = protocol.ErrorResponse(command, "protocol", fmt.Sprintf("Incompatible protocol version; version %d is required.", protocol.Version))
			} else if handshaken {
				response = protocol.ErrorResponse(command, "protocol", "Protocol handshake has already completed.")
			} else {
				handshaken = true
				response = protocol.Response{Type: "hello.ack", RequestID: command.RequestID, ProtocolVersion: protocol.Version, Capabilities: []string{"capturedExportV1", "formatInsertsV1", "passwordCommandV1", protocol.ResultComparisonCapability, protocol.SchemaComparisonCapability, protocol.DataComparisonCapability}, BuildIdentity: identity}
				if tunnels != nil {
					response.Capabilities = append(response.Capabilities, "sshTunnelsV1", "sshConfigV1")
				}
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
		if strings.HasPrefix(command.Type, "data.") {
			if command.Type != "data.page" && command.Type != "data.value" && command.Type != "data.diff" {
				if !emit(dataComparisons.Handle(command)) {
					return
				}
				continue
			}
			select {
			case comparisonReads <- struct{}{}:
			default:
				if !emit(protocol.ErrorResponse(command, "busy", "Too many comparison reads are in progress.")) {
					return
				}
				continue
			}
			go func(command protocol.Command) {
				defer func() { <-comparisonReads }()
				response := dataComparisons.Handle(command)
				select {
				case local <- response:
				case <-controlContext.Done():
				}
			}(command)
			continue
		}
		if strings.HasPrefix(command.Type, "schema.") {
			if command.Type != "schema.page" && command.Type != "schema.value" && command.Type != "schema.diff" && command.Type != "schema.export" {
				if !emit(schemas.Handle(command)) {
					return
				}
				continue
			}
			select {
			case comparisonReads <- struct{}{}:
			default:
				if !emit(protocol.ErrorResponse(command, "busy", "Too many comparison reads are in progress.")) {
					return
				}
				continue
			}
			go func(command protocol.Command) {
				defer func() { <-comparisonReads }()
				response := schemas.Handle(command)
				select {
				case local <- response:
				case <-controlContext.Done():
				}
			}(command)
			continue
		}
		if strings.HasPrefix(command.Type, "compare.") {
			if command.Type != "compare.page" && command.Type != "compare.value" {
				if !emit(comparisons.Handle(command)) {
					return
				}
				continue
			}
			select {
			case comparisonReads <- struct{}{}:
			default:
				if !emit(protocol.ErrorResponse(command, "busy", "Too many comparison reads are in progress.")) {
					return
				}
				continue
			}
			go func(command protocol.Command) {
				defer func() { <-comparisonReads }()
				response := comparisons.Handle(command)
				select {
				case local <- response:
				case <-controlContext.Done():
				}
			}(command)
			continue
		}
		if command.Type == "ssh.probe" || command.Type == "ssh.trust" {
			if tunnels == nil {
				if !emit(protocol.ErrorResponse(command, "ssh", "SSH transport is unavailable.")) {
					return
				}
				continue
			}
			// Key discovery and trust checks must never block the input reader,
			// otherwise EOF, Stop and unrelated sessions cannot be serviced.
			select {
			case controls <- struct{}{}:
			default:
				if !emit(protocol.ErrorResponse(command, "busy", "Too many SSH checks are in progress.")) {
					return
				}
				continue
			}
			go func(command protocol.Command) {
				defer func() { <-controls }()
				ctx, cancel := context.WithTimeout(controlContext, 15*time.Second)
				defer cancel()
				response := protocol.Response{Type: command.Type + ".result", RequestID: command.RequestID}
				var err error
				if command.Type == "ssh.probe" {
					response.SSH, err = tunnels.Probe(ctx, command.Connection.SSH)
				} else {
					err = tunnels.Trust(ctx, command.Connection.SSH, command.SSHTrust.Token, command.SSHTrust.Replace)
					if err == nil {
						response.SSH, err = tunnels.Probe(ctx, command.Connection.SSH)
						if err == nil && response.SSH.Status != "trusted" && command.Connection.SSH.AuthMethod != "openSSH" {
							err = &sshtunnel.Error{Code: "host_key_changed", Message: "The SSH server key changed after review."}
						}
					}
				}
				if err != nil {
					safe := safeSSHError(err)
					response = protocol.ErrorResponse(command, safe.Category, safe.Message)
				}
				select {
				case local <- response:
				case <-controlContext.Done():
				}
			}(command)
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
	return runWithSSH(input, output, opener, identity, nil)
}

func runWithSSH(input io.Reader, output io.Writer, opener adapter.OpenFunc, identity *productidentity.Identity, tunnels *sshtunnel.Manager) error {
	store, err := resultartifact.NewDefaultStore()
	if err != nil {
		return err
	}
	comparisons, err := comparisonjob.New(comparisonjob.OpenArtifacts(store), comparisonjob.Options{})
	if err != nil {
		return err
	}
	return runWithManagers(input, output, opener, identity, tunnels, comparisons)
}

func runWithManagers(input io.Reader, output io.Writer, opener adapter.OpenFunc, identity *productidentity.Identity, tunnels *sshtunnel.Manager, comparisons *comparisonjob.Manager) error {
	defer comparisons.Close()
	schemas, err := schemajob.New(opener, schemajob.Options{RenderDefinition: renderSchemaDefinition})
	if err != nil {
		return err
	}
	defer schemas.Close()
	// The native owner supplies a private parent so it can clean captures after
	// forced process termination. This path is never accepted over the protocol.
	dataComparisons, err := datacomparisonjob.New(opener, datacomparisonjob.Options{Root: os.Getenv("DBEER_DATA_COMPARISON_ROOT")})
	if err != nil {
		return err
	}
	defer dataComparisons.Close()
	manager := session.New(opener)
	defer manager.Close()
	local := make(chan protocol.Response, 256)
	ended := make(chan inputEnd, 1)
	writeRequests := make(chan protocol.Response)
	writeResults := make(chan writeResult, 1)
	stopIO := make(chan struct{})
	controlContext, cancelControls := context.WithCancel(context.Background())
	controls := make(chan struct{}, 8)
	defer cancelControls()
	defer close(stopIO)
	defer func() {
		if closer, ok := output.(io.Closer); ok {
			_ = closer.Close()
		}
	}()
	go readCommands(input, manager, local, ended, stopIO, identity, tunnels, controlContext, controls, comparisons, schemas, dataComparisons)
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
	var drainDeadline time.Time
	armDrain := func() {
		if drainDeadline.IsZero() {
			return
		}
		timeout := time.Until(drainDeadline)
		// Slow resource teardown may use the graceful deadline, but an output
		// consumer that stops reading must never hold shutdown open that long.
		if writerBusy && timeout > time.Second {
			timeout = time.Second
		}
		if timer == nil {
			timer = time.NewTimer(timeout)
		} else {
			timer.Reset(timeout)
		}
		drain = timer.C
	}
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
			drainTimeout := time.Second
			if ending.shutdown && tunnels != nil {
				drainTimeout = 5 * time.Second
			}
			drainDeadline = time.Now().Add(drainTimeout)
			armDrain()
		case <-drain:
			return nil
		case send <- next:
			writerBusy = true
			armDrain()
			outgoing[0] = protocol.Response{}
			outgoing = outgoing[1:]
		case written := <-writeResults:
			writerBusy = false
			armDrain()
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
	if handled, err := sshtunnel.RunUtility(args); handled {
		return err
	}
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
