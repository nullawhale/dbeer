package cassandra

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/exportfile"
	"dbeer/helper/internal/protocol"
	gocql "github.com/apache/cassandra-gocql-driver/v2"
)

const maxRows = 1000
const maxBytes = 8 * 1024 * 1024
const pageRows = 200

// Reserve space for bounded script summaries, notices, and response framing.
// The top-level first result is also duplicated by the existing wire contract;
// a <=8 MiB accumulator therefore remains safely below the 16 MiB frame cap.
const retainedDataBytes = maxBytes - 1024*1024
const metadataLimitNotice = "Cassandra script display limit reached. Later result metadata was omitted; additional interactive read pages were not fetched. Explicit exports retain the complete data."

type displayBudget struct {
	rows, bytes     int
	metadataOmitted bool
}

func (budget *displayBudget) retainColumns(columns []protocol.Column) bool {
	if budget.metadataOmitted {
		return false
	}
	encoded, _ := json.Marshal(columns)
	if budget.bytes+len(encoded)+512 > retainedDataBytes {
		budget.metadataOmitted = true
		return false
	}
	budget.bytes += len(encoded) + 512
	return true
}

// query fetches server pages explicitly. A completed driver request is distinct
// from local decoding/delivery: failures after acknowledgement never turn a
// confirmed write into an uncertain write, and never trigger a retry.
func (s *Session) query(ctx context.Context, command protocol.Command, sql string, values []any, index int, sink adapter.ResultSink, budget *displayBudget, full, onePage bool, page []byte, skip int, write bool) (protocol.ResultSet, []byte, int, *protocol.Response) {
	known := false
	result := protocol.ResultSet{Columns: []protocol.Column{}, Rows: [][]*string{}, CommandTag: firstWord(sql), AffectedRowCountKnown: &known}
	begun, retained, sendSink := false, false, false
	var observer *attemptObserver
	failure := func(err error) *protocol.Response {
		sent := observer != nil && observer.sent.Load()
		response := safeError(command, ctx, err, write, sent)
		return &response
	}
	for {
		if ctx.Err() != nil {
			observer = nil
			return result, nil, 0, failure(ctx.Err())
		}
		observer = &attemptObserver{}
		query := ConfigureQuery(s.driver.Query(sql, values...), s.keyspace).NoSkipMetadata().PageSize(pageRows).PageState(page).Observer(observer)
		iter := query.IterContext(ctx)
		columns := iter.Columns()
		numRows := iter.NumRows()
		// Server errors have no result metadata. Check them before exposing a result
		// sink, so local delivery cannot hide a real lost-response error.
		if numRows == 0 && len(columns) == 0 {
			if err := iter.Close(); err != nil {
				return result, nil, 0, failure(err)
			}
		}
		var deliveryErr error
		finishDeliveryFailure := func(err error) (protocol.ResultSet, []byte, int, *protocol.Response) {
			result.Truncated = true
			result.DisplayedRowCount = len(result.Rows)
			result.DisplayNotice = "Cassandra confirmed execution, but its result could not be delivered completely."
			if sendSink {
				_ = sink.End(index, result)
			}
			response := s.deliveryFailure(command, ctx, err)
			return result, nil, 0, &response
		}
		var completeColumns []protocol.Column
		if !begun {
			completeColumns = make([]protocol.Column, 0, len(columns))
			for i, column := range columns {
				encoding := ""
				if binaryCQLType(column.TypeInfo) {
					encoding = "base64"
				}
				completeColumns = append(completeColumns, protocol.Column{Index: i, Name: column.Name, Engine: "cassandra", NativeType: typeName(column.TypeInfo), TypeIdentity: cassandraResultTypeIdentity(column.TypeInfo), Encoding: encoding})
			}
			retained = budget.retainColumns(completeColumns)
			if retained {
				result.Columns = completeColumns
			} else {
				result.Truncated = true
				result.DisplayNotice = metadataLimitNotice
			}
			// A complete export receives full metadata even when display metadata is
			// omitted. Interactive sinks receive only the retained result prefix.
			sendSink = sink != nil && (retained || full)
			if sendSink {
				sinkColumns := result.Columns
				if full {
					sinkColumns = completeColumns
				}
				deliveryErr = sink.Begin(index, sinkColumns)
			}
			begun = true
		}
		if !retained && !full {
			if err := iter.Close(); err != nil {
				return result, nil, 0, failure(err)
			}
			result.DisplayedRowCount = 0
			return result, nil, 0, nil
		}
		raw := make([]rawValue, len(columns))
		dest := make([]any, 0, len(columns))
		extra := 0
		for i, column := range columns {
			if tuple, ok := column.TypeInfo.(gocql.TupleTypeInfo); ok {
				extra += len(tuple.Elems) - 1
				columns[i].TypeInfo = wholeTuple{column.TypeInfo}
			}
			dest = append(dest, &raw[i])
		}
		for i := 0; i < extra; i++ {
			dest = append(dest, nil)
		}
		scanned, resumeSkip := 0, 0
		stopped := false
		for iter.Scan(dest...) {
			scanned++
			if scanned <= skip {
				continue
			}
			if ctx.Err() != nil && deliveryErr == nil {
				deliveryErr = ctx.Err()
			}
			row := make([]*string, len(raw))
			for i, v := range raw {
				var err error
				row[i], err = renderValue(v.info, v.data, false)
				if err != nil {
					_ = iter.Close()
					result.RowCount += int64(numRows - scanned + 1)
					return finishDeliveryFailure(err)
				}
			}
			encoded, _ := json.Marshal(row)
			fits := retained && budget.rows < maxRows && budget.bytes+len(encoded)+1 <= retainedDataBytes
			if !full && !fits && deliveryErr == nil {
				result.Truncated = true
				stopped = true
				resumeSkip = scanned - 1
				break
			}
			result.RowCount++
			if fits {
				result.Rows = append(result.Rows, row)
				budget.rows++
				budget.bytes += len(encoded) + 1
			} else {
				result.Truncated = true
			}
			if sendSink && deliveryErr == nil {
				deliveryErr = sink.Row(index, row)
			}
			if !full && budget.rows >= maxRows && deliveryErr == nil {
				stopped = true
				resumeSkip = scanned
				break
			}
		}
		next := append([]byte(nil), iter.PageState()...)
		if err := iter.Close(); err != nil {
			if observer.acknowledged.Load() {
				return finishDeliveryFailure(err)
			}
			return result, nil, 0, failure(err)
		}
		if deliveryErr != nil {
			return finishDeliveryFailure(deliveryErr)
		}
		if stopped {
			if resumeSkip < numRows {
				next = append([]byte(nil), page...)
			} else {
				resumeSkip = 0
			}
			if resumeSkip > 0 || len(next) > 0 {
				result.Truncated = true
			}
			if !onePage {
				next = nil
				resumeSkip = 0
			}
			finishQueryResult(&result, full)
			if sendSink && !onePage {
				if err := sink.End(index, result); err != nil {
					return finishDeliveryFailure(err)
				}
			}
			return result, next, resumeSkip, nil
		}
		if onePage || len(next) == 0 {
			finishQueryResult(&result, full)
			if sendSink && !onePage {
				if err := sink.End(index, result); err != nil {
					return finishDeliveryFailure(err)
				}
			}
			return result, next, 0, nil
		}
		if !full && (budget.rows >= maxRows || budget.bytes >= retainedDataBytes) {
			result.Truncated = true
			finishQueryResult(&result, full)
			if sendSink && !onePage {
				if err := sink.End(index, result); err != nil {
					return finishDeliveryFailure(err)
				}
			}
			return result, nil, 0, nil
		}
		page = next
		skip = 0
	}
}
func (s *Session) deliveryFailure(command protocol.Command, ctx context.Context, err error) protocol.Response {
	response := s.failure(command, "result", "The current Cassandra statement completed, but result decoding or delivery failed. Remaining script statements were not executed.")
	response.SQLCompleted = true
	if command.Export != nil {
		response.Category = "export"
		response.ExportPublication = "notPublished"
		response.Message = "The current Cassandra statement completed, but the export failed. No final file was saved. Remaining script statements were not executed."
		if errors.Is(err, exportfile.ErrNullCollision) {
			response.Message += " A text value equals the selected CSV NULL marker."
		}
		if errors.Is(err, exportfile.ErrMultipleResults) {
			response.Message += " CSV cannot represent multiple result sets; choose JSON."
		}
	}
	if errors.Is(ctx.Err(), context.Canceled) {
		response.Category = "cancelled"
		response.Message = "The current Cassandra statement completed, but result delivery was stopped. Remaining script statements were not executed."
		if command.Export != nil {
			response.Message += " No final export file was saved."
		}
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		response.Category = "timeout"
		response.Message = "The current Cassandra statement completed, but result delivery timed out. Remaining script statements were not executed."
		if command.Export != nil {
			response.Message += " No final export file was saved."
		}
	}
	return response
}
func finishQueryResult(result *protocol.ResultSet, full bool) {
	result.DisplayedRowCount = len(result.Rows)
	if result.Truncated {
		result.DisplayNotice = "Result display is limited to 1000 rows and 8 MiB. Additional Cassandra pages were not fetched."
		if full {
			result.DisplayNotice = "Result display is limited to 1000 rows and 8 MiB. The complete Cassandra result was read for export."
		}
	}
	if !strings.EqualFold(result.CommandTag, "SELECT") && len(result.Columns) == 0 {
		result.DisplayNotice = "Cassandra confirmed completion; an affected-row count is unavailable."
	}
}
