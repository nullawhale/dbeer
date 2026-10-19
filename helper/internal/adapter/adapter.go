// Package adapter defines the private database boundary. One worker exclusively
// owns each physical session; Execute must finish cancellation recovery before
// returning and Close must release the transport within a bounded interval.
package adapter

import (
	"context"

	"dbeer/helper/internal/protocol"
)

type Session interface {
	Execute(context.Context, protocol.Command) protocol.Response
	Close()
	TransactionStatus() string
}

type OpenFunc func(context.Context, protocol.Connection) (Session, error)

// ResultSink receives every row once, before display truncation. Calls are
// sequential; returning an error stops sink delivery but the adapter still
// drains server completion so the SQL outcome remains authoritative.
type ResultSink interface {
	Begin(resultIndex int, columns []protocol.Column) error
	Row(resultIndex int, values []*string) error
	End(resultIndex int, summary protocol.ResultSet) error
}

type StreamingSession interface {
	ExecuteWithSink(context.Context, protocol.Command, ResultSink) protocol.Response
}

// ConnectionError contains only a safe diagnostic and validated SQLSTATE. Raw
// driver errors and connection settings never cross the adapter boundary.
type ConnectionError struct {
	Category string
	Message  string
	SQLState string
}

func (err *ConnectionError) Error() string { return err.Message }

func Capabilities(engine string) []string {
	return []string{"execute", "cancel", "transactions", "catalog", "quoteIdentifiers"}
}
