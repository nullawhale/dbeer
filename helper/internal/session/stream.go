package session

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/exportfile"
	"dbeer/helper/internal/protocol"
)

const displayRows = 1000
const displayBytes = 8 * 1024 * 1024
const chunkTarget = 64 * 1024

type creditState struct {
	owner    *owner
	command  protocol.Command
	mu       sync.Mutex
	sequence int
	expected int
	credit   chan struct{}
}

func newCreditState(owner *owner, command protocol.Command) *creditState {
	return &creditState{owner: owner, command: command, credit: make(chan struct{}, 1)}
}

func (state *creditState) ack(sequence int) bool {
	state.mu.Lock()
	defer state.mu.Unlock()
	if sequence < 1 || sequence > state.sequence {
		return false
	}
	if sequence != state.expected {
		return true
	} // stale ACK never grants credit twice.
	state.expected = 0
	select {
	case state.credit <- struct{}{}:
	default:
	}
	return true
}

func (state *creditState) send(ctx context.Context, index int, columns []protocol.Column, rows [][]*string) (bool, error) {
	state.mu.Lock()
	state.sequence++
	sequence := state.sequence
	state.expected = sequence
	state.mu.Unlock()
	response := protocol.Response{Type: "query.chunk", RequestID: state.command.RequestID, SessionID: state.command.SessionID, QueryID: state.command.QueryID, Sequence: sequence, ResultIndex: index, Columns: columns, Rows: rows}
	select {
	case state.owner.manager.events <- event{sessionID: state.owner.id, response: response}:
	case <-ctx.Done():
		return false, ctx.Err()
	case <-state.owner.manager.stop:
		return false, context.Canceled
	}
	select {
	case <-state.credit:
		return true, nil
	case <-ctx.Done():
		return true, ctx.Err()
	case <-state.owner.manager.stop:
		return true, context.Canceled
	}
}

type streamSet struct {
	columns    []protocol.Column
	summary    protocol.ResultSet
	batch      [][]*string
	batchBytes int
	sent       int
	seen       int64
	dropped    bool
	ended      bool
}

type streamSink struct {
	ctx    context.Context
	credit *creditState
	sets   []*streamSet
	bytes  int
	rows   int
	err    error
}

func (sink *streamSink) Begin(index int, columns []protocol.Column) error {
	if sink.err != nil {
		return sink.err
	}
	if index != len(sink.sets) || index >= 1024 {
		sink.err = errors.New("Invalid result sequence.")
		return sink.err
	}
	encoded, _ := json.Marshal(columns)
	set := &streamSet{columns: append([]protocol.Column{}, columns...)}
	if sink.bytes+len(encoded)+1024 > displayBytes {
		set.columns = []protocol.Column{}
		set.dropped = true
	} else {
		sink.bytes += len(encoded) + 1024
	}
	sink.sets = append(sink.sets, set)
	_, sink.err = sink.credit.send(sink.ctx, index, set.columns, nil)
	return sink.err
}

func (sink *streamSink) Row(index int, row []*string) error {
	if index < 0 || index >= len(sink.sets) {
		return errors.New("Invalid result sequence.")
	}
	set := sink.sets[index]
	set.seen++
	if sink.err != nil {
		return sink.err
	}
	if set.dropped || sink.rows >= displayRows {
		set.dropped = true
		return nil
	}
	encoded, _ := json.Marshal(row)
	if sink.bytes+len(encoded)+1 > displayBytes {
		set.dropped = true
		return nil
	}
	if set.batchBytes+len(encoded) > chunkTarget && len(set.batch) > 0 {
		if err := sink.flush(index); err != nil {
			return err
		}
	}
	set.batch = append(set.batch, row)
	set.batchBytes += len(encoded) + 1
	sink.bytes += len(encoded) + 1
	sink.rows++
	if set.batchBytes >= chunkTarget {
		return sink.flush(index)
	}
	return nil
}

func (sink *streamSink) flush(index int) error {
	set := sink.sets[index]
	if len(set.batch) == 0 {
		return sink.err
	}
	queued, err := sink.credit.send(sink.ctx, index, nil, set.batch)
	if queued {
		set.sent += len(set.batch)
	} else {
		set.dropped = true
	}
	set.batch = nil
	set.batchBytes = 0
	if err != nil {
		sink.err = err
	}
	return err
}

func (sink *streamSink) End(index int, summary protocol.ResultSet) error {
	if index < 0 || index >= len(sink.sets) {
		return errors.New("Invalid result sequence.")
	}
	set := sink.sets[index]
	err := sink.flush(index)
	set.ended = true
	set.summary = summary
	set.summary.Columns, set.summary.Rows = set.columns, nil
	set.summary.DisplayedRowCount = set.sent
	set.summary.Truncated = summary.Truncated && strings.Contains(summary.DisplayNotice, "Cassandra") || set.dropped || int64(set.sent) < set.seen
	if summary.Truncated && !set.summary.Truncated {
		set.summary.DisplayNotice = strings.TrimSpace(strings.ReplaceAll(set.summary.DisplayNotice, "Result display is limited to 1000 rows and 8 MiB. The command completed in full.", ""))
	}
	if set.summary.Truncated && !strings.Contains(set.summary.DisplayNotice, "Cassandra") {
		set.summary.DisplayNotice = "Result display is limited to 1000 rows and 8 MiB. The command completed in full."
	}
	return err
}

func (sink *streamSink) finish(response protocol.Response) protocol.Response {
	response.Streamed = true
	response.ResultSets = []protocol.ResultSet{}
	first := true
	for _, set := range sink.sets {
		if !set.ended {
			break
		}
		if first && (len(set.columns) > 0 || len(sink.sets) == 1) {
			notice := response.DisplayNotice
			if !set.summary.Truncated {
				notice = strings.TrimSpace(strings.ReplaceAll(notice, "Result display is limited to 1000 rows and 8 MiB. The command completed in full.", ""))
			}
			if notice != "" && !strings.Contains(set.summary.DisplayNotice, notice) {
				set.summary.DisplayNotice = strings.TrimSpace(set.summary.DisplayNotice + " " + notice)
			}
			response.DisplayedRowCount = set.summary.DisplayedRowCount
			if response.TransactionStatus == "unsupported" {
				response.Truncated = response.Truncated || set.summary.Truncated
			} else {
				response.Truncated = set.summary.Truncated
			}
			response.DisplayNotice = set.summary.DisplayNotice
			response.NextCursor = set.summary.NextCursor
			response.AffectedRowCountKnown = set.summary.AffectedRowCountKnown
			first = false
		}
		response.ResultSets = append(response.ResultSets, set.summary)
	}
	response.Columns, response.Rows = nil, nil
	return response
}

type fanoutSink []adapter.ResultSink

func (sinks fanoutSink) Begin(index int, columns []protocol.Column) error {
	var first error
	for _, sink := range sinks {
		if err := sink.Begin(index, columns); err != nil && first == nil {
			first = err
		}
	}
	return first
}
func (sinks fanoutSink) Row(index int, row []*string) error {
	var first error
	for _, sink := range sinks {
		if err := sink.Row(index, row); err != nil && first == nil {
			first = err
		}
	}
	return first
}
func (sinks fanoutSink) End(index int, summary protocol.ResultSet) error {
	var first error
	for _, sink := range sinks {
		if err := sink.End(index, summary); err != nil && first == nil {
			first = err
		}
	}
	return first
}

// Full export progress has no display budget and grants no stream credit or completion.
// The bounded manager event queue provides backpressure; counts contain no SQL or values.
type exportProgressSink struct {
	ctx    context.Context
	credit *creditState
	rows   int64
}

func (sink *exportProgressSink) send(index int) error {
	sink.credit.mu.Lock()
	sink.credit.sequence++
	sequence := sink.credit.sequence
	sink.credit.expected = sequence
	sink.credit.mu.Unlock()
	response := protocol.Response{Sequence: sequence, Type: "query.progress", RequestID: sink.credit.command.RequestID, SessionID: sink.credit.command.SessionID, QueryID: sink.credit.command.QueryID, ResultIndex: index, RowCount: sink.rows}
	select {
	case sink.credit.owner.manager.events <- event{sessionID: sink.credit.owner.id, response: response}:
	case <-sink.ctx.Done():
		return sink.ctx.Err()
	case <-sink.credit.owner.manager.stop:
		return context.Canceled
	}
	select {
	case <-sink.credit.credit:
		return nil
	case <-sink.ctx.Done():
		return sink.ctx.Err()
	case <-sink.credit.owner.manager.stop:
		return context.Canceled
	}
}
func (sink *exportProgressSink) Begin(index int, columns []protocol.Column) error { return nil }
func (sink *exportProgressSink) Row(index int, row []*string) error {
	sink.rows++
	if sink.rows%4096 == 0 {
		return sink.send(index)
	}
	return nil
}
func (sink *exportProgressSink) End(index int, summary protocol.ResultSet) error {
	return sink.send(index)
}

func runExecution(ctx context.Context, physical adapter.Session, command protocol.Command, credit *creditState) protocol.Response {
	if !command.Stream && command.Export == nil {
		return physical.Execute(ctx, command)
	}
	streaming, ok := physical.(adapter.StreamingSession)
	if !ok {
		if command.Export == nil {
			return physical.Execute(ctx, command)
		}
		failure := protocol.ErrorResponse(command, "export", "This database adapter cannot export complete executions.")
		failure.Connected, failure.TransactionStatus = true, physical.TransactionStatus()
		failure.SQLNotExecuted, failure.ExportPublication = true, "notPublished"
		return failure
	}
	var sinks fanoutSink
	var display *streamSink
	if command.Stream {
		display = &streamSink{ctx: ctx, credit: credit}
		sinks = append(sinks, display)
	}
	var file *exportfile.Writer
	if command.Export != nil {
		var err error
		file, err = exportfile.New(*command.Export)
		if err != nil {
			failure := protocol.ErrorResponse(command, "export", "The export file could not be created. SQL was not executed.")
			failure.Connected, failure.TransactionStatus = true, physical.TransactionStatus()
			failure.SQLNotExecuted, failure.ExportPublication = true, "notPublished"
			return failure
		}
		defer file.Abort()
		stopCleanup := file.CancelOn(ctx)
		defer stopCleanup()
		sinks = append(sinks, file)
		if command.Stream {
			sinks = append(sinks, &exportProgressSink{ctx: ctx, credit: credit})
		}
	}
	response := streaming.ExecuteWithSink(ctx, command, sinks)
	if file != nil && response.Type == "query.result" {
		if ctx.Err() != nil {
			failure := protocol.ErrorResponse(command, "cancelled", "Export was cancelled; no final file was saved. SQL completion was confirmed.")
			failure.Connected, failure.TransactionStatus = true, response.TransactionStatus
			failure.SQLCompleted, failure.ExportPublication = true, "notPublished"
			response = failure
		} else if err := file.CommitContext(ctx); err != nil {
			failure := protocol.ErrorResponse(command, "export", "SQL completed, but export failed. No final file was saved. "+err.Error())
			if errors.Is(err, exportfile.ErrCancelled) || ctx.Err() != nil {
				failure.Category, failure.Message = "cancelled", "Export was cancelled; no final file was saved. SQL completion was confirmed."
			}
			failure.Connected, failure.TransactionStatus = true, response.TransactionStatus
			failure.SQLCompleted, failure.ExportPublication = true, "notPublished"
			if errors.Is(err, exportfile.ErrPublicationUnknown) {
				failure.ExportPublication = "unknown"
				failure.Message = "SQL completed, but file publication could not be verified. Inspect the destination. Do not rerun SQL to recover the save."
			}
			failure.ResultSets = response.ResultSets
			response = failure
		} else {
			response.ExportPath, response.ExportFormat, response.ExportRowCount = command.Export.Path, command.Export.Format, file.RowCount()
		}
	}
	if display != nil {
		response = display.finish(response)
	}
	return response
}
