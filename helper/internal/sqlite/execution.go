package sqlite

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/queryparams"
	lib "zombiezen.com/go/sqlite"
)

func quote(s string) string { return `"` + strings.ReplaceAll(s, `"`, `""`) + `"` }
func valueAt(stmt *lib.Stmt, i int) protocol.SQLiteValue {
	switch stmt.ColumnType(i) {
	case lib.TypeNull:
		return protocol.SQLiteValue{Type: "null"}
	case lib.TypeInteger:
		return protocol.SQLiteValue{Type: "integer", Value: strconv.FormatInt(stmt.ColumnInt64(i), 10)}
	case lib.TypeFloat:
		return protocol.SQLiteValue{Type: "real", Value: fmt.Sprintf("%016x", math.Float64bits(stmt.ColumnFloat(i)))}
	case lib.TypeText:
		return protocol.SQLiteValue{Type: "text", Value: base64.StdEncoding.EncodeToString([]byte(stmt.ColumnText(i)))}
	default:
		b := make([]byte, stmt.ColumnLen(i))
		stmt.ColumnBytes(i, b)
		return protocol.SQLiteValue{Type: "blob", Value: base64.StdEncoding.EncodeToString(b)}
	}
}
func display(v protocol.SQLiteValue) *string {
	if v.Type == "null" {
		return nil
	}
	t := v.Value
	switch v.Type {
	case "text":
		b, _ := base64.StdEncoding.DecodeString(v.Value)
		if utf8.Valid(b) {
			t = string(b)
		} else {
			t = "[non-UTF-8 text: " + v.Value + "]"
		}
	case "real":
		bits, _ := strconv.ParseUint(v.Value, 16, 64)
		t = strconv.FormatFloat(math.Float64frombits(bits), 'g', -1, 64)
	}
	return &t
}
func text(v protocol.SQLiteValue) string {
	if v.Type == "text" {
		b, _ := base64.StdEncoding.DecodeString(v.Value)
		return string(b)
	}
	if p := display(v); p != nil {
		return *p
	}
	return ""
}
func integer(v protocol.SQLiteValue) int { n, _ := strconv.Atoi(text(v)); return n }
func bind(stmt *lib.Stmt, args []any) error {
	if stmt.BindParamCount() != len(args) {
		return errors.New("The SQLite parameter count does not match.")
	}
	for i, a := range args {
		p := i + 1
		switch v := a.(type) {
		case nil:
			stmt.BindNull(p)
		case string:
			stmt.BindText(p, v)
		case []byte:
			stmt.BindBytes(p, v)
		case int:
			stmt.BindInt64(p, int64(v))
		case int64:
			stmt.BindInt64(p, v)
		case float64:
			stmt.BindFloat(p, v)
		case bool:
			stmt.BindBool(p, v)
		case protocol.SQLiteValue:
			switch v.Type {
			case "null":
				stmt.BindNull(p)
			case "integer":
				n, e := strconv.ParseInt(v.Value, 10, 64)
				if e != nil {
					return e
				}
				stmt.BindInt64(p, n)
			case "real":
				n, e := strconv.ParseUint(v.Value, 16, 64)
				if e != nil {
					return e
				}
				stmt.BindFloat(p, math.Float64frombits(n))
			case "text", "blob":
				b, e := base64.StdEncoding.DecodeString(v.Value)
				if e != nil {
					return e
				}
				if v.Type == "text" {
					stmt.BindText(p, string(b))
				} else {
					stmt.BindBytes(p, b)
				}
			default:
				return errors.New("Invalid SQLite storage class.")
			}
		default:
			return errors.New("Unsupported SQLite parameter.")
		}
	}
	return nil
}
func (s *Session) query(ctx context.Context, sql string, args ...any) ([][]protocol.SQLiteValue, []string, error) {
	old := s.internal
	s.internal = true
	defer func() { s.internal = old }()
	previous := s.conn.SetInterrupt(ctx.Done())
	defer s.conn.SetInterrupt(previous)
	stmt, tail, err := s.conn.PrepareTransient(sql)
	if err != nil {
		return nil, nil, err
	}
	defer stmt.Finalize()
	if tail != 0 && !emptyTail(sql[len(sql)-tail:]) {
		return nil, nil, errors.New("Only one SQLite statement is accepted.")
	}
	if err = bind(stmt, args); err != nil {
		return nil, nil, err
	}
	names := make([]string, stmt.ColumnCount())
	for i := range names {
		names[i] = stmt.ColumnName(i)
	}
	rows := [][]protocol.SQLiteValue{}
	bytes := 0
	for {
		has, e := stmt.Step()
		if e != nil {
			return nil, nil, e
		}
		if !has {
			break
		}
		row := make([]protocol.SQLiteValue, len(names))
		for i := range row {
			row[i] = valueAt(stmt, i)
			bytes += len(row[i].Value) + 32
		}
		if bytes > 16<<20 || len(rows) >= 100001 {
			return nil, nil, errors.New("SQLite metadata exceeds the capture limit.")
		}
		rows = append(rows, row)
	}
	return rows, names, nil
}
func (s *Session) exec(ctx context.Context, sql string, args ...any) error {
	_, _, err := s.query(ctx, sql, args...)
	return err
}
func (s *Session) fail(c protocol.Command, ctx context.Context, err error) protocol.Response {
	category, message := "sql", "The SQLite operation failed. Check the statement, file permissions and database constraints."
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		category, message = "timeout", "SQLite execution timed out."
	} else if ctx.Err() != nil {
		category, message = "cancelled", "SQLite execution was cancelled."
	} else if code := lib.ErrCode(err); code == lib.ResultBusy || code == lib.ResultLocked {
		category, message = "conflict", "The SQLite database is busy. Finish the other transaction and retry explicitly."
	} else if code == lib.ResultAuth || code == lib.ResultReadOnly {
		category, message = "policy", "The SQLite operation is prohibited by the connection policy."
	}
	r := protocol.ErrorResponse(c, category, message)
	r.Connected = !s.closed
	r.TransactionStatus = s.TransactionStatus()
	return r
}

func (s *Session) execute(ctx context.Context, c protocol.Command, sink adapter.ResultSink) protocol.Response {
	sql, err := s.prepareUserSQL(c.SQL)
	if err != nil {
		return s.fail(c, ctx, err)
	}
	bound, err := queryparams.Bind("sqlite", sql, c.Parameters)
	if err != nil {
		return s.fail(c, ctx, err)
	}
	args := make([]any, len(bound.Parameters))
	for i, p := range bound.Parameters {
		if p.Value == nil {
			continue
		}
		switch p.Type {
		case "integer":
			args[i], err = strconv.ParseInt(*p.Value, 10, 64)
		case "boolean":
			args[i] = *p.Value == "true"
		default:
			args[i] = *p.Value
		}
		if err != nil {
			return s.fail(c, ctx, err)
		}
	}
	response := s.executeBound(ctx, c, bound.SQL, args, sink)
	if response.Type == "query.result" && s.attachmentChanged {
		if err := s.refreshAttachments(ctx); err != nil {
			s.Close()
			failure := s.fail(c, ctx, err)
			failure.SQLCompleted = true
			return failure
		}
	}
	return response
}
func (s *Session) executeBound(ctx context.Context, c protocol.Command, sql string, args []any, sink adapter.ResultSink) protocol.Response {
	started := time.Now()
	previous := s.conn.SetInterrupt(ctx.Done())
	defer s.conn.SetInterrupt(previous)
	stmt, tail, err := s.conn.PrepareTransient(sql)
	if err != nil {
		r := s.fail(c, ctx, err)
		r.SQLNotExecuted = true
		return r
	}
	defer stmt.Finalize()
	if tail != 0 && !emptyTail(sql[len(sql)-tail:]) {
		r := s.fail(c, ctx, errors.New("Multiple statements are not accepted."))
		r.SQLNotExecuted = true
		return r
	}
	if err = bind(stmt, args); err != nil {
		return s.fail(c, ctx, err)
	}
	r := protocol.Response{Type: "query.result", RequestID: c.RequestID, SessionID: c.SessionID, QueryID: c.QueryID, Columns: []protocol.Column{}, Rows: [][]*string{}, SQLiteValues: [][]protocol.SQLiteValue{}, Connected: true}
	for i := 0; i < stmt.ColumnCount(); i++ {
		r.Columns = append(r.Columns, protocol.Column{Index: i, Name: stmt.ColumnName(i), Engine: "sqlite", NativeType: "dynamic"})
	}
	if sink != nil {
		if err = sink.Begin(0, r.Columns); err != nil {
			return s.fail(c, ctx, err)
		}
	}
	bytes := 0
	var sinkError error
	for {
		has, e := stmt.Step()
		if e != nil {
			return s.fail(c, ctx, e)
		}
		if !has {
			break
		}
		r.RowCount++
		row := make([]*string, len(r.Columns))
		typed := make([]protocol.SQLiteValue, len(row))
		size := 0
		for i := range row {
			typed[i] = valueAt(stmt, i)
			row[i] = display(typed[i])
			size += len(typed[i].Value) + 32
			if row[i] != nil {
				size += len(*row[i])
			}
		}
		if sink != nil && sinkError == nil {
			if typedSink, ok := sink.(interface {
				SQLiteRow(int, []protocol.SQLiteValue) error
			}); ok {
				sinkError = typedSink.SQLiteRow(0, typed)
			}
			if sinkError == nil {
				sinkError = sink.Row(0, row)
			}
		}
		if len(r.Rows) < 1000 && bytes+size <= 8<<20 {
			r.Rows = append(r.Rows, row)
			r.SQLiteValues = append(r.SQLiteValues, typed)
			bytes += size
		} else {
			r.Truncated = true
		}
	}
	if len(r.Columns) == 0 {
		word := strings.Fields(strings.ToUpper(sqlStart(sql)))
		if len(word) > 0 && (word[0] == "INSERT" || word[0] == "UPDATE" || word[0] == "DELETE" || word[0] == "REPLACE") {
			r.RowCount = int64(s.conn.Changes())
		} else {
			r.RowCount = 0
		}
		r.CommandTag = "OK"
	} else {
		r.CommandTag = "SELECT"
	}
	r.DisplayedRowCount = len(r.Rows)
	r.TransactionStatus = s.TransactionStatus()
	r.DurationMS = float64(time.Since(started)) / float64(time.Millisecond)
	if r.Truncated {
		r.DisplayNotice = "The displayed result reached the 1,000-row or 8 MiB limit."
	}
	if sink != nil && sinkError == nil {
		sinkError = sink.End(0, protocol.ResultSet{Columns: r.Columns, Rows: r.Rows, SQLiteValues: r.SQLiteValues, CommandTag: r.CommandTag, RowCount: r.RowCount, DisplayedRowCount: r.DisplayedRowCount, Truncated: r.Truncated, DisplayNotice: r.DisplayNotice})
	}
	if sinkError != nil {
		failure := s.fail(c, ctx, sinkError)
		failure.SQLCompleted = true
		return failure
	}
	return r
}

// Only whitespace and comments may follow the prepared statement.
func emptyTail(tail string) bool {
	return sqlStart(tail) == ""
}

func sqlStart(tail string) string {
	for {
		tail = strings.TrimSpace(tail)
		if tail == "" {
			return ""
		}
		if strings.HasPrefix(tail, "--") {
			if i := strings.IndexByte(tail, '\n'); i >= 0 {
				tail = tail[i+1:]
				continue
			}
			return ""
		}
		if strings.HasPrefix(tail, "/*") {
			if i := strings.Index(tail[2:], "*/"); i >= 0 {
				tail = tail[i+4:]
				continue
			}
		}
		return tail
	}
}
