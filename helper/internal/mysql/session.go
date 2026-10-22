package mysql

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

type Session struct {
	adapter.TransportBinding
	mu             sync.Mutex
	work           *connection
	serverUUID     string
	connectionID   uint32
	openControl    func(context.Context) (*connection, error)
	closed         atomic.Bool
	transaction    atomic.Value
	commitOverride func(func() error) error
	afterRowLock   func(int)
}

func Open(ctx context.Context, settings protocol.Connection) (adapter.Session, error) {
	if _, err := tlsConfiguration(settings); err != nil {
		return nil, err
	}
	work, err := dial(ctx, settings)
	if err != nil {
		return nil, safeConnectionError(err)
	}
	tunnel := adapter.TransportFromContext(ctx)
	session := &Session{work: work, connectionID: work.client.GetConnectionID(), TransportBinding: adapter.TransportBinding{Transport: tunnel}}
	session.transaction.Store("idle")
	session.openControl = func(ctx context.Context) (*connection, error) { return dialWithTransport(ctx, settings, tunnel) }
	uuid, err := serverIdentity(work)
	if err != nil || uuid == "" || session.connectionID == 0 {
		session.Close()
		return nil, &adapter.ConnectionError{Category: "connection", Message: "MySQL server identity could not be verified."}
	}
	session.serverUUID = uuid
	_ = work.transport.SetDeadline(time.Time{})
	session.updateTransaction()
	return session, nil
}

func safeConnectionError(err error) error {
	var validation *adapter.ConnectionError
	if errors.As(err, &validation) {
		return validation
	}
	var server *wire.MyError
	if errors.As(err, &server) && (server.Code == 1045 || server.Code == 1698) {
		return &adapter.ConnectionError{Category: "authentication", Message: "MySQL authentication failed.", SQLState: "28000"}
	}
	return &adapter.ConnectionError{Category: "connection", Message: "Cannot connect to MySQL. Check server availability, credentials and TLS settings."}
}

func serverIdentity(conn *connection) (string, error) {
	result, err := conn.client.Execute("SELECT @@server_uuid, CONNECTION_ID()")
	if err != nil {
		return "", err
	}
	defer result.Close()
	if result.RowNumber() != 1 {
		return "", errors.New("invalid server identity")
	}
	uuid, err := result.GetString(0, 0)
	if err != nil {
		return "", err
	}
	id, err := result.GetInt(0, 1)
	if err != nil || id != int64(conn.client.GetConnectionID()) {
		return "", errors.New("connection identity mismatch")
	}
	return uuid, nil
}

func (session *Session) Close() {
	if session.closed.CompareAndSwap(false, true) {
		session.transaction.Store("unknown")
		_ = session.work.transport.Close()
		session.CloseTransport()
	}
}

func (session *Session) TransactionStatus() string { return session.transaction.Load().(string) }

func (session *Session) updateTransaction() {
	status := "idle"
	if session.work.client.IsInTransaction() {
		status = "transaction"
	}
	session.transaction.Store(status)
}

type cancellation struct {
	attempted bool
	err       error
	deadline  time.Time
}

// Execute owns this session until both the query and cancellation worker finish.
// In particular no subsequent query or recovery probe can race a late KILL.
func (session *Session) Execute(ctx context.Context, command protocol.Command) protocol.Response {
	return session.ExecuteWithSink(ctx, command, nil)
}

func (session *Session) ExecuteWithSink(ctx context.Context, command protocol.Command, sink adapter.ResultSink) protocol.Response {
	if command.Changes != nil {
		return session.ExecuteChanges(ctx, command)
	}
	if command.Catalog != nil {
		return session.catalog(ctx, command, sink)
	}
	if unsupportedStatement(command.SQL) {
		response := protocol.ErrorResponse(command, "validation", "MySQL client commands, COPY and LOAD DATA LOCAL are not supported. Submit SQL statements directly.")
		response.Connected, response.TransactionStatus = !session.closed.Load(), session.TransactionStatus()
		response.SQLNotExecuted = command.Type == "execute"
		return response
	}
	return session.executeWith(ctx, command, func(collector *collector, result *wire.Result) error {
		return session.executeResults(command.SQL, collector, result)
	}, sink)
}

func (session *Session) executeWith(ctx context.Context, command protocol.Command, operation func(*collector, *wire.Result) error, sinks ...adapter.ResultSink) protocol.Response {
	session.mu.Lock()
	defer session.mu.Unlock()
	if session.closed.Load() {
		response := protocol.ErrorResponse(command, "connection", "The MySQL session is closed. SQL was not executed.")
		response.SQLNotExecuted = command.Type == "execute"
		return response
	}
	ctx, cancel := context.WithTimeout(ctx, ExecuteTimeout)
	defer cancel()
	if ctx.Err() != nil {
		response := session.queryError(command, ctx, ctx.Err())
		response.SQLNotExecuted = command.Type == "execute"
		return response
	}
	if deadline, ok := ctx.Deadline(); ok {
		_ = session.work.transport.SetDeadline(deadline.Add(RecoveryTimeout))
	}
	started := time.Now()
	var gate sync.Mutex
	active := true
	done := make(chan struct{})
	watcher := make(chan cancellation, 1)
	go func() {
		select {
		case <-done:
			watcher <- cancellation{}
			return
		case <-ctx.Done():
		}
		result := cancellation{deadline: time.Now().Add(RecoveryTimeout)}
		_ = session.work.transport.SetDeadline(result.deadline)
		controlCtx, stop := context.WithDeadline(context.Background(), result.deadline)
		defer stop()
		control, err := session.openControl(controlCtx)
		if err == nil {
			defer control.transport.Close()
			var uuid string
			uuid, err = serverIdentity(control)
			if err == nil && (uuid != session.serverUUID || control.client.GetConnectionID() == session.connectionID ||
				session.work.client.GetConnectionID() != session.connectionID) {
				err = errors.New("cancellation server identity mismatch")
			}
		}
		gate.Lock()
		defer gate.Unlock()
		if !active {
			watcher <- result
			return
		}
		if err == nil {
			// The target ID belongs to this still-open physical connection. The
			// UUID check prevents a load balancer from cancelling another server.
			var target *wire.Result
			target, err = control.client.Execute(fmt.Sprintf("SELECT ID FROM information_schema.PROCESSLIST WHERE ID = %d", session.connectionID))
			if err == nil {
				var id int64
				if target.RowNumber() == 1 {
					id, err = target.GetInt(0, 0)
				}
				if id != int64(session.connectionID) {
					err = errors.New("cancellation target is missing")
				}
				target.Close()
			}
		}
		if err == nil {
			result.attempted = true
			var killed *wire.Result
			killed, err = control.client.Execute(fmt.Sprintf("KILL QUERY %d", session.connectionID))
			if killed != nil {
				killed.Close()
			}
		}
		result.err = err
		if err != nil {
			session.Close()
		}
		watcher <- result
	}()
	collector := newCollector(command)
	if len(sinks) > 0 && sinks[0] != nil {
		collector.delivery = &sinkDelivery{sink: sinks[0]}
	}
	result := wire.NewResult(nil)
	defer result.Close()
	err := operation(collector, result)
	gate.Lock()
	active = false
	gate.Unlock()
	close(done)
	cancelled := <-watcher
	if session.closed.Load() || cancelled.err != nil {
		return collector.attachResults(session.unknown(command))
	}
	if err != nil || cancelled.attempted || collector.needsStatusProbe {
		// ERR packets have no status flags. COM_PING returns a new OK packet
		// without running SQL or changing the user's transaction/session state.
		deadline := time.Now().Add(RecoveryTimeout)
		if !cancelled.deadline.IsZero() && cancelled.deadline.Before(deadline) {
			deadline = cancelled.deadline
		}
		_ = session.work.transport.SetDeadline(deadline)
		var sqlError *wire.MyError
		var validation *adapter.ConnectionError
		if err != nil && !errors.As(err, &sqlError) && !errors.As(err, &validation) {
			session.Close()
			return collector.attachResults(session.unknown(command))
		}
		if session.work.client.Ping() != nil {
			session.Close()
			return collector.attachResults(session.unknown(command))
		}
	}
	_ = session.work.transport.SetDeadline(time.Time{})
	session.updateTransaction()
	if err != nil {
		response := session.queryError(command, ctx, err)
		var validation *adapter.ConnectionError
		if errors.As(err, &validation) {
			response = protocol.ErrorResponse(command, validation.Category, validation.Message)
			response.Connected = true
			response.TransactionStatus = session.TransactionStatus()
		}
		if len(collector.resultSets) > 0 {
			response.ResultSets = collector.resultSets
			response = boundResultSets(response)
		}
		return response
	}
	response := collector.finish(result, time.Since(started), session.TransactionStatus())
	if cancelled.attempted {
		if response.DisplayNotice != "" {
			response.DisplayNotice += " "
		}
		response.DisplayNotice += "Cancellation was requested; the server completed the statement. The returned result and transaction state are authoritative."
	}
	return response
}

func (session *Session) unknown(command protocol.Command) protocol.Response {
	response := protocol.ErrorResponse(command, "connection", "MySQL session could not be recovered. The command outcome is unknown.")
	response.OutcomeUnknown = true
	return response
}

func (session *Session) queryError(command protocol.Command, ctx context.Context, err error) protocol.Response {
	response := protocol.ErrorResponse(command, "sql", "MySQL rejected the SQL command.")
	response.Connected, response.TransactionStatus = !session.closed.Load(), session.TransactionStatus()
	var server *wire.MyError
	interrupted := errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded)
	if errors.As(err, &server) {
		interrupted = server.Code == 1317 || server.Code == 3024
		if len(server.State) == 5 {
			response.SQLState = server.State
		}
		message := server.Message
		if len(message) > 4096 {
			message = message[:4096]
			for !utf8.ValidString(message) {
				message = message[:len(message)-1]
			}
		}
		response.Message = strings.ToValidUTF8(message, "�")
	}
	if interrupted && errors.Is(ctx.Err(), context.DeadlineExceeded) {
		response.Category, response.Message = "timeout", "Query execution timed out."
	} else if interrupted && errors.Is(ctx.Err(), context.Canceled) {
		response.Category, response.Message = "cancelled", "Query was cancelled."
	}
	return response
}
