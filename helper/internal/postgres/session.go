package postgres

import (
	"context"
	"github.com/jackc/pgx/v5/pgconn"
	"strings"
	"sync/atomic"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
)

// PrepareEnvironment is called once by the dedicated helper before starting
// concurrent session workers. Open never mutates the process environment.
func PrepareEnvironment() { clearPostgresEnvironment() }

type Session struct {
	adapter.TransportBinding
	conn                       *pgx.Conn
	schemaObservationListening bool
	schemaObservationRevision  *atomic.Uint64
	explainIdentity            string
	afterStructureStep         func(int)
	structureCommitOverride    func(func() error) error
}

func Open(ctx context.Context, connection protocol.Connection) (adapter.Session, error) {
	var revision *atomic.Uint64
	var notification func(*pgconn.Notification)
	if connection.SessionPurpose == "monitor" {
		revision = &atomic.Uint64{}
		notification = func(event *pgconn.Notification) {
			if event.Channel == "dbeer_schema_watch_v1" {
				revision.Add(1)
			}
		}
	}
	conn, err := connectWithNotifications(ctx, connection, notification)
	if err != nil {
		response := connectionError(protocol.Command{}, err)
		return nil, &adapter.ConnectionError{Category: response.Category, Message: response.Message, SQLState: response.SQLState}
	}
	var identity string
	_ = conn.QueryRow(ctx, "SELECT pg_catalog.version()").Scan(&identity)
	return &Session{conn: conn, schemaObservationRevision: revision, explainIdentity: identity, TransportBinding: adapter.TransportBinding{Transport: adapter.TransportFromContext(ctx)}}, nil
}

func (session *Session) Execute(ctx context.Context, command protocol.Command) protocol.Response {
	if strings.HasPrefix(command.Type, "import.") {
		return tableImport(ctx, session.conn, command)
	}
	if command.Changes != nil {
		return changes(ctx, session.conn, command)
	}
	if command.Catalog != nil {
		return catalog(ctx, session.conn, command)
	}
	return execute(ctx, session.conn, command)
}

func (session *Session) ExecuteWithSink(ctx context.Context, command protocol.Command, sink adapter.ResultSink) protocol.Response {
	if strings.HasPrefix(command.Type, "import.") {
		return tableImport(ctx, session.conn, command)
	}
	if command.Changes != nil {
		return changes(ctx, session.conn, command)
	}
	if command.Catalog != nil {
		return catalogWithSink(ctx, session.conn, command, sink)
	}
	if startsWithCopy(command.SQL) {
		return execute(ctx, session.conn, command)
	}
	return executeNamedParameters(ctx, session.conn, command, sink)
}

func (session *Session) Close() {
	closeConnection(session.conn)
	session.CloseTransport()
}

func (session *Session) TransactionStatus() string { return transactionStatus(session.conn) }
