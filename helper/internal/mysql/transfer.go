package mysql

import (
	"context"
	"encoding/base64"
	"errors"
	"io"
	"regexp"
	"strconv"
	"strings"
	"time"

	dt "dbeer/helper/internal/datatransfer"
	"dbeer/helper/internal/protocol"
	tc "dbeer/helper/internal/tablecapture"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

var transferDecimalType = regexp.MustCompile(`^(?:decimal|numeric)\(([0-9]+),([0-9]+)\)$`)

func transferDecimalBounds(native string) (int, int, bool) {
	native = strings.TrimSuffix(native, " zerofill")
	native = strings.TrimSuffix(native, " unsigned")
	match := transferDecimalType.FindStringSubmatch(native)
	if len(match) != 3 {
		return 0, 0, false
	}
	precision, err := strconv.Atoi(match[1])
	if err != nil {
		return 0, 0, false
	}
	scale, err := strconv.Atoi(match[2])
	if err != nil {
		return 0, 0, false
	}
	return precision, scale, precision >= 1 && precision <= 65 && scale >= 0 && scale <= 30 && scale <= precision
}

type transferSink struct {
	columns []protocol.TransferColumn
	consume func([]protocol.CellValue) error
}

func (s transferSink) Row(values []*string) error {
	row := make([]protocol.CellValue, len(values))
	for index, value := range values {
		kind := "text"
		if value == nil {
			kind = "null"
		} else if s.columns[index].Type == "binary" {
			kind = "binary"
		}
		if value != nil && s.columns[index].Type == "timestampTZ" {
			if parsed, err := time.Parse("2006-01-02 15:04:05.999999", *value); err == nil && parsed.Year() > 0 {
				text := parsed.UTC().Format(time.RFC3339Nano)
				value = &text
			}
		}
		row[index] = protocol.CellValue{Kind: kind, Value: value}
	}
	return s.consume(row)
}

func (s *Session) transferBegin(ctx context.Context) (*changeExecution, error) {
	if s.closed.Load() || s.TransactionStatus() != "idle" {
		return nil, dt.ErrInvalid
	}
	if deadline, ok := ctx.Deadline(); ok {
		_ = s.work.transport.SetDeadline(deadline.Add(RecoveryTimeout))
	}
	return s.newChangeExecution(ctx), nil
}
func transferQuery(execution *changeExecution, sql string, args ...any) error {
	r, err := execution.query(sql, args...)
	if r != nil {
		r.Close()
	}
	return err
}
func (s *Session) transferDescription(execution *changeExecution, schema, table string) (dt.Description, error) {
	d := dt.Description{Columns: []protocol.TransferColumn{}, Notices: []string{}}
	meta, err := mysqlImportRows(execution, `SELECT TABLE_TYPE,ENGINE,TABLE_COLLATION,CAST(CREATE_TIME AS CHAR) FROM information_schema.TABLES WHERE BINARY TABLE_SCHEMA=? AND BINARY TABLE_NAME=? LIMIT 2`, schema, table)
	if err != nil {
		return d, err
	}
	if len(meta) != 1 || myText(meta[0], 0) != "BASE TABLE" || myText(meta[0], 1) != "InnoDB" {
		return d, dt.ErrInvalid
	}
	rows, err := mysqlImportRows(execution, `SELECT COLUMN_NAME,DATA_TYPE,COLUMN_TYPE,IS_NULLABLE,EXTRA,COALESCE(GENERATION_EXPRESSION,''),CHARACTER_SET_NAME FROM information_schema.COLUMNS WHERE BINARY TABLE_SCHEMA=? AND BINARY TABLE_NAME=? ORDER BY ORDINAL_POSITION LIMIT 257`, schema, table)
	if err != nil {
		return d, err
	}
	if len(rows) == 0 || len(rows) > protocol.MaxTransferColumns {
		return d, dt.ErrInvalid
	}
	for index, row := range rows {
		kind, native := myText(row, 1), myText(row, 2)
		c := protocol.TransferColumn{SourceIndex: index, Name: myText(row, 0), Nullable: myText(row, 3) == "YES", Type: "text"}
		switch kind {
		case "tinyint", "smallint", "mediumint", "int", "bigint":
			c.Type = "integer"
			if kind == "bigint" && strings.Contains(native, "unsigned") {
				c.Type = "decimal"
				c.Precision = 20
			}
		case "decimal", "numeric":
			precision, scale, ok := transferDecimalBounds(native)
			if !ok {
				return d, dt.ErrInvalid
			}
			c.Type = "decimal"
			c.Precision, c.Scale = precision, scale
		case "float", "double", "real":
			c.Type = "real"
		case "date":
			c.Type = "date"
		case "datetime":
			c.Type = "timestamp"
		case "timestamp":
			c.Type = "timestampTZ"
		case "json":
			c.Type = "json"
		case "bit", "binary", "varbinary", "tinyblob", "blob", "mediumblob", "longblob":
			c.Type = "binary"
		case "char", "varchar", "tinytext", "text", "mediumtext", "longtext", "enum", "set", "time", "year":
		default:
			return d, dt.ErrInvalid
		}
		if c.Type == "text" && kind != "text" && kind != "varchar" && kind != "char" {
			d.Notices = append(d.Notices, "Some source types are copied as reviewed TEXT values; source labels, duration types and their constraints are not cloned.")
		}
		if !c.Valid() {
			return d, dt.ErrInvalid
		}
		d.Columns = append(d.Columns, c)
	}
	d.Digest = dt.Digest([]any{s.serverUUID, schema, table, meta, rows})
	return d, nil
}
func (s *Session) TransferDescribe(ctx context.Context, schema, table string) (dt.Description, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	execution, err := s.transferBegin(ctx)
	if err != nil {
		return dt.Description{}, err
	}
	defer execution.finish()
	if err = transferQuery(execution, "SET SESSION time_zone='+00:00'"); err != nil {
		return dt.Description{}, err
	}
	return s.transferDescription(execution, schema, table)
}
func (s *Session) TransferCapture(ctx context.Context, schema, table, digest string, sink func([]protocol.CellValue) error) (d dt.Description, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	execution, err := s.transferBegin(ctx)
	if err != nil {
		return d, err
	}
	defer execution.finish()
	for _, sql := range []string{"SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ", "SET SESSION time_zone='+00:00'", "SET NAMES utf8mb4", "SET SESSION sql_mode=TRIM(BOTH ',' FROM REPLACE(CONCAT(',',@@SESSION.sql_mode,','),',PAD_CHAR_TO_FULL_LENGTH,',','))", "START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY"} {
		if err = transferQuery(execution, sql); err != nil {
			return d, err
		}
	}
	name := QuoteIdentifier(schema) + "." + QuoteIdentifier(table)
	if err = transferQuery(execution, "SELECT * FROM "+name+" LIMIT 0"); err != nil {
		return d, err
	}
	d, err = s.transferDescription(execution, schema, table)
	if err != nil {
		return d, err
	}
	if d.Digest != digest {
		return d, dt.ErrChanged
	}
	names := []string{}
	spec := tc.Spec{ReadLimit: int(^uint(0) >> 1)}
	descriptor := tc.Descriptor{}
	for _, column := range d.Columns {
		name := QuoteIdentifier(column.Name)
		if column.Type == "real" {
			name = "CAST(" + name + " AS DOUBLE) AS " + QuoteIdentifier(column.Name)
		}
		names = append(names, name)
		spec.Columns = append(spec.Columns, column.Name)
		encoding := ""
		if column.Type == "binary" {
			encoding = "base64"
		}
		descriptor.Columns = append(descriptor.Columns, tc.Column{Name: column.Name, Encoding: encoding})
	}
	execution.gate.Lock()
	execution.active = true
	execution.gate.Unlock()
	err = s.readDataRows("SELECT "+strings.Join(names, ",")+" FROM "+name, descriptor, spec, transferSink{d.Columns, sink}, &tc.Outcome{}, wire.NewResult(nil))
	execution.gate.Lock()
	execution.active = false
	execution.gate.Unlock()
	if err != nil {
		s.Close()
		return d, err
	}
	if err = transferQuery(execution, "ROLLBACK"); err != nil {
		s.Close()
	}
	return d, err
}
func transferMySQLDDL(schema, table string, columns []protocol.TransferColumn) (string, error) {
	if err := dt.ValidateTarget("mysql", schema, table); err != nil {
		return "", err
	}
	if err := dt.ValidateColumns(columns, "mysql"); err != nil {
		return "", err
	}
	parts := []string{}
	for _, column := range columns {
		kind := ""
		switch column.Type {
		case "text":
			kind = "LONGTEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"
		case "integer":
			kind = "BIGINT"
		case "decimal":
			kind = "DECIMAL(" + strconv.Itoa(column.Precision) + "," + strconv.Itoa(column.Scale) + ")"
		case "real":
			kind = "DOUBLE"
		case "boolean":
			kind = "BOOLEAN"
		case "date":
			kind = "DATE"
		case "timestamp", "timestampTZ":
			kind = "DATETIME(6)"
		case "json":
			kind = "LONGTEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"
		case "binary":
			kind = "LONGBLOB"
		default:
			return "", dt.ErrInvalid
		}
		part := QuoteIdentifier(column.Name) + " " + kind
		if !column.Nullable {
			part += " NOT NULL"
		}
		parts = append(parts, part)
	}
	return "CREATE TABLE " + QuoteIdentifier(schema) + "." + QuoteIdentifier(table) + " (\n  " + strings.Join(parts, ",\n  ") + "\n) ENGINE=InnoDB;", nil
}
func (s *Session) transferPreview(execution *changeExecution, schema, table string, columns []protocol.TransferColumn) (string, error) {
	sql, err := transferMySQLDDL(schema, table, columns)
	if err != nil {
		return "", err
	}
	rows, err := mysqlImportRows(execution, `SELECT EXISTS(SELECT 1 FROM information_schema.SCHEMATA WHERE BINARY SCHEMA_NAME=?),EXISTS(SELECT 1 FROM information_schema.TABLES WHERE BINARY TABLE_SCHEMA=? AND BINARY TABLE_NAME=?)`, schema, schema, table)
	if err != nil {
		return "", err
	}
	if len(rows) != 1 || myText(rows[0], 0) != "1" {
		return "", dt.ErrInvalid
	}
	if myText(rows[0], 1) != "0" {
		return "", dt.ErrExists
	}
	return sql, nil
}
func (s *Session) TransferPreview(ctx context.Context, schema, table string, columns []protocol.TransferColumn) (string, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	execution, err := s.transferBegin(ctx)
	if err != nil {
		return "", "", err
	}
	defer execution.finish()
	statement, err := s.transferPreview(execution, schema, table, columns)
	return statement, s.serverUUID, err
}
func transferMySQLArguments(row []protocol.CellValue, columns []protocol.TransferColumn) ([]any, error) {
	args := make([]any, len(row))
	for index, value := range row {
		if value.Kind == "null" {
			continue
		}
		if value.Value == nil {
			return nil, dt.ErrInvalid
		}
		text := *value.Value
		switch columns[index].Type {
		case "binary":
			b, err := base64.StdEncoding.DecodeString(text)
			if err != nil {
				return nil, err
			}
			args[index] = b
		case "boolean":
			if text == "true" {
				args[index] = int64(1)
			} else {
				args[index] = int64(0)
			}
		case "integer":
			n, err := strconv.ParseInt(text, 10, 64)
			if err != nil {
				return nil, err
			}
			args[index] = n
		case "real":
			n, err := strconv.ParseFloat(text, 64)
			if err != nil {
				return nil, err
			}
			args[index] = n
		case "timestampTZ":
			parsed, err := time.Parse(time.RFC3339Nano, text)
			if err != nil {
				return nil, err
			}
			args[index] = parsed.UTC().Format("2006-01-02 15:04:05.999999")
		default:
			args[index] = text
		}
	}
	return args, nil
}
func (s *Session) TransferApply(ctx context.Context, schema, table, expectedIdentity string, columns []protocol.TransferColumn, read dt.RowReader, progress func(int64)) (out dt.Result, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.serverUUID != expectedIdentity {
		return out, dt.ErrChanged
	}
	execution, err := s.transferBegin(ctx)
	if err != nil {
		return out, err
	}
	defer execution.finish()
	statement, err := s.transferPreview(execution, schema, table, columns)
	if err != nil {
		return out, err
	}
	if err = transferQuery(execution, "SET SESSION sql_mode=CONCAT_WS(',',@@SESSION.sql_mode,'STRICT_ALL_TABLES','NO_ZERO_DATE','NO_ZERO_IN_DATE','ERROR_FOR_DIVISION_BY_ZERO'), explicit_defaults_for_timestamp=ON, time_zone='+00:00', lock_wait_timeout=5, innodb_lock_wait_timeout=5"); err != nil {
		return out, err
	}
	// CREATE is intentionally not IF NOT EXISTS and cannot overwrite another
	// table racing this preview. MySQL commits DDL independently of row inserts.
	if err = transferQuery(execution, statement); err != nil {
		var server *wire.MyError
		if !errors.As(err, &server) {
			out.OutcomeUnknown = true
		}
		return out, err
	}
	out.TableCreated = true
	if err = transferQuery(execution, "BEGIN"); err != nil {
		return out, err
	}
	names, marks := []string{}, []string{}
	for _, column := range columns {
		names = append(names, QuoteIdentifier(column.Name))
		marks = append(marks, "?")
	}
	insert := "INSERT INTO " + QuoteIdentifier(schema) + "." + QuoteIdentifier(table) + " (" + strings.Join(names, ",") + ") VALUES (" + strings.Join(marks, ",") + ")"
	var count int64
	for {
		row, e := read()
		if e == io.EOF {
			break
		}
		if e != nil {
			return out, e
		}
		if len(row) != len(columns) {
			return out, dt.ErrInvalid
		}
		args, e := transferMySQLArguments(row, columns)
		if e != nil {
			return out, e
		}
		result, e := execution.query(insert, args...)
		if result != nil {
			if e == nil && (result.Warnings != 0 || result.AffectedRows != 1) {
				e = dt.ErrInvalid
			}
			result.Close()
		}
		if e != nil {
			return out, e
		}
		count++
		if count%1000 == 0 {
			progress(count)
		}
	}
	if ctx.Err() != nil {
		return out, ctx.Err()
	}
	if err = transferQuery(execution, "COMMIT"); err != nil {
		out.OutcomeUnknown = true
		out.Rows = count
		s.Close()
		return out, err
	}
	out.Rows = count
	progress(count)
	return out, nil
}

var _ dt.Database = (*Session)(nil)
