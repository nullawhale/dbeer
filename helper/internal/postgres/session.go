package postgres

import (
	"context"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
)

// PrepareEnvironment is called once by the dedicated helper before starting
// concurrent session workers. Open never mutates the process environment.
func PrepareEnvironment() { clearPostgresEnvironment() }

type Session struct {
	adapter.TransportBinding
	conn *pgx.Conn
}

func Open(ctx context.Context, connection protocol.Connection) (adapter.Session, error) {
	conn, err := connect(ctx, connection)
	if err != nil {
		response := connectionError(protocol.Command{}, err)
		return nil, &adapter.ConnectionError{Category: response.Category, Message: response.Message, SQLState: response.SQLState}
	}
	return &Session{conn: conn, TransportBinding: adapter.TransportBinding{Transport: adapter.TransportFromContext(ctx)}}, nil
}

func (session *Session) Execute(ctx context.Context, command protocol.Command) protocol.Response {
	if command.Changes != nil {
		return changes(ctx, session.conn, command)
	}
	if command.Catalog != nil {
		return catalog(ctx, session.conn, command)
	}
	return execute(ctx, session.conn, command)
}

func (session *Session) ExecuteWithSink(ctx context.Context, command protocol.Command, sink adapter.ResultSink) protocol.Response {
	if command.Changes != nil {
		return changes(ctx, session.conn, command)
	}
	if command.Catalog != nil {
		return catalogWithSink(ctx, session.conn, command, sink)
	}
	if startsWithCopy(command.SQL) {
		return execute(ctx, session.conn, command)
	}
	return executeParamsSink(ctx, session.conn, command, command.SQL, nil, sink)
}

func (session *Session) Close() {
	closeConnection(session.conn)
	session.CloseTransport()
}

func (session *Session) TransactionStatus() string { return transactionStatus(session.conn) }
