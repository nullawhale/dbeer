package cassandra

import (
	"context"
	"errors"
	"strings"
	"sync/atomic"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/credential"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/safety"
	gocql "github.com/apache/cassandra-gocql-driver/v2"
)

type Session struct {
	adapter.TransportBinding
	driver          *gocql.Session
	stopCredentials context.CancelFunc
	keyspace        string
	cursors         map[string]browseCursor
}

func Open(ctx context.Context, connection protocol.Connection) (adapter.Session, error) {
	config, err := NewClusterConfig(connection)
	if err != nil {
		return nil, err
	}
	if connection.PasswordCommand != nil {
		config.ConnectTimeout += credential.Timeout
	}
	if err := configureTransport(ctx, connection, config); err != nil {
		return nil, err
	}
	credentialCtx, stopCredentials := context.WithCancel(context.Background())
	stopStartupCancellation := context.AfterFunc(ctx, stopCredentials)
	failures := configureCredentials(credentialCtx, connection, config)
	openingCtx, stopOpening := context.WithCancel(ctx)
	defer stopOpening()
	// ClusterConfig has bounded per-node connect deadlines but no context-aware
	// CreateSession. An abandoned result is closed by its creator, never leaked.
	ready := make(chan struct {
		driver *gocql.Session
		err    error
	})
	go func() {
		driver, err := config.CreateSession()
		select {
		case ready <- struct {
			driver *gocql.Session
			err    error
		}{driver, err}:
		case <-openingCtx.Done():
			if driver != nil {
				driver.Close()
			}
		}
	}()
	select {
	case result := <-ready:
		stopStartupCancellation()
		if ctx.Err() != nil {
			stopCredentials()
			if result.driver != nil {
				result.driver.Close()
			}
			return nil, &adapter.ConnectionError{Category: "cancelled", Message: "The Cassandra connection attempt was cancelled."}
		}
		if result.err != nil {
			stopCredentials()
			failure := safeError(protocol.Command{}, ctx, result.err, false, false)
			return nil, &adapter.ConnectionError{Category: failure.Category, Message: failure.Message}
		}
		return &Session{driver: result.driver, stopCredentials: stopCredentials, keyspace: connection.Database, cursors: make(map[string]browseCursor), TransportBinding: adapter.TransportBinding{Transport: adapter.TransportFromContext(ctx)}}, nil
	case err := <-failures:
		stopStartupCancellation()
		stopCredentials()
		return nil, err
	case <-ctx.Done():
		stopStartupCancellation()
		stopCredentials()
		return nil, &adapter.ConnectionError{Category: "timeout", Message: "The Cassandra connection attempt timed out or was cancelled."}
	}
}
func (s *Session) Close() {
	if s.stopCredentials != nil {
		s.stopCredentials()
	}
	if s.driver != nil {
		s.driver.Close()
	}
	s.cursors = nil
	s.CloseTransport()
}
func (s *Session) TransactionStatus() string { return "unsupported" }
func (s *Session) CurrentKeyspace() string   { return s.keyspace }
func (s *Session) Execute(ctx context.Context, command protocol.Command) protocol.Response {
	return s.ExecuteWithSink(ctx, command, nil)
}
func (s *Session) response(command protocol.Command) protocol.Response {
	known := false
	keyspace := s.keyspace
	return protocol.Response{Type: "query.result", RequestID: command.RequestID, SessionID: command.SessionID, QueryID: command.QueryID, Connected: true, TransactionStatus: "unsupported", AffectedRowCountKnown: &known, CurrentKeyspace: &keyspace, Columns: []protocol.Column{}, Rows: [][]*string{}}
}
func (s *Session) failure(command protocol.Command, category, message string) protocol.Response {
	response := protocol.ErrorResponse(command, category, message)
	response.Connected = true
	response.TransactionStatus = "unsupported"
	keyspace := s.keyspace
	response.CurrentKeyspace = &keyspace
	return response
}
func (s *Session) ExecuteWithSink(ctx context.Context, command protocol.Command, sink adapter.ResultSink) protocol.Response {
	started := time.Now()
	if command.Changes != nil {
		return s.complete(s.changes(ctx, command), started)
	}
	if command.Catalog != nil {
		return s.catalog(ctx, command, sink)
	}
	statements := safety.Classify("cassandra", command.SQL)
	if len(statements) == 0 || len(statements) > 1024 {
		failure := s.failure(command, "sql", "Enter between 1 and 1024 CQL statements.")
		failure.SQLNotExecuted = true
		return failure
	}
	response := s.response(command)
	budget := &displayBudget{}
	results := make([]protocol.ResultSet, 0, len(statements))
	for index, statement := range statements {
		if ctx.Err() != nil {
			failure := safeError(command, ctx, ctx.Err(), false, false)
			failure.SQLNotExecuted = index == 0
			failure.ResultSets = results
			return s.complete(failure, started)
		}
		sql := command.SQL[statement.Start:statement.End]
		var result protocol.ResultSet
		if keyspace, ok := safety.CQLKeyspace(sql); ok {
			// Resolve the exact name before publishing a new per-tab default. This does
			// not mutate any pooled physical connection's keyspace.
			var found string
			query := ConfigureQuery(s.driver.Query("SELECT keyspace_name FROM system_schema.keyspaces WHERE keyspace_name = ?", keyspace), s.keyspace)
			err := query.ScanContext(ctx, &found)
			if err != nil {
				failure := safeError(command, ctx, err, false, false)
				failure.ResultSets = results
				return s.complete(failure, started)
			}
			s.keyspace = keyspace
			s.cursors = make(map[string]browseCursor)
			known := false
			result = protocol.ResultSet{Columns: []protocol.Column{}, Rows: [][]*string{}, CommandTag: "USE", AffectedRowCountKnown: &known}
			if sink != nil && (!budget.metadataOmitted || command.Export != nil) {
				err := sink.Begin(index, result.Columns)
				if endErr := sink.End(index, result); err == nil {
					err = endErr
				}
				if err != nil {
					failure := s.deliveryFailure(command, ctx, err)
					return s.completedPrefixFailure(failure, results, result, index, len(statements), started)
				}
			}
		} else {
			if firstWord(sql) == "COMMIT" || firstWord(sql) == "ROLLBACK" || firstWord(sql) == "BEGIN" && statement.Reason != "cql_batch" {
				failure := s.failure(command, "unsupported", "Cassandra does not support SQL transactions. CQL BATCH is a separate operation.")
				failure.SQLNotExecuted = index == 0
				failure.ResultSets = results
				return s.complete(failure, started)
			}
			write := statement.Kind != safety.Read
			var failure *protocol.Response
			result, _, _, failure = s.query(ctx, command, sql, nil, index, sink, budget, command.Export != nil, false, nil, 0, write)
			if write {
				s.cursors = make(map[string]browseCursor)
			}
			if failure != nil {
				if failure.SQLCompleted {
					return s.completedPrefixFailure(*failure, results, result, index, len(statements), started)
				}
				failure.ResultSets = results
				return s.complete(*failure, started)
			}
		}
		if !budget.metadataOmitted {
			results = append(results, result)
		}
	}
	response.ResultSets = results
	if budget.metadataOmitted {
		response.Truncated = true
		response.DisplayNotice = metadataLimitNotice
	}
	if len(results) > 0 {
		r := results[0]
		response.Columns = r.Columns
		response.Rows = r.Rows
		response.CommandTag = r.CommandTag
		response.RowCount = r.RowCount
		response.DisplayedRowCount = r.DisplayedRowCount
		response.Truncated = r.Truncated || budget.metadataOmitted
		if budget.metadataOmitted {
			response.DisplayNotice = metadataLimitNotice
		} else {
			response.DisplayNotice = r.DisplayNotice
		}
		response.AffectedRowCountKnown = r.AffectedRowCountKnown
	}
	return s.complete(response, started)
}
func (s *Session) complete(response protocol.Response, started time.Time) protocol.Response {
	response.DurationMS = float64(time.Since(started)) / float64(time.Millisecond)
	response.TransactionStatus = "unsupported"
	keyspace := s.keyspace
	response.CurrentKeyspace = &keyspace
	return response
}
func firstWord(sql string) string {
	fields := strings.Fields(sql)
	if len(fields) == 0 {
		return ""
	}
	return strings.ToUpper(fields[0])
}

type attemptObserver struct {
	sent         atomic.Bool
	acknowledged atomic.Bool
}

func (o *attemptObserver) ObserveQuery(_ context.Context, q gocql.ObservedQuery) {
	if q.Host != nil {
		o.sent.Store(true)
		o.acknowledged.Store(q.Err == nil)
	}
}

func safeError(command protocol.Command, ctx context.Context, err error, write, sent bool) protocol.Response {
	response := protocol.ErrorResponse(command, "connection", "The Cassandra request failed. Check cluster connectivity and node discovery.")
	response.Connected = true
	response.TransactionStatus = "unsupported"
	// Parameter conversion happens before the data request is sent. It is a
	// local validation failure, not a lost connection or unavailable cluster.
	if errors.Is(err, errBrowse) || errors.Is(err, errBrowseType) {
		response.Category = "validation"
		response.Message = "A Cassandra value is invalid or unsupported for its column type. Check the value or use explicit CQL."
		return response
	}
	unknown := write && sent
	var request gocql.RequestError
	if errors.As(err, &request) {
		switch request.Code() {
		case gocql.ErrCodeCredentials, gocql.ErrCodeUnauthorized:
			response.Category = "authorization"
			response.Message = "Cassandra authentication or authorization failed."
			unknown = false
		case gocql.ErrCodeSyntax, gocql.ErrCodeInvalid, gocql.ErrCodeConfig, gocql.ErrCodeAlreadyExists, gocql.ErrCodeUnprepared:
			response.Category = "sql"
			response.Message = "Cassandra rejected the CQL statement. Check its syntax, object names, and query restrictions."
			unknown = false
		case gocql.ErrCodeUnavailable, gocql.ErrCodeOverloaded, gocql.ErrCodeBootstrapping:
			response.Category = "unavailable"
			response.Message = "Cassandra cannot satisfy this request at the selected consistency level."
			unknown = false
		case gocql.ErrCodeReadTimeout, gocql.ErrCodeReadFailure:
			response.Category = "timeout"
			response.Message = "The Cassandra read could not complete at the selected consistency level."
		case gocql.ErrCodeWriteTimeout, gocql.ErrCodeWriteFailure, gocql.ErrCodeCASWriteUnknown, gocql.ErrCodeCDCWriteFailure, gocql.ErrCodeTruncate:
			response.Category = "timeout"
			response.Message = "Cassandra did not confirm the write outcome."
			unknown = write
		default:
			response.Category = "sql"
			response.Message = "Cassandra could not complete the CQL request."
		}
	}
	if errors.Is(ctx.Err(), context.Canceled) {
		response.Category = "cancelled"
		response.Message = "The Cassandra request was stopped. The server may continue processing it."
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		response.Category = "timeout"
		response.Message = "The Cassandra request timed out."
	}
	response.OutcomeUnknown = unknown
	if unknown {
		response.Message += " The write outcome is unknown. Inspect the database before retrying."
	}
	return response
}

// SQLCompleted describes the entire submitted script. A confirmed current
// statement is retained even if later statements were deliberately not run.
func (s *Session) completedPrefixFailure(failure protocol.Response, prior []protocol.ResultSet, current protocol.ResultSet, index, total int, started time.Time) protocol.Response {
	failure.ResultSets = append(prior, current)
	if index+1 < total {
		failure.SQLCompleted = false
		failure.ExportPublication = ""
	}
	return s.complete(failure, started)
}
