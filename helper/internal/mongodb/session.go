package mongodb

import (
	"context"
	"errors"
	"sync/atomic"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/credential"
	"dbeer/helper/internal/mongoscript"
	"dbeer/helper/internal/protocol"
	"go.mongodb.org/mongo-driver/v2/event"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
	"go.mongodb.org/mongo-driver/v2/mongo/readpref"
)

type Session struct {
	adapter.TransportBinding
	client   *mongo.Client
	database string
	cursors  map[string]browseCursor
}

type attemptKey struct{}
type attempt struct{ sent, acknowledged atomic.Bool }

func Open(ctx context.Context, connection protocol.Connection) (adapter.Session, error) {
	opts, err := clientOptions(connection)
	if err != nil {
		return nil, err
	}
	if connection.User != "" {
		password, err := credential.Password(ctx, connection)
		if err != nil {
			return nil, err
		}
		auth := options.Credential{Username: connection.User, Password: password, PasswordSet: true, AuthSource: "admin"}
		if connection.MongoDB != nil {
			auth.AuthMechanism = connection.MongoDB.AuthMechanism
			if connection.MongoDB.AuthSource != "" {
				auth.AuthSource = connection.MongoDB.AuthSource
			}
		}
		opts.SetAuth(auth)
	}
	bindTransport(ctx, connection, opts)
	opts.SetMonitor(&event.CommandMonitor{
		Started: func(ctx context.Context, e *event.CommandStartedEvent) {
			if a, ok := ctx.Value(attemptKey{}).(*attempt); ok && e.CommandName == "aggregate" {
				a.sent.Store(true)
			}
		},
		Succeeded: func(ctx context.Context, e *event.CommandSucceededEvent) {
			if a, ok := ctx.Value(attemptKey{}).(*attempt); ok && e.CommandName == "aggregate" {
				// Command monitoring can report success for ok:1 replies that
				// still contain a write-concern error. Such writes are uncertain.
				if e.Reply.Lookup("writeConcernError").Type == 0 && e.Reply.Lookup("writeErrors").Type == 0 {
					a.acknowledged.Store(true)
				}
			}
		},
	})
	client, err := mongo.Connect(opts)
	if err == nil {
		err = client.Ping(ctx, readpref.Primary())
	}
	if err != nil {
		if client != nil {
			closeCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			_ = client.Disconnect(closeCtx)
			cancel()
		}
		failure := safeError(protocol.Command{}, ctx, err, false, nil)
		return nil, &adapter.ConnectionError{Category: failure.Category, Message: failure.Message}
	}
	return &Session{client: client, database: connection.Database, cursors: make(map[string]browseCursor), TransportBinding: adapter.TransportBinding{Transport: adapter.TransportFromContext(ctx)}}, nil
}

func (s *Session) Close() {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	s.clearCursors(ctx)
	if s.client != nil {
		_ = s.client.Disconnect(ctx)
	}
	s.CloseTransport()
}
func (*Session) TransactionStatus() string { return "unsupported" }
func (s *Session) Execute(ctx context.Context, command protocol.Command) protocol.Response {
	return s.ExecuteWithSink(ctx, command, nil)
}
func (s *Session) failure(command protocol.Command, category, message string) protocol.Response {
	r := protocol.ErrorResponse(command, category, message)
	r.Connected = true
	r.TransactionStatus = "unsupported"
	return r
}
func (s *Session) ExecuteWithSink(ctx context.Context, command protocol.Command, sink adapter.ResultSink) protocol.Response {
	started := time.Now()
	var response protocol.Response
	switch {
	case command.Changes != nil:
		response = s.failure(command, "unsupported", "MongoDB document editing is not supported.")
		response.SQLNotExecuted = true
	case command.Catalog != nil:
		response = s.catalog(ctx, command, sink)
	default:
		script, err := mongoscript.Parse(command.SQL)
		if err != nil {
			response = s.failure(command, "validation", err.Error())
			response.SQLNotExecuted = true
			break
		}
		if script.Database == "" {
			script.Database = s.database
		}
		if !mongoscript.ValidName(script.Database) {
			response = s.failure(command, "validation", "Select a database in the connection or the MongoDB JSON script.")
			response.SQLNotExecuted = true
			break
		}
		a := &attempt{}
		queryCtx := context.WithValue(ctx, attemptKey{}, a)
		cursor, err := s.openCursor(queryCtx, script)
		if err != nil {
			response = safeError(command, ctx, err, script.Write, a)
			break
		}
		defer closeCursor(cursor)
		tag := "FIND"
		if script.Aggregate {
			tag = "AGGREGATE"
		}
		result, err := readDocuments(queryCtx, cursor, sink, command.Export != nil, 1000, tag)
		if err != nil {
			response = safeError(command, ctx, err, script.Write, a)
			if script.Write && a.acknowledged.Load() {
				response.SQLCompleted = true
				response.Category = "result"
				response.Message = "MongoDB confirmed the output pipeline, but local result delivery stopped."
			}
			break
		}
		response = resultResponse(command, result)
	}
	response.DurationMS = float64(time.Since(started)) / float64(time.Millisecond)
	response.TransactionStatus = "unsupported"
	return response
}

func (s *Session) openCursor(ctx context.Context, script mongoscript.Script) (*mongo.Cursor, error) {
	collection := s.client.Database(script.Database).Collection(script.Collection)
	if script.Aggregate {
		return collection.Aggregate(ctx, script.Pipeline, options.Aggregate().SetBatchSize(200).SetAllowDiskUse(false))
	}
	opts := options.Find().SetBatchSize(200)
	if len(script.Sort) > 0 {
		opts.SetSort(script.Sort)
	}
	if len(script.Projection) > 0 {
		opts.SetProjection(script.Projection)
	}
	if script.Limit > 0 {
		opts.SetLimit(script.Limit)
	}
	return collection.Find(ctx, script.Filter, opts)
}

func closeCursor(cursor *mongo.Cursor) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_ = cursor.Close(ctx)
}

func safeError(command protocol.Command, ctx context.Context, err error, write bool, a *attempt) protocol.Response {
	r := protocol.ErrorResponse(command, "connection", "The MongoDB request failed. Check connectivity and server availability.")
	r.Connected, r.TransactionStatus = true, "unsupported"
	unknown := write && a != nil && a.sent.Load() && !a.acknowledged.Load()
	var server mongo.CommandError
	if errors.As(err, &server) {
		r.Category, r.Message = "query", "MongoDB rejected the request. Check collection names, operators, types, and access permissions."
		if server.Code == 13 || server.Code == 18 {
			r.Category, r.Message = "authorization", "MongoDB authentication or authorization failed."
			unknown = false
		}
		// Rejections before any stage can run have a definite no-write outcome.
		switch server.Code {
		case 9, 59, 168, 40324:
			unknown = false
		}
	}
	var concern mongo.WriteConcernError
	if errors.As(err, &concern) {
		r.Category, r.Message = "writeConcern", "MongoDB did not confirm the requested write acknowledgement."
		unknown = write
	}
	if errors.Is(err, errDocumentLimit) {
		r.Category, r.Message = "result", "A MongoDB document exceeds the interactive result limit. Use Run to File to retain complete documents."
	}
	if mongo.IsTimeout(err) || errors.Is(ctx.Err(), context.DeadlineExceeded) {
		r.Category, r.Message = "timeout", "The MongoDB request timed out."
	}
	if errors.Is(ctx.Err(), context.Canceled) {
		r.Category, r.Message = "cancelled", "The MongoDB request was stopped."
	}
	r.OutcomeUnknown = unknown
	if unknown {
		r.Message += " The write outcome is unknown. Inspect the output collection before retrying."
	}
	return r
}
