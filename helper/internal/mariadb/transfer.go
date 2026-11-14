package mariadb

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"strconv"
	"strings"
	"time"

	dt "dbeer/helper/internal/datatransfer"
	"dbeer/helper/internal/protocol"
	tc "dbeer/helper/internal/tablecapture"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func transferMariaDBColumns(columns []protocol.TransferColumn) error {
	if e := dt.ValidateColumns(columns, "mariadb"); e != nil {
		return e
	}
	seen := map[string]bool{}
	for _, c := range columns {
		key := strings.ToLower(c.Name)
		if !mariaDBNameValid(c.Name) || seen[key] || c.Type == "decimal" && (c.Precision > 65 || c.Scale > 38) {
			return dt.ErrInvalid
		}
		seen[key] = true
	}
	return nil
}
func transferMariaDBDescription(d tc.Descriptor) (dt.Description, error) {
	out := dt.Description{Columns: []protocol.TransferColumn{}, Notices: []string{dt.OmissionNotice()}}
	if len(d.Columns) > protocol.MaxTransferColumns {
		return out, dt.ErrInvalid
	}
	var meta struct {
		Table   [][]*string
		Periods []MariaDBPeriodColumn
	}
	if json.Unmarshal(d.Definition, &meta) != nil {
		return out, dt.ErrInvalid
	}
	if len(meta.Table) == 1 && rowText(meta.Table[0], 1) != "InnoDB" {
		out.Notices = append(out.Notices, "The "+rowText(meta.Table[0], 1)+" source is nontransactional. Read-only capture is best effort and concurrent row changes are not isolated by its transaction snapshot.")
	}
	if len(meta.Periods) > 0 {
		out.Notices = append(out.Notices, "Copies current visible values only. System-versioning history and implicit period witnesses are not cloned.")
	}
	for i, c := range d.Columns {
		kind := flowKind(c)
		v := protocol.TransferColumn{SourceIndex: i, Name: c.Name, Type: "text", Nullable: c.Nullable}
		switch kind {
		case "tinyint", "smallint", "mediumint", "int", "bigint":
			v.Type = "integer"
			if kind == "bigint" && strings.Contains(c.TypeLabel, "unsigned") {
				v.Type = "decimal"
				v.Precision = 20
			}
		case "decimal", "numeric":
			var raw []*string
			if json.Unmarshal(c.Definition, &raw) != nil {
				return out, dt.ErrInvalid
			}
			p, ok := rowInt(raw, 11)
			scale, yes := rowInt(raw, 12)
			if !ok || !yes || p < 1 || p > 65 || scale < 0 || scale > 38 || scale > p {
				return out, dt.ErrInvalid
			}
			v.Type = "decimal"
			v.Precision = p
			v.Scale = scale
		case "float", "double":
			v.Type = "real"
		case "date":
			v.Type = "date"
		case "datetime":
			v.Type = "timestamp"
		case "timestamp":
			v.Type = "timestampTZ"
		case "bit", "binary", "varbinary", "tinyblob", "blob", "mediumblob", "longblob", "geometry", "point", "linestring", "polygon", "multipoint", "multilinestring", "multipolygon", "geometrycollection":
			v.Type = "binary"
		case "enum", "set":
			var raw []*string
			if json.Unmarshal(c.Definition, &raw) != nil {
				return out, dt.ErrInvalid
			}
			if rowText(raw, 8) == "" || rowText(raw, 8) == "binary" {
				v.Type = "binary"
			}
			out.Notices = append(out.Notices, "ENUM/SET copies displayed label bytes only. Ordinals, empty-member bits and the source label domain are not cloned.")
		case "char", "varchar", "tinytext", "text", "mediumtext", "longtext", "time", "year", "uuid", "inet4", "inet6":
		default:
			return out, dt.ErrInvalid
		}
		if kind == "date" || kind == "datetime" || kind == "timestamp" {
			out.Notices = append(out.Notices, "Native zero or partial temporal values retain their original text. Choose TEXT to preserve them; temporal destinations refuse invalid dates instead of coercing them.")
		}
		if mariaDBSpatialKind(kind) {
			out.Notices = append(out.Notices, "Geometry is copied as MariaDB internal binary storage, including its SRID prefix; it is not WKB or a spatial target type.")
		}
		if !v.Valid() {
			return out, dt.ErrInvalid
		}
		out.Columns = append(out.Columns, v)
	}
	out.Digest = d.Digest
	return out, nil
}
func (s *Session) TransferDescribe(ctx context.Context, schema, table string) (dt.Description, error) {
	d, e := s.DescribeTable(ctx, tc.Table{Schema: schema, Name: table})
	if e != nil {
		return dt.Description{}, e
	}
	return transferMariaDBDescription(d)
}

type mariaDBTransferSink struct {
	columns []protocol.TransferColumn
	consume func([]protocol.CellValue) error
}

func (s mariaDBTransferSink) Row(row []*string) error {
	if len(row) != len(s.columns) {
		return dt.ErrChanged
	}
	cells := make([]protocol.CellValue, len(row))
	for i, v := range row {
		kind := "text"
		if v == nil {
			kind = "null"
		} else if s.columns[i].Type == "binary" {
			kind = "binary"
		}
		if v != nil && s.columns[i].Type == "timestampTZ" {
			p, e := time.Parse("2006-01-02 15:04:05.999999", *v)
			if e == nil && p.Year() >= 1000 {
				value := p.UTC().Format(time.RFC3339Nano)
				v = &value
			}
		}
		cells[i] = protocol.CellValue{Kind: kind, Value: v}
	}
	return s.consume(cells)
}
func (s *Session) TransferCapture(ctx context.Context, schema, table, digest string, sink func([]protocol.CellValue) error) (d dt.Description, err error) {
	if sink == nil {
		return d, dt.ErrInvalid
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, ExecuteTimeout)
	defer cancel()
	x, scope, e := s.flowBegin(ctx)
	if e != nil {
		return d, e
	}
	transaction := false
	defer func() {
		if e := s.flowFinish(x, transaction); err == nil {
			err = e
		}
		if ctx.Err() != nil {
			err = ctx.Err()
		}
	}()
	if err = s.flowSnapshot(x); err != nil {
		return
	}
	transaction = true
	captured, e := s.describeFlowTable(x, tc.Table{Schema: schema, Name: table}, scope)
	if e != nil {
		return d, e
	}
	d, e = transferMariaDBDescription(captured)
	if e != nil {
		return d, e
	}
	if d.Digest != digest {
		return d, dt.ErrChanged
	}
	names := []string{}
	fields := []string{}
	for i, c := range captured.Columns {
		expr := MariaDBStableProjection(c.Name, flowKind(c))
		fields = append(fields, expr+" AS "+QuoteIdentifier(c.Name))
		names = append(names, c.Name)
		if d.Columns[i].Type == "binary" {
			captured.Columns[i].Encoding = "base64"
		} else {
			captured.Columns[i].Encoding = ""
		}
	}
	sql := "SELECT " + strings.Join(fields, ",") + " FROM " + QuoteIdentifier(schema) + "." + QuoteIdentifier(table)
	if err = s.readFlowRows(x, scope.wrap(sql), captured, names, 0, mariaDBTransferSink{d.Columns, sink}, &tc.Outcome{}); err != nil {
		return
	}
	after, e := s.describeFlowTable(x, captured.Table, scope)
	if e != nil {
		return d, e
	}
	if after.Digest != digest {
		return d, dt.ErrChanged
	}
	err = scope.verify(x)
	return
}
func transferMariaDBDDL(schema, table string, columns []protocol.TransferColumn) (string, error) {
	if !mariaDBNameValid(schema) || !mariaDBNameValid(table) {
		return "", dt.ErrInvalid
	}
	if e := transferMariaDBColumns(columns); e != nil {
		return "", e
	}
	parts := []string{}
	for _, c := range columns {
		typ := ""
		switch c.Type {
		case "text", "json":
			typ = "LONGTEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_bin"
		case "integer":
			typ = "BIGINT"
		case "decimal":
			typ = "DECIMAL(" + strconv.Itoa(c.Precision) + "," + strconv.Itoa(c.Scale) + ")"
		case "real":
			typ = "DOUBLE"
		case "boolean":
			typ = "BOOLEAN"
		case "date":
			typ = "DATE"
		case "timestamp", "timestampTZ":
			typ = "DATETIME(6)"
		case "binary":
			typ = "LONGBLOB"
		default:
			return "", dt.ErrInvalid
		}
		part := QuoteIdentifier(c.Name) + " " + typ
		if !c.Nullable {
			part += " NOT NULL"
		}
		parts = append(parts, part)
	}
	return "CREATE TABLE " + QuoteIdentifier(schema) + "." + QuoteIdentifier(table) + " (\n " + strings.Join(parts, ",\n ") + "\n) ENGINE=InnoDB", nil
}
func (s *Session) transferPreviewFlow(x *changeExecution, scope mariaDBWriteScope, schema, table string, columns []protocol.TransferColumn) (sql, identity string, err error) {
	sql, err = transferMariaDBDDL(schema, table, columns)
	if err != nil {
		return
	}
	rows, e := mariaDBMetadataRows(x, "SELECT SCHEMA_NAME,DEFAULT_CHARACTER_SET_NAME,DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE BINARY SCHEMA_NAME=BINARY ?", schema)
	if e != nil {
		return "", "", e
	}
	if len(rows) != 1 {
		return "", "", dt.ErrInvalid
	}
	exists, e := mariaDBMetadataRows(x, "SELECT TABLE_NAME FROM information_schema.TABLES WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? LIMIT 2", schema, table)
	if e != nil {
		return "", "", e
	}
	if len(exists) != 0 {
		return "", "", dt.ErrExists
	}
	// A temporary table can shadow a schema-qualified permanent target too.
	shadow, e := x.query("SHOW CREATE TABLE " + QuoteIdentifier(schema) + "." + QuoteIdentifier(table))
	if shadow != nil {
		shadow.Close()
	}
	var server *wire.MyError
	if e == nil {
		return "", "", dt.ErrExists
	}
	if !errors.As(e, &server) || server.Code != 1146 {
		return "", "", e
	}
	actor, e := mariaDBMetadataRows(x, "SELECT CURRENT_USER(),CURRENT_ROLE()")
	if e != nil {
		return "", "", e
	}
	if len(actor) != 1 || len(actor[0]) != 2 {
		return "", "", dt.ErrInvalid
	}
	sql = scope.wrap(sql)
	identity = dt.Digest([]any{"mariadb", s.serverIdentity, actor, scope.state, rows, schema, table, columns, sql})
	return
}
func (s *Session) TransferPreview(ctx context.Context, schema, table string, columns []protocol.TransferColumn) (sql, identity string, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, ExecuteTimeout)
	defer cancel()
	x, scope, e := s.flowBegin(ctx)
	if e != nil {
		return "", "", e
	}
	defer func() {
		if e := s.flowFinish(x, false); err == nil {
			err = e
		}
	}()
	sql, identity, err = s.transferPreviewFlow(x, scope, schema, table, columns)
	if err == nil {
		err = scope.verify(x)
	}
	return
}
func transferMariaDBArguments(row []protocol.CellValue, columns []protocol.TransferColumn) ([]any, error) {
	if len(row) != len(columns) {
		return nil, dt.ErrInvalid
	}
	size := 0
	for _, v := range row {
		if v.Value != nil {
			size += len(*v.Value)
		}
	}
	if size > dt.MaxRowBytes {
		return nil, dt.ErrInvalid
	}
	args := make([]any, len(row))
	for i, v := range row {
		normalized, e := dt.Normalize(v, columns[i], "mariadb")
		if e != nil {
			return nil, e
		}
		if normalized.Kind == "null" {
			continue
		}
		text := *normalized.Value
		if columns[i].Type == "date" && text < "1000-01-01" || columns[i].Type == "timestamp" && text < "1000-01-01 00:00:00" || columns[i].Type == "timestampTZ" && text < "1000-01-01T00:00:00Z" {
			return nil, dt.ErrInvalid
		}
		switch columns[i].Type {
		case "binary":
			args[i], e = base64.StdEncoding.DecodeString(text)
		case "boolean":
			if text == "true" {
				args[i] = int64(1)
			} else {
				args[i] = int64(0)
			}
		case "integer":
			args[i], e = strconv.ParseInt(text, 10, 64)
		case "real":
			args[i], e = strconv.ParseFloat(text, 64)
		case "timestampTZ":
			var p time.Time
			p, e = time.Parse(time.RFC3339Nano, text)
			args[i] = p.UTC().Format("2006-01-02 15:04:05.999999")
		default:
			args[i] = text
		}
		if e != nil {
			return nil, e
		}
	}
	return args, nil
}
func (s *Session) TransferApply(ctx context.Context, schema, table, expectedIdentity string, columns []protocol.TransferColumn, read dt.RowReader, progress func(int64)) (out dt.Result, err error) {
	if read == nil {
		return out, dt.ErrInvalid
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, ExecuteTimeout)
	defer cancel()
	x, scope, e := s.flowBegin(ctx)
	if e != nil {
		return out, e
	}
	transaction := false
	defer func() {
		if e := s.flowFinish(x, transaction); err == nil {
			err = e
		}
		if ctx.Err() != nil && err != nil {
			err = ctx.Err()
		}
	}()
	statement, identity, e := s.transferPreviewFlow(x, scope, schema, table, columns)
	if e != nil {
		return out, e
	}
	if identity != expectedIdentity {
		return out, dt.ErrChanged
	}
	writable, e := mariaDBMetadataRows(x, "SELECT @@SESSION.tx_read_only")
	if e != nil {
		return out, e
	}
	if len(writable) != 1 || rowText(writable[0], 0) != "0" {
		return out, dt.ErrInvalid
	}
	if err = scope.verify(x); err != nil {
		return
	}
	r, e, dispatched := x.run(statement)
	warnings := uint16(0)
	if r != nil {
		warnings = r.Warnings
		r.Close()
	}
	if e != nil {
		var server *wire.MyError
		if dispatched && !errors.As(e, &server) {
			out.OutcomeUnknown = true
			s.Close()
		}
		return out, e
	}
	out.TableCreated = true
	if warnings != 0 {
		return out, dt.ErrInvalid
	}
	if err = flowQuery(x, "BEGIN"); err != nil {
		return
	}
	transaction = true
	names, marks := []string{}, []string{}
	for _, c := range columns {
		names = append(names, QuoteIdentifier(c.Name))
		marks = append(marks, "?")
	}
	insert := scope.wrap("INSERT INTO " + QuoteIdentifier(schema) + "." + QuoteIdentifier(table) + " (" + strings.Join(names, ",") + ") VALUES (" + strings.Join(marks, ",") + ")")
	count := int64(0)
	for {
		row, e := read()
		if e == io.EOF {
			break
		}
		if e != nil {
			return out, e
		}
		args, e := transferMariaDBArguments(row, columns)
		if e != nil {
			return out, e
		}
		r, e := x.query(insert, args...)
		if r != nil {
			if e == nil && (r.Warnings != 0 || r.AffectedRows != 1) {
				e = dt.ErrInvalid
			}
			r.Close()
		}
		if e != nil {
			return out, e
		}
		count++
		if progress != nil && count%1000 == 0 {
			progress(count)
		}
	}
	if err = scope.verify(x); err != nil {
		return
	}
	dispatched = false
	commit := func() error {
		r, e, started := x.run("COMMIT AND NO CHAIN NO RELEASE")
		dispatched = dispatched || started
		if r != nil {
			r.Close()
		}
		return e
	}
	if s.commitOverride != nil {
		err = s.commitOverride(commit)
	} else {
		err = commit()
	}
	if err != nil {
		if dispatched {
			out.OutcomeUnknown = true
			out.Rows = count
			transaction = false
			x.finish()
			s.Close()
		}
		return
	}
	if !dispatched {
		return out, dt.ErrInvalid
	}
	transaction = false
	out.Rows = count
	if progress != nil {
		progress(count)
	}
	return
}

var _ dt.Database = (*Session)(nil)
