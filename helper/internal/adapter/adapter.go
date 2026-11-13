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

// NativeResultSink receives the same captured row immediately before Row.
// Existing display-only sinks remain valid; durable and streaming sinks retain it.
type NativeResultSink interface {
	NativeRow(resultIndex int, values []protocol.NativeValue) error
}

func DeliverNativeRow(sink ResultSink, index int, values []protocol.NativeValue) error {
	if typed, ok := sink.(NativeResultSink); ok {
		return typed.NativeRow(index, values)
	}
	return nil
}

type StreamingSession interface {
	ExecuteWithSink(context.Context, protocol.Command, ResultSink) protocol.Response
}

// SessionMonitor reads a fixed, bounded observation through a dedicated readonly
// physical session. User SQL is never accepted on this adapter boundary.
type SessionMonitor interface {
	MonitorSnapshot(context.Context, protocol.Command) protocol.Response
}

// ReadOnlySession changes the physical session's default transaction access
// mode. The owner must serialize this with Execute, and must not change policy
// while a transaction is open. SQL assessment is still required: database
// read-only modes have exceptions and may be overridden by user SQL.
type ReadOnlySession interface {
	SetReadOnly(context.Context, bool) error
}

// ReadOnlyOperationSession recognizes session-local operations whose adapter
// enforces readonly access to every target, including additional files.
type ReadOnlyOperationSession interface {
	IsReadOnlyOperation(protocol.OperationRequest) bool
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
	common := []string{"execute", "cancel", "catalog", "quoteIdentifiers", "executionPolicy", "operationAssessment", protocol.NativeResultValuesCapability, protocol.BrowseFilterTreeCapability}
	switch engine {
	case "sqlite":
		return append(common, "transactions", "gridEditing", "serverReadOnly", "tableStructureEditorV1", protocol.StructureAuthoringCapability, protocol.QueryParametersCapability, protocol.TableImportCapability, protocol.SQLiteCellFilterCapability, protocol.NativeCellFilterCapability, protocol.CatalogColumnTypesCapability, protocol.SQLiteRelationshipBrowseCapability, protocol.IncomingRelationsCapability)
	case "mongodb":
		return append(common, "localReadOnly", "cursorPagination", "documentModelV1", "canonicalExtendedJSONV1")
	case "cassandra":
		return append(common, "localReadOnly", "cursorPagination", "gridEditing")
	case "", "postgresql", "mysql":
		return append(common, "transactions", "gridEditing", "serverReadOnly", "resultSourceV1", "tableStructureEditorV1", protocol.StructureAuthoringCapability, protocol.QueryParametersCapability, protocol.TableImportCapability, protocol.SessionMonitorCapability, protocol.NativeCellFilterCapability, protocol.CatalogColumnTypesCapability, protocol.IncomingRelationsCapability)
	default:
		return nil
	}
}
