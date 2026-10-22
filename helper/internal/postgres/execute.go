package postgres

import (
	"context"
	"dbeer/helper/internal/adapter"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

const ExecuteTimeout = 30 * time.Second
const MaxResultRows = 1000
const MaxResultBytes = 8 * 1024 * 1024

// execute runs on the connection's exclusive worker. In particular Close drains
// ReadyForQuery and waits for the cancellation watcher before the actor may
// reuse or close the connection. The watcher sends server CancelRequest and has
// a five-second socket deadline as its recovery fallback.
func execute(ctx context.Context, conn *pgx.Conn, command protocol.Command) protocol.Response {
	if startsWithCopy(command.SQL) {
		response := protocol.ErrorResponse(command, "sql", "COPY is not supported by this prototype.")
		response.Connected, response.TransactionStatus = true, transactionStatus(conn)
		response.SQLNotExecuted = true
		return response
	}
	return executeParams(ctx, conn, command, command.SQL, nil)
}

func executeParams(ctx context.Context, conn *pgx.Conn, command protocol.Command, sql string, values [][]byte) protocol.Response {
	return executeParamsSink(ctx, conn, command, sql, values, nil)
}

func executeParamsSink(ctx context.Context, conn *pgx.Conn, command protocol.Command, sql string, values [][]byte, sink adapter.ResultSink) protocol.Response {
	started := time.Now()
	if ctx.Err() != nil {
		category, message := "cancelled", "Execution was cancelled before it started."
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			category, message = "timeout", "Execution timed out before it started."
		}
		failure := protocol.ErrorResponse(command, category, message)
		failure.SQLNotExecuted = command.Type == "execute"
		failure.Connected, failure.TransactionStatus = !conn.IsClosed(), transactionStatus(conn)
		return failure
	}
	reader := conn.PgConn().ExecParams(ctx, sql, values, nil, nil, nil)
	collector := newResultCollector(command, reader.FieldDescriptions(), MaxResultBytes)
	for index, field := range reader.FieldDescriptions() {
		if nativeType, ok := conn.TypeMap().TypeForOID(field.DataTypeOID); ok {
			collector.response.Columns[index].NativeType = nativeType.Name
		}
		if field.DataTypeOID == 17 {
			collector.response.Columns[index].Encoding = "base64"
		}
	}
	sinkOK := sink != nil
	if sinkOK && sink.Begin(0, collector.response.Columns) != nil {
		sinkOK = false
	}
	var binaryError bool
	for reader.NextRow() {
		row := make([]*string, len(reader.Values()))
		for index, value := range reader.Values() {
			if value == nil {
				continue
			}
			text := string(value)
			if collector.response.Columns[index].Encoding == "base64" {
				decoded, err := decodeBytea(value)
				if err != nil {
					binaryError = true
					continue
				}
				text = base64.StdEncoding.EncodeToString(decoded)
			}
			row[index] = &text
		}
		collector.addRow(row)
		if sinkOK && sink.Row(0, row) != nil {
			sinkOK = false
		}
	}
	tag, err := reader.Close()
	if err != nil {
		return queryError(command, ctx, conn, err)
	}
	response := collector.finish(tag, time.Since(started), transactionStatus(conn))
	if binaryError {
		failure := protocol.ErrorResponse(command, "result", "The command completed, but PostgreSQL binary data could not be decoded.")
		failure.Connected, failure.TransactionStatus = true, response.TransactionStatus
		return failure
	}
	if sinkOK {
		_ = sink.End(0, protocol.ResultSet{Columns: response.Columns, Rows: [][]*string{}, CommandTag: response.CommandTag, RowCount: response.RowCount, DisplayedRowCount: response.DisplayedRowCount, Truncated: response.Truncated, DisplayNotice: response.DisplayNotice})
	}
	return response
}

func decodeBytea(value []byte) ([]byte, error) {
	if len(value) >= 2 && value[0] == '\\' && value[1] == 'x' {
		return hex.DecodeString(string(value[2:]))
	}
	decoded := make([]byte, 0, len(value))
	for index := 0; index < len(value); index++ {
		if value[index] != '\\' {
			decoded = append(decoded, value[index])
			continue
		}
		if index+1 < len(value) && value[index+1] == '\\' {
			decoded = append(decoded, '\\')
			index++
			continue
		}
		if index+3 >= len(value) {
			return nil, errors.New("invalid binary value")
		}
		var code byte
		for digit := 1; digit <= 3; digit++ {
			ch := value[index+digit]
			if ch < '0' || ch > '7' {
				return nil, errors.New("invalid binary value")
			}
			code = code*8 + ch - '0'
		}
		decoded = append(decoded, code)
		index += 3
	}
	return decoded, nil
}

type resultCollector struct {
	response protocol.Response
	limit    int
	rowBytes int
	rowSizes []int
	baseSize int
	stopped  bool
}

func newResultCollector(command protocol.Command, fields []pgconn.FieldDescription, limit int) *resultCollector {
	response := protocol.Response{Type: "query.result", RequestID: command.RequestID, SessionID: command.SessionID, QueryID: command.QueryID,
		TransactionStatus: "idle", Columns: make([]protocol.Column, len(fields)), Rows: make([][]*string, 0)}
	for index, field := range fields {
		response.Columns[index] = protocol.Column{Index: index, Name: field.Name, Engine: "postgresql", NativeType: "oid:" + strconv.FormatUint(uint64(field.DataTypeOID), 10), TypeOID: field.DataTypeOID}
	}
	base, _ := json.Marshal(response)
	return &resultCollector{response: response, limit: limit, baseSize: len(base)}
}

func (collector *resultCollector) add(values [][]byte) {
	if collector.stopped {
		return
	}
	if len(collector.response.Rows) == MaxResultRows {
		collector.response.Truncated, collector.stopped = true, true
		return
	}
	row := make([]*string, len(values))
	for index, value := range values {
		if value != nil {
			text := string(value)
			row[index] = &text
		}
	}
	collector.addRow(row)
}

func (collector *resultCollector) addRow(row []*string) {
	if collector.stopped {
		return
	}
	if len(collector.response.Rows) == MaxResultRows {
		collector.response.Truncated, collector.stopped = true, true
		return
	}
	encoded, _ := json.Marshal(row)
	// Reserve a little space for the final tag, timing and truncation notice.
	// finish still measures the actual complete JSON before emitting it.
	extra := len(encoded)
	if len(collector.response.Rows) > 0 {
		extra++
	}
	if collector.baseSize+collector.rowBytes+extra+1024 > collector.limit {
		collector.response.Truncated, collector.stopped = true, true
		return
	}
	collector.response.Rows = append(collector.response.Rows, row)
	collector.rowSizes = append(collector.rowSizes, len(encoded))
	collector.rowBytes += extra
}

func (collector *resultCollector) finish(tag pgconn.CommandTag, elapsed time.Duration, txStatus string) protocol.Response {
	response := &collector.response
	response.CommandTag, response.RowCount = tag.String(), tag.RowsAffected()
	response.DurationMS = float64(elapsed) / float64(time.Millisecond)
	response.TransactionStatus = txStatus
	if response.Truncated {
		response.DisplayNotice = "Result display is limited to 1000 rows and 8 MiB. The command completed in full."
	}
	for {
		response.DisplayedRowCount = len(response.Rows)
		// The empty rows array contributes its two brackets to base. Each saved
		// row contributes its exact JSON size, plus the commas between rows.
		rows := response.Rows
		response.Rows = nil
		base, _ := json.Marshal(response)
		response.Rows = rows
		if len(base)+collector.rowBytes <= collector.limit {
			return *response
		}
		response.Truncated = true
		response.DisplayNotice = "Result display is limited to 1000 rows and 8 MiB. The command completed in full."
		if len(rows) > 0 {
			last := len(rows) - 1
			collector.rowBytes -= collector.rowSizes[last]
			if last > 0 {
				collector.rowBytes--
			}
			response.Rows = rows[:last]
			collector.rowSizes = collector.rowSizes[:last]
			continue
		}
		// PostgreSQL can complete successfully even when metadata cannot fit.
		// Keep the actual outcome and use a compact, explicit display notice.
		response.Columns = nil
		response.DisplayNotice = "Column metadata exceeds the display limit; no data is shown. The command completed in full."
		base, _ = json.Marshal(response)
		if len(base) <= collector.limit {
			return *response
		}
		// Protocol identifiers are bounded. A server command tag normally has
		// only a few bytes; cap a hostile oversized tag without changing counts.
		response.CommandTag = ""
		response.DisplayNotice = "Result exceeds the display limit. The command completed in full."
		return *response
	}
}

func queryError(command protocol.Command, ctx context.Context, conn *pgx.Conn, err error) protocol.Response {
	response := protocol.ErrorResponse(command, "connection", "PostgreSQL connection was lost. The command outcome is unknown.")
	response.Connected = !conn.IsClosed()
	var pgError *pgconn.PgError
	if errors.As(err, &pgError) {
		if pgError.Position > 0 {
			response.ErrorPosition = int(pgError.Position)
		}
		if validSQLState(pgError.Code) {
			response.SQLState = pgError.Code
		}
		if pgError.Severity == "FATAL" || pgError.Severity == "PANIC" || pgError.SeverityUnlocalized == "FATAL" || pgError.SeverityUnlocalized == "PANIC" || strings.HasPrefix(pgError.Code, "08") || pgError.Code == "57P01" {
			// A fatal session failure has no normal command completion or
			// ReadyForQuery boundary. Keep the SQL outcome explicitly unknown.
			response.Connected, response.OutcomeUnknown = false, true
			return response
		}
		response.Category, response.Message = "sql", boundedDiagnostic(pgError.Message)
		if pgError.Code == "57014" {
			if errors.Is(ctx.Err(), context.DeadlineExceeded) {
				response.Category, response.Message = "timeout", "Query execution timed out."
			} else if errors.Is(ctx.Err(), context.Canceled) {
				response.Category, response.Message = "cancelled", "Query was cancelled."
			}
		}
	} else if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		response.Category, response.Message = "timeout", "Query execution timed out."
		if !response.Connected {
			response.Message = "Query timed out and its connection could not be recovered. The command outcome is unknown."
		}
	} else if errors.Is(ctx.Err(), context.Canceled) {
		response.Category, response.Message = "cancelled", "Query was cancelled."
		if !response.Connected {
			response.Message = "Query was cancelled and its connection could not be recovered. The command outcome is unknown."
		}
	}
	if response.Connected {
		response.TransactionStatus = transactionStatus(conn)
	} else {
		response.OutcomeUnknown = pgError == nil
	}
	return response
}

func boundedDiagnostic(message string) string {
	const limit = 4096
	if message == "" {
		return "PostgreSQL rejected the SQL command."
	}
	if len(message) <= limit {
		return message
	}
	message = message[:limit]
	for !utf8.ValidString(message) && len(message) > 0 {
		message = message[:len(message)-1]
	}
	return message + "…"
}

// COPY requires an interactive frontend exchange and is outside this protocol.
// Inspect only the initial SQL keyword, skipping SQL whitespace/comments; the
// SQL itself is never split or rewritten. All statement validation stays on PG.
func startsWithCopy(sql string) bool {
	for {
		// PostgreSQL ignores empty statements before its one parsed statement.
		sql = strings.TrimLeft(sql, " \t\r\n\f\v;")
		if strings.HasPrefix(sql, "--") {
			if newline := strings.IndexAny(sql, "\r\n"); newline >= 0 {
				sql = sql[newline+1:]
				continue
			}
			return false
		}
		if strings.HasPrefix(sql, "/*") {
			depth, index := 1, 2
			for index < len(sql) && depth > 0 {
				if strings.HasPrefix(sql[index:], "/*") {
					depth++
					index += 2
				} else if strings.HasPrefix(sql[index:], "*/") {
					depth--
					index += 2
				} else {
					index++
				}
			}
			if depth != 0 {
				return false
			}
			sql = sql[index:]
			continue
		}
		break
	}
	end := 0
	for end < len(sql) && (sql[end] >= 'a' && sql[end] <= 'z' || sql[end] >= 'A' && sql[end] <= 'Z' || sql[end] == '_' || sql[end] >= '0' && sql[end] <= '9' || sql[end] == '$' || sql[end] >= 128) {
		end++
	}
	return strings.EqualFold(sql[:end], "copy")
}
