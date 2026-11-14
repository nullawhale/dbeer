// Package session multiplexes independent physical database sessions. Its
// routing loop never performs database I/O; each session has an exclusive owner.
package session

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"slices"
	"sync"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/catalogmetadata"
	"dbeer/helper/internal/credential"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/queryparams"
	"dbeer/helper/internal/tableedit"
)

const MaxSessions = 64
const ConnectTimeout = 5 * time.Second
const QueryTimeout = 30 * time.Second

type Manager struct {
	commands                chan protocol.Command
	responses               chan protocol.Response
	events                  chan event
	stop                    chan struct{}
	done                    chan struct{}
	once                    sync.Once
	workers                 sync.WaitGroup
	opener                  adapter.OpenFunc
	timeout                 time.Duration
	controlMu               sync.RWMutex
	owners                  map[string]*owner
	shutdownRequests        chan protocol.Command
	shutdownOnce            sync.Once
	pendingQueries          map[string]pendingQuery
	closedStructureSessions map[string]bool
	closedStructureOrder    []string
	quiescing               bool
}

type pendingQuery struct {
	sessionID string
	canceled  bool
}

type event struct {
	sessionID string
	response  protocol.Response
	closed    bool
}

func New(opener adapter.OpenFunc) *Manager { return newWithTimeout(opener, QueryTimeout) }

func newWithTimeout(opener adapter.OpenFunc, timeout time.Duration) *Manager {
	manager := &Manager{commands: make(chan protocol.Command, 256), responses: make(chan protocol.Response, 8), events: make(chan event, 8),
		stop: make(chan struct{}), done: make(chan struct{}), opener: opener, timeout: timeout, owners: make(map[string]*owner), shutdownRequests: make(chan protocol.Command, 1), pendingQueries: make(map[string]pendingQuery), closedStructureSessions: make(map[string]bool)}
	go manager.run()
	return manager
}

func (manager *Manager) Responses() <-chan protocol.Response { return manager.responses }
func (manager *Manager) Commands() chan<- protocol.Command   { return manager.commands }

func (manager *Manager) Submit(command protocol.Command) bool {
	select {
	case <-manager.done:
		return false
	default:
	}
	manager.markPending(command)
	select {
	case manager.commands <- command:
		return true
	case <-manager.done:
		return false
	}
}

func (manager *Manager) markPending(command protocol.Command) {
	if (command.Type == "monitor.snapshot" || command.Type == "monitor.schema") || command.Type == "execute" || command.Type == "command.execute" || command.Type == "explain.run" || command.Type == "catalog" || isCatalogMetadata(command.Type) || command.Type == "changes.preview" || command.Type == "changes.apply" || isStructure(command.Type) || isImport(command.Type) {
		manager.controlMu.Lock()
		manager.pendingQueries[command.QueryID] = pendingQuery{sessionID: command.SessionID}
		manager.controlMu.Unlock()
	}
}

func (manager *Manager) TrySubmit(command protocol.Command) bool {
	select {
	case <-manager.done:
		return false
	default:
	}
	manager.markPending(command)
	select {
	case <-manager.done:
		return false
	case manager.commands <- command:
		return true
	default:
		return false
	}
}

func (manager *Manager) forgetPending(command protocol.Command) {
	manager.controlMu.Lock()
	delete(manager.pendingQueries, command.QueryID)
	manager.controlMu.Unlock()
}

// Routing rejections happen before the adapter receives the submitted SQL.
// Keep them distinct from terminal failures of dispatched database commands.
func rejectedCommand(command protocol.Command, category, message string) protocol.Response {
	response := protocol.ErrorResponse(command, category, message)
	response.SQLNotExecuted = command.Type == "execute" || command.Type == "command.execute" || command.Type == "explain.run" || command.Type == "structure.apply" || command.Type == "structure.physical.apply" || command.Type == "structure.migration.apply" || command.Type == "structure.validate" || isImport(command.Type)
	return response
}

// Close is an out-of-band abort used by EOF or transport failure. It also
// unblocks full response queues, then waits until all physical sessions close.
func (manager *Manager) Close() {
	manager.once.Do(func() { close(manager.stop) })
	<-manager.done
}

func (manager *Manager) run() {
	defer close(manager.done)
	defer close(manager.responses)
	defer manager.workers.Wait()
	owners := manager.owners
	var shutdown *protocol.Command
	beginShutdown := func(command protocol.Command) {
		shutdown = &command
		manager.controlMu.RLock()
		defer manager.controlMu.RUnlock()
		for _, owner := range owners {
			owner.requestStop(nil)
		}
	}
	emit := func(response protocol.Response) bool {
		for {
			select {
			case manager.responses <- response:
				return true
			case <-manager.stop:
				return false
			case command := <-manager.shutdownRequests:
				beginShutdown(command)
			}
		}
	}
	for {
		if shutdown != nil && len(owners) == 0 {
			emit(protocol.Response{Type: "shutdown.ack", RequestID: shutdown.RequestID})
			return
		}
		commands := manager.commands
		if shutdown != nil {
			commands = nil
		}
		select {
		case <-manager.stop:
			return
		case command := <-manager.shutdownRequests:
			beginShutdown(command)
		case result := <-manager.events:
			if result.closed {
				manager.controlMu.Lock()
				if closedOwner := owners[result.sessionID]; closedOwner != nil && closedOwner.structureOnly {
					manager.closedStructureSessions[result.sessionID] = true
					manager.closedStructureOrder = append(manager.closedStructureOrder, result.sessionID)
					if len(manager.closedStructureOrder) > 256 {
						old := manager.closedStructureOrder[0]
						manager.closedStructureOrder = manager.closedStructureOrder[1:]
						delete(manager.closedStructureSessions, old)
					}
				}
				delete(owners, result.sessionID)
				manager.controlMu.Unlock()
			} else if !emit(result.response) {
				return
			}
		case command := <-commands:
			if command.Type == "formatInserts" {
				if !emit(formatInserts(command)) {
					return
				}
				continue
			}
			if command.Type == "shutdown" {
				beginShutdown(command)
				continue
			}
			if command.Type == "connect" {
				manager.controlMu.RLock()
				quiescing := manager.quiescing
				manager.controlMu.RUnlock()
				if quiescing {
					if !emit(protocol.ErrorResponse(command, "cancelled", "Connection attempt was cancelled.")) {
						return
					}
					continue
				}
				if command.Connection == nil {
					if !emit(protocol.ErrorResponse(command, "protocol", "Connection settings are required.")) {
						return
					}
					continue
				}
				if command.Connection.SessionPurpose == "monitor" && command.Connection.DatabaseEngine() != "postgresql" && command.Connection.DatabaseEngine() != "mysql" {
					if !emit(protocol.ErrorResponse(command, "capability", "Session monitoring is available only for PostgreSQL and MySQL.")) {
						return
					}
					continue
				}
				if len(owners) >= MaxSessions {
					if !emit(protocol.ErrorResponse(command, "busy", "The maximum number of sessions is already open.")) {
						return
					}
					continue
				}
				var randomID [16]byte
				if _, err := rand.Read(randomID[:]); err != nil {
					if !emit(protocol.ErrorResponse(command, "connection", "Cannot create a session identifier.")) {
						return
					}
					continue
				}
				id := hex.EncodeToString(randomID[:])
				owner := &owner{id: id, structureOnly: command.Connection.SessionPurpose == "structure", importOnly: command.Connection.SessionPurpose == "import", monitorOnly: command.Connection.SessionPurpose == "monitor", manager: manager, commands: make(chan protocol.Command, 1), shutdown: make(chan struct{})}
				manager.controlMu.Lock()
				owners[id] = owner
				manager.controlMu.Unlock()
				manager.workers.Go(func() { owner.run(command) })
				continue
			}
			owner := owners[command.SessionID]
			if owner == nil {
				manager.forgetPending(command)
				if !emit(rejectedCommand(command, "connection", "Session identifier is not active.")) {
					return
				}
				continue
			}
			if category := owner.route(command); category != "" {
				manager.forgetPending(command)
				response := rejectedCommand(command, category, "Session is closing or its command queue is full.")
				response.Connected = category == "busy"
				if !emit(response) {
					return
				}
			}
		}
	}
}

type operation struct {
	session  adapter.Session
	response protocol.Response
	txStatus string
	err      error
}

type owner struct {
	metadata           catalogmetadata.Store
	structure          tableedit.Store
	migration          tableedit.MigrationStore
	physicalDDL        tableedit.PhysicalStore
	structureOnly      bool
	importOnly         bool
	monitorOnly        bool
	id                 string
	manager            *Manager
	commands           chan protocol.Command
	shutdown           chan struct{}
	routeMu            sync.Mutex
	closing            bool
	controlMu          sync.Mutex
	activeQuery        string
	activeCancel       context.CancelFunc
	credit             *creditState
	stopOnce           sync.Once
	externalDisconnect *protocol.Command
	stopRequested      bool
	closedPhysical     bool
	authMu             sync.Mutex
	grant              *operationGrant
	approvedExplainSQL string
}

// Control is deliberately separate from ordinary routing and result queues.
// The input reader validates handshake/IDs before calling it. Its effects never
// wait for stdout or for an outstanding stream credit.
func (manager *Manager) Control(command protocol.Command) *protocol.Response {
	if command.Type == "cancel" || command.Type == "disconnect" {
		manager.controlMu.RLock()
		owner := manager.owners[command.SessionID]
		manager.controlMu.RUnlock()
		if owner != nil {
			owner.invalidateGrant()
		}
	}
	if command.Type == "shutdown" {
		manager.shutdownOnce.Do(func() {
			manager.controlMu.Lock()
			manager.quiescing = true
			for _, owner := range manager.owners {
				owner.requestStop(nil)
			}
			manager.controlMu.Unlock()
		})
		return nil
	}
	if command.Type == "cancel" {
		manager.controlMu.Lock()
		pending, ok := manager.pendingQueries[command.QueryID]
		if ok && pending.sessionID == command.SessionID {
			pending.canceled = true
			manager.pendingQueries[command.QueryID] = pending
			manager.controlMu.Unlock()
			response := protocol.Response{Type: "cancel.ack", RequestID: command.RequestID, SessionID: command.SessionID, QueryID: command.QueryID, Status: "accepted"}
			return &response
		}
		manager.controlMu.Unlock()
	}
	manager.controlMu.RLock()
	owner := manager.owners[command.SessionID]
	knownStructureClosed := manager.closedStructureSessions[command.SessionID]
	manager.controlMu.RUnlock()
	if owner == nil {
		if command.Type == "disconnect" && knownStructureClosed {
			response := protocol.Response{Type: "disconnect.ack", RequestID: command.RequestID, SessionID: command.SessionID}
			return &response
		}
		if command.Type == "stream.ack" {
			return nil
		}
		response := protocol.ErrorResponse(command, "connection", "Session identifier is not active.")
		return &response
	}
	if command.Type == "disconnect" {
		if owner.requestStop(&command) {
			return nil
		}
		owner.controlMu.Lock()
		closed := owner.structureOnly && owner.closedPhysical
		owner.controlMu.Unlock()
		if closed {
			response := protocol.Response{Type: "disconnect.ack", RequestID: command.RequestID, SessionID: command.SessionID}
			return &response
		}
		response := protocol.ErrorResponse(command, "connection", "Session is closing.")
		return &response
	}
	owner.controlMu.Lock()
	defer owner.controlMu.Unlock()
	if command.Type == "stream.ack" {
		if owner.credit == nil || owner.activeQuery != command.QueryID {
			return nil
		}
		if owner.credit.ack(command.Sequence) {
			return nil
		}
		response := protocol.ErrorResponse(command, "protocol", "Unexpected stream credit.")
		return &response
	}
	status := "alreadyFinished"
	if owner.activeQuery == command.QueryID && owner.activeCancel != nil {
		owner.activeCancel()
		status = "accepted"
	}
	response := protocol.Response{Type: "cancel.ack", RequestID: command.RequestID, SessionID: command.SessionID, QueryID: command.QueryID, Status: status}
	return &response
}

func (owner *owner) requestStop(disconnect *protocol.Command) bool {
	owner.controlMu.Lock()
	if disconnect != nil && owner.structureOnly && owner.closedPhysical {
		owner.controlMu.Unlock()
		return false
	}
	if disconnect != nil && owner.stopRequested {
		owner.controlMu.Unlock()
		return false
	}
	owner.stopRequested = true
	if disconnect != nil && owner.externalDisconnect == nil {
		copy := *disconnect
		owner.externalDisconnect = &copy
	}
	if owner.activeCancel != nil {
		owner.activeCancel()
	}
	owner.controlMu.Unlock()
	owner.stopOnce.Do(func() { close(owner.shutdown) })
	return true
}

func (owner *owner) route(command protocol.Command) string {
	owner.routeMu.Lock()
	defer owner.routeMu.Unlock()
	if owner.closing {
		return "connection"
	}
	select {
	case owner.commands <- command:
		return ""
	default:
		return "busy"
	}
}

func (owner *owner) closeRouting() []protocol.Response {
	owner.routeMu.Lock()
	defer owner.routeMu.Unlock()
	owner.closing = true
	var rejected []protocol.Response
	for {
		select {
		case command := <-owner.commands:
			owner.manager.forgetPending(command)
			rejected = append(rejected, rejectedCommand(command, "connection", "Session is closing."))
		default:
			return rejected
		}
	}
}

func (owner *owner) run(connectCommand protocol.Command) {
	defer owner.metadata.Close()
	var physical adapter.Session
	defer func() {
		if physical != nil {
			physical.Close()
		}
		select {
		case owner.manager.events <- event{sessionID: owner.id, closed: true}:
		case <-owner.manager.stop:
		}
	}()
	connection := *connectCommand.Connection
	engine := connection.DatabaseEngine()
	policy := protocol.ExecutionPolicy{Environment: "unspecified"}
	if connection.Policy != nil {
		policy = *connection.Policy
	}
	if owner.monitorOnly {
		policy.ReadOnly = true
		connection.Policy = &policy
	}
	pending := connectCommand
	result := make(chan operation, 1)
	connectTimeout := ConnectTimeout
	if connection.SSH != nil {
		connectTimeout = 30 * time.Second
	}
	if connection.PasswordCommand != nil {
		connectTimeout += credential.Timeout
	}
	ctx, cancel := context.WithTimeout(context.Background(), connectTimeout)
	defer func() { cancel() }()
	go func() {
		physical, err := owner.manager.opener(ctx, connection)
		if physical == nil && err == nil {
			err = errors.New("adapter returned no session")
		}
		tx := ""
		if physical != nil && err == nil {
			if owner.monitorOnly {
				if _, ok := physical.(adapter.SessionMonitor); !ok {
					err = &adapter.ConnectionError{Category: "capability", Message: "Session monitoring is unavailable for this adapter."}
				}
			}
			if err == nil && policy.ReadOnly && engine != "cassandra" && engine != "mongodb" {
				readOnly, ok := physical.(adapter.ReadOnlySession)
				if !ok {
					err = errors.New("adapter has no readonly mode")
				} else {
					err = readOnly.SetReadOnly(ctx, true)
				}
			}
			tx = physical.TransactionStatus()
		}
		result <- operation{session: physical, txStatus: tx, err: err}
	}()
	var active <-chan operation = result
	var disconnect *protocol.Command
	var beginExecution chan struct{}
	outgoing := make([]protocol.Response, 0, 4)
	txStatus := ""
	stopping, aborting, closed, routingClosed := false, false, false, false
	stop, shutdown := owner.manager.stop, owner.shutdown
	var transportDone <-chan struct{}
	transportFailed := false
	for {
		if stopping && !routingClosed {
			outgoing = append(outgoing, owner.closeRouting()...)
			routingClosed = true
		}
		if stopping && active == nil && !closed {
			if physical != nil {
				physical.Close()
				physical = nil
			}
			if owner.structureOnly {
				owner.controlMu.Lock()
				owner.closedPhysical = true
				if disconnect == nil && owner.externalDisconnect != nil {
					copy := *owner.externalDisconnect
					disconnect = &copy
				}
				owner.controlMu.Unlock()
			}
			closed = true
			if disconnect != nil {
				outgoing = append(outgoing, protocol.Response{Type: "disconnect.ack", RequestID: disconnect.RequestID, SessionID: owner.id})
			}
		}
		if aborting && active == nil {
			return
		}
		if closed && len(outgoing) == 0 {
			return
		}
		commands := owner.commands
		if stopping || len(outgoing) >= 2 {
			commands = nil
		}
		var send chan<- event
		var next event
		if len(outgoing) != 0 && !aborting {
			send = owner.manager.events
			next = event{sessionID: owner.id, response: outgoing[0]}
		}
		select {
		case <-transportDone:
			transportDone = nil
			transportFailed = true
			owner.invalidateGrant()
			stopping = true
			cancel()
		case <-stop:
			stop = nil
			stopping, aborting = true, true
			cancel()
			outgoing = nil
		case <-shutdown:
			shutdown = nil
			stopping = true
			owner.controlMu.Lock()
			disconnect = owner.externalDisconnect
			owner.controlMu.Unlock()
			cancel()
		case send <- next:
			if next.response.Type == "query.started" && beginExecution != nil {
				close(beginExecution)
				beginExecution = nil
			}
			outgoing[0] = protocol.Response{}
			outgoing = outgoing[1:]
		case completed := <-active:
			active = nil
			cancel()
			owner.controlMu.Lock()
			owner.activeQuery, owner.activeCancel, owner.credit = "", nil, nil
			owner.controlMu.Unlock()
			if pending.Type == "connect" {
				// SSH authentication is complete. Keep runtime control settings
				// without retaining the one-use authentication material in routing.
				if pending.Connection != nil && pending.Connection.SSH != nil {
					pending.Connection.SSH.Password, pending.Connection.SSH.Passphrase = "", ""
				}
				physical, txStatus = completed.session, completed.txStatus
				if monitored, ok := physical.(interface{ TransportDone() <-chan struct{} }); ok {
					transportDone = monitored.TransportDone()
					select {
					case <-transportDone:
						transportDone = nil
						transportFailed = true
						if completed.err == nil {
							completed.err = &adapter.ConnectionError{Category: "ssh", Message: "The SSH tunnel disconnected."}
						}
					default:
					}
				}
				if completed.err != nil {
					outgoing = append(outgoing, connectError(pending, completed.err))
					stopping = true
				} else if stopping {
					outgoing = append(outgoing, protocol.ErrorResponse(pending, "cancelled", "Connection attempt was cancelled."))
				} else {
					response := protocol.Response{Type: "connect.result", RequestID: pending.RequestID, SessionID: owner.id, Engine: engine, Capabilities: adapter.Capabilities(engine), TransactionStatus: txStatus}
					if _, ok := physical.(tableedit.PhysicalAdapter); !ok {
						response.Capabilities = slices.DeleteFunc(response.Capabilities, func(c string) bool { return c == protocol.StructurePhysicalCapability })
					}
					support := adapter.SessionOperationSupport(engine, physical, policy)
					response.OperationSupport = &support
					if _, ok := physical.(adapter.NativeCommandSession); ok {
						response.Capabilities = append(response.Capabilities, protocol.NativeCommandsCapability)
						if !slices.Contains(response.Capabilities, protocol.NativeResultValuesCapability) {
							response.Capabilities = append(response.Capabilities, protocol.NativeResultValuesCapability)
						}
					}
					response.Capabilities = append(response.Capabilities, protocol.OperationSupportCapability)
					if _, ok := physical.(adapter.SchemaObserver); ok {
						response.Capabilities = append(response.Capabilities, protocol.SchemaObservationCapability)
					}
					if _, ok := physical.(adapter.CatalogMetadataReader); ok {
						response.Capabilities = append(response.Capabilities, protocol.CatalogMetadataCapability)
					}
					if explain, ok := physical.(adapter.ExplainSession); ok {
						support := explain.ExplainSupport()
						response.ExplainSupport = &support
						response.Capabilities = append(response.Capabilities, protocol.VisualExplainCapability)
						if support.DML != nil {
							response.Capabilities = append(response.Capabilities, protocol.ExplainDMLCapability)
						}
						if support.Engine == "postgresql" || support.Engine == "mysql" {
							response.Capabilities = append(response.Capabilities, protocol.ExplainMetricsCapability)
						}
						if support.DiagnosticModel != "" {
							response.Capabilities = append(response.Capabilities, protocol.EngineDiagnosticsCapability)
						} else {
							response.Capabilities = append(response.Capabilities, protocol.ExplainParametersCapability)
							if support.Options != nil {
								response.Capabilities = append(response.Capabilities, protocol.ExplainOptionsCapability)
							}
						}
					}
					if current, ok := physical.(interface{ CurrentKeyspace() string }); ok {
						keyspace := current.CurrentKeyspace()
						response.CurrentKeyspace = &keyspace
					}
					outgoing = append(outgoing, response)
				}
			} else {
				response := completed.response
				attachOperationSupport(&response, engine, policy)
				if transportFailed && response.Type == "error" {
					response.Connected = false
				}
				if response.Type == "error" {
					owner.invalidateGrant()
				}
				// Correlation belongs to the owner rather than a driver. A driver
				// cannot accidentally finish another execution or another session.
				response.RequestID, response.SessionID, response.QueryID = pending.RequestID, owner.id, pending.QueryID
				outgoing = append(outgoing, response)
				txStatus = response.TransactionStatus
				if response.Type == "error" && !response.Connected {
					stopping = true
				}
			}
		case command := <-commands:
			select {
			case <-transportDone:
				transportDone = nil
				transportFailed = true
				owner.invalidateGrant()
				owner.manager.forgetPending(command)
				outgoing = append(outgoing, rejectedCommand(command, "connection", "The SSH tunnel disconnected."))
				stopping = true
				cancel()
				continue
			default:
			}
			var response protocol.Response
			switch command.Type {
			case "structure.physical.status":
				owner.manager.forgetPending(command)
				response = owner.physicalStatus(command)
				response.Connected = txStatus != "unknown"
				response.TransactionStatus = txStatus
			case "operation.assess":
				if owner.monitorOnly {
					response = protocol.ErrorResponse(command, "policy", "This session is reserved for readonly monitoring.")
				} else if active != nil || len(outgoing) != 0 {
					response = protocol.ErrorResponse(command, "busy", "Another operation is in progress in this session.")
				} else {
					response = owner.assess(command, engine, policy, physical)
				}
			case "monitor.snapshot", "monitor.schema", "import.describe", "import.preview", "import.apply", "structure.physical.inspect", "structure.physical.preview", "structure.physical.apply", "structure.physical.reconcile", "structure.physical.close", "structure.migration.preview", "structure.migration.apply", "structure.migration.export", "structure.migration.status", "structure.migration.reconcile", "structure.migration.close", "structure.load", "structure.preview", "structure.apply", "structure.validate", "structure.status", "structure.close", "execute", "command.execute", "explain.run", "catalog", "catalog.page", "catalog.batch", "catalog.close", "changes.preview", "changes.apply":
				if active != nil || len(outgoing) != 0 {
					owner.manager.forgetPending(command)
					response = rejectedCommand(command, "busy", "Another operation is in progress in this session.")
				} else if owner.manager.pendingWasCancelled(command) {
					owner.manager.forgetPending(command)
					response = rejectedCommand(command, "cancelled", "Execution was cancelled before it started.")
				} else if owner.monitorOnly && command.Type != "monitor.snapshot" && command.Type != "monitor.schema" || !owner.monitorOnly && (command.Type == "monitor.snapshot" || command.Type == "monitor.schema") {
					owner.manager.forgetPending(command)
					response = rejectedCommand(command, "policy", "Open a dedicated readonly monitor session to collect session activity.")
				} else if owner.importOnly && !isImport(command.Type) || !owner.importOnly && isImport(command.Type) {
					owner.manager.forgetPending(command)
					response = rejectedCommand(command, "policy", "Open a dedicated import session to import table data.")
				} else if owner.structureOnly && !isStructure(command.Type) {
					owner.manager.forgetPending(command)
					response = rejectedCommand(command, "policy", "This session is reserved for the table structure editor.")
				} else if command.Type == "command.execute" && !nativeCommandAvailable(physical, command) {
					owner.manager.forgetPending(command)
					owner.invalidateGrant()
					response = rejectedCommand(command, "capability", "Native commands are unavailable for this adapter.")
				} else if command.ResultValues != "" && command.Type != "command.execute" && !slices.Contains(adapter.Capabilities(engine), protocol.NativeResultValuesCapability) {
					owner.manager.forgetPending(command)
					response = rejectedCommand(command, "capability", "This adapter does not provide native result values.")
				} else if command.Type == "execute" && queryParameterError(engine, command) != nil {
					owner.manager.forgetPending(command)
					owner.invalidateGrant()
					response = rejectedCommand(command, "validation", queryParameterError(engine, command).Error())
				} else if command.Catalog != nil && command.Catalog.RelationshipScope != nil && engine != "sqlite" {
					owner.manager.forgetPending(command)
					response = rejectedCommand(command, "capability", "Incoming relationship scopes require the SQLite adapter.")
				} else if !owner.authorize(command, engine, policy, physical) {
					owner.manager.forgetPending(command)
					response = rejectedCommand(command, "policy", "Execution is blocked by readonly policy or requires a fresh confirmation of this exact operation.")
				} else {
					command.PreparedExplainSQL = owner.takeApprovedExplainSQL()
					duration := owner.manager.timeout
					if command.Type == "structure.physical.apply" {
						duration = 30 * time.Minute
					}
					ctx, cancel = context.WithTimeout(context.Background(), duration)
					pending = command
					credit := newCreditState(owner, command)
					owner.manager.controlMu.Lock()
					owner.controlMu.Lock()
					queued := owner.manager.pendingQueries[command.QueryID]
					delete(owner.manager.pendingQueries, command.QueryID)
					if queued.canceled || owner.manager.quiescing || owner.stopRequested {
						owner.controlMu.Unlock()
						owner.manager.controlMu.Unlock()
						cancel()
						response = rejectedCommand(command, "cancelled", "Execution was cancelled before it started.")
						response.Connected, response.TransactionStatus = true, txStatus
						outgoing = append(outgoing, response)
						continue
					}
					owner.activeQuery, owner.activeCancel, owner.credit = command.QueryID, cancel, credit
					owner.controlMu.Unlock()
					owner.manager.controlMu.Unlock()
					result := make(chan operation, 1)
					active = result
					begin := make(chan struct{})
					beginExecution = begin
					outgoing = append(outgoing, protocol.Response{Type: "query.started", RequestID: command.RequestID, SessionID: owner.id, QueryID: command.QueryID})
					go func() {
						select {
						case <-begin:
						case <-ctx.Done():
						}
						if isCatalogMetadata(command.Type) {
							result <- operation{response: owner.runCatalogMetadata(ctx, physical, command)}
						} else if command.Type == "monitor.schema" {
							result <- operation{response: runSchemaObservation(ctx, physical, command, engine)}
						} else if command.Type == "monitor.snapshot" {
							result <- operation{response: runMonitor(ctx, physical, command, engine)}
						} else if isStructure(command.Type) {
							result <- operation{response: owner.runStructure(ctx, physical, command)}
						} else {
							result <- operation{response: runExecution(ctx, physical, command, credit)}
						}
					}()
					continue
				}
			case "cancel":
				status := "alreadyFinished"
				if active != nil && ((pending.Type == "monitor.snapshot" || pending.Type == "monitor.schema") || pending.Type == "execute" || pending.Type == "command.execute" || pending.Type == "explain.run" || pending.Type == "catalog" || isCatalogMetadata(pending.Type) || pending.Type == "changes.preview" || pending.Type == "changes.apply" || isStructure(pending.Type) || isImport(pending.Type)) && pending.QueryID == command.QueryID {
					cancel()
					status = "accepted"
				}
				response = protocol.Response{Type: "cancel.ack", RequestID: command.RequestID, SessionID: owner.id, QueryID: command.QueryID, Status: status}
			case "disconnect":
				disconnect = &command
				stopping = true
				cancel()
				continue
			default:
				response = protocol.ErrorResponse(command, "protocol", "Command is unavailable in this session.")
			}
			if response.Type == "error" {
				response.Connected = physical != nil
				response.TransactionStatus = txStatus
			}
			outgoing = append(outgoing, response)
		}
	}
}

func connectError(command protocol.Command, err error) protocol.Response {
	response := protocol.ErrorResponse(command, "connection", "Cannot connect to the database. Check the address, TLS settings, and server availability.")
	var safe *adapter.ConnectionError
	if errors.As(err, &safe) {
		response.Category, response.Message, response.SQLState = safe.Category, safe.Message, safe.SQLState
	} else if errors.Is(err, context.DeadlineExceeded) {
		response.Category, response.Message = "timeout", "Connection attempt timed out."
	} else if errors.Is(err, context.Canceled) {
		response.Category, response.Message = "cancelled", "Connection attempt was cancelled."
	}
	return response
}

func (manager *Manager) pendingWasCancelled(command protocol.Command) bool {
	manager.controlMu.RLock()
	defer manager.controlMu.RUnlock()
	return manager.pendingQueries[command.QueryID].canceled
}

func queryParameterError(engine string, command protocol.Command) error {
	_, err := queryparams.Bind(engine, command.SQL, command.Parameters)
	return err
}

func isImport(kind string) bool {
	return kind == "import.describe" || kind == "import.preview" || kind == "import.apply"
}
