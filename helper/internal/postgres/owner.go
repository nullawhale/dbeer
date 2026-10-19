package postgres

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"sync"
	"time"

	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

type connectFunc func(context.Context, protocol.Connection) (*pgx.Conn, error)

// Owner serializes the lifetime and operations of one physical connection. A
// worker owns the connection exclusively during a blocking operation; the actor
// remains available to reject conflicts and request cancellation. There is no
// pool, replacement of an active connection, or automatic reconnection.
type Owner struct {
	commands  chan protocol.Command
	responses chan protocol.Response
	stop      chan struct{}
	done      chan struct{}
	once      sync.Once
}

func NewOwner() *Owner {
	clearPostgresEnvironment()
	return newOwner(connect)
}

func newOwner(connector connectFunc) *Owner {
	return newOwnerWithTimeout(connector, ExecuteTimeout)
}

func newOwnerWithTimeout(connector connectFunc, queryTimeout time.Duration) *Owner {
	owner := &Owner{commands: make(chan protocol.Command), responses: make(chan protocol.Response, 8), stop: make(chan struct{}), done: make(chan struct{})}
	go owner.run(connector, queryTimeout)
	return owner
}

func (owner *Owner) Responses() <-chan protocol.Response { return owner.responses }
func (owner *Owner) Commands() chan<- protocol.Command   { return owner.commands }

func (owner *Owner) Submit(command protocol.Command) bool {
	select {
	case owner.commands <- command:
		return true
	case <-owner.done:
		return false
	}
}

// Close is used for stdin EOF and transport failure. It cancels pending work,
// waits for its owner to return, and closes the session without writing an ack.
func (owner *Owner) Close() {
	owner.once.Do(func() { close(owner.stop) })
	<-owner.done
}

func connect(ctx context.Context, connection protocol.Connection) (*pgx.Conn, error) {
	config, err := connectionConfig(connection)
	if err != nil {
		return nil, err
	}
	return pgx.ConnectConfig(ctx, config)
}

type connectionResult struct {
	conn *pgx.Conn
	err  error
}

func (owner *Owner) run(connector connectFunc, queryTimeout time.Duration) {
	defer close(owner.done)
	defer close(owner.responses)
	var conn *pgx.Conn
	defer func() { closeConnection(conn) }()
	var sessionID string
	var pending *protocol.Command
	var cancel context.CancelFunc
	var shutdown *protocol.Command
	var connecting <-chan connectionResult
	var executing <-chan protocol.Response
	// This snapshot is read by the actor while a worker owns the connection.
	// Reading pgconn fields concurrently with an operation is not safe.
	var txStatus string
	stop := owner.stop
	stopping := false
	emit := func(response protocol.Response) bool {
		select {
		case owner.responses <- response:
			return true
		case <-owner.stop:
			return false
		}
	}
	for {
		if stopping && connecting == nil && executing == nil {
			closeConnection(conn)
			conn = nil
			if shutdown != nil {
				emit(protocol.Response{Type: "shutdown.ack", RequestID: shutdown.RequestID})
			}
			return
		}
		commands := owner.commands
		if stopping {
			commands = nil
		}
		select {
		case <-stop:
			stop = nil
			stopping = true
			if cancel != nil {
				cancel()
			}
		case result := <-connecting:
			connecting = nil
			cancel()
			cancel = nil
			command := *pending
			pending = nil
			if stopping {
				closeConnection(result.conn)
				if shutdown != nil {
					emit(protocol.ErrorResponse(command, "cancelled", "Connection attempt was cancelled."))
				}
				continue
			}
			if result.err != nil {
				closeConnection(result.conn)
				if !emit(connectionError(command, result.err)) {
					stopping = true
				}
				continue
			}
			id, err := newSessionID()
			if err != nil {
				closeConnection(result.conn)
				emit(protocol.ErrorResponse(command, "connection", "Cannot create a session identifier."))
				continue
			}
			conn, sessionID = result.conn, id
			txStatus = transactionStatus(conn)
			if !emit(protocol.Response{Type: "connect.result", RequestID: command.RequestID, SessionID: sessionID, TransactionStatus: txStatus}) {
				stopping = true
			}
		case response := <-executing:
			executing = nil
			cancel()
			cancel, pending = nil, nil
			if response.Type == "error" && !response.Connected {
				closeConnection(conn)
				conn, sessionID, txStatus = nil, "", ""
			} else {
				txStatus = response.TransactionStatus
			}
			if !emit(response) {
				stopping = true
			}
		case command := <-commands:
			if command.Type == "shutdown" {
				shutdown = &command
				stopping = true
				if cancel != nil {
					cancel()
				}
				continue
			}
			var response protocol.Response
			switch command.Type {
			case "connect":
				if connecting != nil || conn != nil {
					response = protocol.ErrorResponse(command, "busy", "Disconnect the current session before connecting again.")
				} else {
					ctx, cancelConnect := context.WithTimeout(context.Background(), ConnectTimeout)
					cancel = cancelConnect
					pending = &command
					result := make(chan connectionResult, 1)
					connecting = result
					connection := *command.Connection
					go func() {
						conn, err := connector(ctx, connection)
						result <- connectionResult{conn: conn, err: err}
					}()
					continue
				}
			case "execute":
				if connecting != nil || executing != nil {
					response = protocol.ErrorResponse(command, "busy", "Another operation is in progress.")
				} else if conn == nil || command.SessionID != sessionID {
					response = protocol.ErrorResponse(command, "connection", "Session identifier is not active.")
				} else {
					ctx, cancelQuery := context.WithTimeout(context.Background(), queryTimeout)
					cancel, pending = cancelQuery, &command
					result := make(chan protocol.Response, 1)
					executing = result
					if !emit(protocol.Response{Type: "query.started", RequestID: command.RequestID, SessionID: sessionID, QueryID: command.QueryID}) {
						stopping = true
						cancelQuery()
					}
					ownedConn := conn
					go func() { result <- execute(ctx, ownedConn, command) }()
					continue
				}
			case "cancel":
				if conn == nil || command.SessionID != sessionID {
					response = protocol.ErrorResponse(command, "connection", "Session identifier is not active.")
				} else {
					status := "alreadyFinished"
					if executing != nil && pending.QueryID == command.QueryID {
						cancel()
						status = "accepted"
					}
					response = protocol.Response{Type: "cancel.ack", RequestID: command.RequestID, SessionID: sessionID, QueryID: command.QueryID, Status: status}
				}
			case "disconnect":
				if connecting != nil || executing != nil {
					response = protocol.ErrorResponse(command, "busy", "Another operation is in progress.")
				} else if conn == nil || command.SessionID != sessionID {
					response = protocol.ErrorResponse(command, "connection", "Session identifier is not active.")
				} else {
					closeConnection(conn)
					conn, sessionID, txStatus = nil, "", ""
					response = protocol.Response{Type: "disconnect.ack", RequestID: command.RequestID, SessionID: command.SessionID}
				}
			default:
				response = protocol.ErrorResponse(command, "protocol", "Command is unavailable in this prototype stage.")
			}
			if response.Type == "error" {
				response.Connected = conn != nil
				if response.Connected {
					response.TransactionStatus = txStatus
				}
			}
			if !emit(response) {
				stopping = true
			}
		}
	}
}

func closeConnection(conn *pgx.Conn) {
	if conn == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_ = conn.Close(ctx)
}

func newSessionID() (string, error) {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(value[:]), nil
}

func transactionStatus(conn *pgx.Conn) string {
	switch conn.PgConn().TxStatus() {
	case 'T':
		return "transaction"
	case 'E':
		return "failedTransaction"
	default:
		return "idle"
	}
}

func connectionError(command protocol.Command, err error) protocol.Response {
	response := protocol.ErrorResponse(command, "connection", "Cannot connect to PostgreSQL. Check the address, TLS settings, and server availability.")
	var pgError *pgconn.PgError
	if errors.As(err, &pgError) {
		if validSQLState(pgError.Code) {
			response.SQLState = pgError.Code
		}
		switch pgError.Code {
		case "28P01", "28000":
			response.Message = "Authentication failed. Check the user and password."
		case "3D000":
			response.Message = "Database does not exist. Check the database name."
		}
	} else if errors.Is(err, context.DeadlineExceeded) || pgconn.Timeout(err) {
		response.Category, response.Message = "timeout", "Connection attempt timed out."
	} else if errors.Is(err, context.Canceled) {
		response.Category, response.Message = "cancelled", "Connection attempt was cancelled."
	}
	return response
}

func validSQLState(value string) bool {
	if len(value) != 5 {
		return false
	}
	for _, letter := range value {
		if !(letter >= '0' && letter <= '9' || letter >= 'A' && letter <= 'Z') {
			return false
		}
	}
	return true
}
