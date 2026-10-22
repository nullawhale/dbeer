package mysql

import (
	"context"
	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	tc "dbeer/helper/internal/tablecapture"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	wire "github.com/go-mysql-org/go-mysql/mysql"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

func (s *Session) dataSetup() error {
	for _, sql := range []string{"SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ", "SET SESSION time_zone='+00:00'", "SET NAMES utf8mb4", "SET SESSION show_gipk_in_create_table_and_information_schema=ON", "START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY"} {
		result, e := s.work.client.Execute(sql)
		if e != nil {
			return e
		}
		result.Close()
	}
	return nil
}
func (s *Session) dataRollback() {
	if s.closed.Load() {
		return
	}
	_ = s.work.transport.SetDeadline(time.Now().Add(RecoveryTimeout))
	result, e := s.work.client.Execute("ROLLBACK")
	if e == nil {
		result.Close()
	}
}
func (s *Session) DescribeTable(ctx context.Context, table tc.Table) (tc.Descriptor, error) {
	var d tc.Descriptor
	var captured error
	response := s.executeWith(ctx, protocol.Command{}, func(_ *collector, _ *wire.Result) error {
		if captured = s.dataSetup(); captured != nil {
			return captured
		}
		defer s.dataRollback()
		d, captured = s.describeDataTable(table)
		return captured
	})
	if captured != nil {
		return d, captured
	}
	if response.Type != "query.result" {
		return d, tc.ErrInvalid
	}
	return d, nil
}
func (s *Session) describeDataTable(table tc.Table) (tc.Descriptor, error) {
	d := tc.Descriptor{Engine: "mysql", Table: table, Columns: []tc.Column{}}
	if !table.Valid() {
		return d, tc.ErrInvalid
	}
	r := &mysqlSchemaCapture{s: s, spec: sc.CaptureSpec{Limits: sc.DefaultLimits()}}
	tables, e := r.rows("SELECT TABLE_NAME,ENGINE,TABLE_COLLATION,CREATE_OPTIONS FROM information_schema.TABLES WHERE BINARY TABLE_SCHEMA=? AND BINARY TABLE_NAME=? AND TABLE_TYPE='BASE TABLE'", table.Schema, table.Name)
	if e != nil {
		return d, e
	}
	if len(tables) != 1 || myText(tables[0], 1) != "InnoDB" || myText(tables[0], 3) != "" {
		return d, tc.ErrUnsupported
	}
	version, e := r.rows("SELECT VERSION()")
	if e != nil || len(version) != 1 {
		return d, tc.ErrUnsupported
	}
	v := strings.Split(myText(version[0], 0), ".")
	if len(v) < 3 || strings.Contains(strings.ToLower(myText(version[0], 0)), "mariadb") {
		return d, tc.ErrUnsupported
	}
	if v[0] == "8" && v[1] == "0" && intValue(strings.Split(v[2], "-")[0]) < 30 {
		return d, tc.ErrUnsupported
	}
	if v[0] != "8" && v[0] != "9" {
		return d, tc.ErrUnsupported
	}
	principal, e := r.rows("SELECT CURRENT_USER(),CURRENT_ROLE(),@@partial_revokes")
	if e != nil || len(principal) != 1 {
		return d, tc.ErrUnsupported
	}
	identity := myText(principal[0], 0)
	user, host, ok := strings.Cut(identity, "@")
	if !ok || strings.Count(identity, "@") != 1 || myText(principal[0], 1) != "NONE" || myText(principal[0], 2) != "0" {
		return d, tc.ErrUnsupported
	}
	grantee := "'" + strings.ReplaceAll(user, "'", "''") + "'@'" + strings.ReplaceAll(host, "'", "''") + "'"
	privilege, e := r.rows("SELECT (EXISTS(SELECT 1 FROM information_schema.USER_PRIVILEGES WHERE GRANTEE=? AND PRIVILEGE_TYPE='SELECT') OR EXISTS(SELECT 1 FROM information_schema.SCHEMA_PRIVILEGES WHERE GRANTEE=? AND BINARY TABLE_SCHEMA=? AND PRIVILEGE_TYPE='SELECT') OR EXISTS(SELECT 1 FROM information_schema.TABLE_PRIVILEGES WHERE GRANTEE=? AND BINARY TABLE_SCHEMA=? AND BINARY TABLE_NAME=? AND PRIVILEGE_TYPE='SELECT'))", grantee, grantee, table.Schema, grantee, table.Schema, table.Name)
	if e != nil {
		return d, e
	}
	if len(privilege) != 1 || myText(privilege[0], 0) != "1" {
		return d, tc.ErrUnsupported
	}
	columns, e := r.rows("SELECT COLUMN_NAME,ORDINAL_POSITION,DATA_TYPE,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT,EXTRA,GENERATION_EXPRESSION,CHARACTER_SET_NAME,COLLATION_NAME,CHARACTER_MAXIMUM_LENGTH,NUMERIC_PRECISION,NUMERIC_SCALE,DATETIME_PRECISION,SRS_ID FROM information_schema.COLUMNS WHERE BINARY TABLE_SCHEMA=? AND BINARY TABLE_NAME=? ORDER BY ORDINAL_POSITION", table.Schema, table.Name)
	if e != nil {
		return d, e
	}
	keys, e := r.rows("SELECT COLUMN_NAME,ORDINAL_POSITION FROM information_schema.KEY_COLUMN_USAGE WHERE BINARY TABLE_SCHEMA=? AND BINARY TABLE_NAME=? AND CONSTRAINT_NAME='PRIMARY' ORDER BY ORDINAL_POSITION", table.Schema, table.Name)
	if e != nil {
		return d, e
	}
	primary := map[string]int{}
	for _, key := range keys {
		primary[myText(key, 0)] = intValue(myText(key, 1))
	}
	for i, c := range columns {
		kind := myText(c, 2)
		supported := strings.Contains("|tinyint|smallint|mediumint|int|bigint|decimal|float|double|bit|char|varchar|binary|varbinary|tinyblob|blob|mediumblob|longblob|tinytext|text|mediumtext|longtext|date|datetime|timestamp|time|year|json|enum|set|", "|"+kind+"|")
		if !supported {
			return d, tc.ErrUnsupported
		}
		native, _ := json.Marshal(struct{ DataType, ColumnType, Charset, Collation string }{kind, myText(c, 3), myText(c, 8), myText(c, 9)})
		definition, _ := json.Marshal(c)
		encoding := ""
		if kind == "bit" || strings.Contains(kind, "blob") || kind == "binary" || kind == "varbinary" {
			encoding = "base64"
		}
		extra := myText(c, 6)
		d.Columns = append(d.Columns, tc.Column{Index: i, Name: myText(c, 0), NativeType: string(native), TypeLabel: myText(c, 3), Encoding: encoding, PrimaryKey: primary[myText(c, 0)], Numeric: strings.Contains("|tinyint|smallint|mediumint|int|bigint|decimal|float|double|", "|"+kind+"|"), Generated: myText(c, 7) != "", Identity: strings.Contains(extra, "auto_increment"), Nullable: myText(c, 4) == "YES", Definition: definition})
	}
	d.Definition, e = json.Marshal(struct {
		Table      [][]*string `json:"table"`
		Columns    [][]*string `json:"columns"`
		PrimaryKey [][]*string `json:"primaryKey"`
	}{tables, columns, keys})
	if e != nil {
		return d, e
	}
	return d, d.Seal()
}
func (s *Session) CaptureTable(ctx context.Context, spec tc.Spec, sink tc.Sink) (tc.Descriptor, tc.Outcome, error) {
	var d tc.Descriptor
	out := tc.Outcome{StartedAt: time.Now().UTC().Format(time.RFC3339Nano), ReadLimit: spec.ReadLimit, Consistency: "repeatableReadBestEffortMetadata", Rendering: "mysqlTextUTCUTF8v1", PartialReasons: []string{}, Table: spec.Table, Engine: "mysql"}
	var captured error
	response := s.executeWith(ctx, protocol.Command{}, func(_ *collector, target *wire.Result) error {
		captured = func() error {
			if e := s.dataSetup(); e != nil {
				return e
			}
			streamStarted, streamFinished := false, false
			defer func() {
				if !streamStarted || streamFinished {
					s.dataRollback()
				}
			}()
			var e error
			d, e = s.describeDataTable(spec.Table)
			if e != nil {
				return e
			}
			if e = tc.Validate(d, spec); e != nil {
				return e
			}
			statement, e := mysqlDataSQL(d, spec)
			if e != nil {
				return e
			}
			streamStarted = true
			if e = s.readDataRows(statement, d, spec, sink, &out, target); e != nil {
				return e
			}
			streamFinished = true
			after, e := s.describeDataTable(spec.Table)
			if e != nil {
				return e
			}
			if after.Digest != d.Digest {
				return tc.ErrChanged
			}
			return nil
		}()
		return captured
	})
	out.FinishedAt = time.Now().UTC().Format(time.RFC3339Nano)
	out.DescriptorDigest = d.Digest
	if captured != nil {
		if ctx.Err() != nil && captured != tc.ErrQuota {
			return d, out, ctx.Err()
		}
		return d, out, captured
	}
	if response.Type != "query.result" {
		if ctx.Err() != nil {
			return d, out, ctx.Err()
		}
		return d, out, tc.ErrInvalid
	}
	return d, out, nil
}
func mysqlDataSQL(d tc.Descriptor, s tc.Spec) (string, error) {
	columns := map[string]tc.Column{}
	for _, c := range d.Columns {
		columns[c.Name] = c
	}
	quoted := []string{}
	for _, name := range s.Columns {
		quoted = append(quoted, QuoteIdentifier(name))
	}
	sql := "SELECT " + strings.Join(quoted, ",") + " FROM " + QuoteIdentifier(s.Table.Schema) + "." + QuoteIdentifier(s.Table.Name)
	predicates := []string{}
	ops := map[string]string{"eq": "=", "ne": "<>", "lt": "<", "lte": "<=", "gt": ">", "gte": ">="}
	for _, f := range s.Filters {
		c := columns[f.Column]
		name := QuoteIdentifier(c.Name)
		if f.Operator == "isNull" || f.Operator == "isNotNull" {
			operator := " IS NULL"
			if f.Operator == "isNotNull" {
				operator = " IS NOT NULL"
			}
			predicates = append(predicates, name+operator)
			continue
		}
		cell := protocol.CellValue{Kind: "text", Value: f.Value}
		if c.Encoding == "base64" {
			cell.Kind = "binary"
		}
		literal, e := insertLiteral(cell)
		if e != nil {
			return "", tc.ErrInvalid
		}
		if f.Operator == "contains" {
			if c.Numeric {
				return "", tc.ErrUnsupported
			}
			predicates = append(predicates, "LOCATE("+literal+","+name+")>0")
			continue
		}
		operator, ok := ops[f.Operator]
		if !ok {
			return "", tc.ErrInvalid
		}
		if c.Numeric {
			kind := strings.Split(c.TypeLabel, "(")[0]
			kind = strings.Split(kind, " ")[0]
			template, value, e := browseNumericParameter(kind, *f.Value)
			if e != nil {
				return "", tc.ErrInvalid
			}
			literal, e = insertLiteral(protocol.CellValue{Kind: "text", Value: &value})
			if e != nil {
				return "", e
			}
			literal = strings.Replace(template, "?", literal, 1)
		}
		predicates = append(predicates, name+" "+operator+" "+literal)
	}
	if len(predicates) > 0 {
		sql += " WHERE " + strings.Join(predicates, " AND ")
	}
	order := []string{}
	for _, key := range s.Keys {
		order = append(order, QuoteIdentifier(key)+" ASC")
	}
	return sql + " ORDER BY " + strings.Join(order, ",") + " LIMIT " + strconv.Itoa(s.ReadLimit+1), nil
}

type dataPacket struct {
	bytes []byte
	limit int
}

func (w *dataPacket) Write(b []byte) (int, error) {
	if len(b) > w.limit-len(w.bytes) {
		return 0, tc.ErrUnsupported
	}
	w.bytes = append(w.bytes, b...)
	return len(b), nil
}
func (s *Session) dataPacket(limit int) ([]byte, error) {
	w := &dataPacket{limit: limit}
	e := s.work.client.ReadPacketTo(w)
	return w.bytes, e
}

type dataCaptureWireFailure struct {
	stage string
	cause error
}

func (e *dataCaptureWireFailure) Error() string { return "Table capture wire stage: " + e.stage }
func (e *dataCaptureWireFailure) Unwrap() error { return e.cause }

func (s *Session) readDataRows(sql string, d tc.Descriptor, spec tc.Spec, sink tc.Sink, out *tc.Outcome, target *wire.Result) (err error) {
	stage := "send"
	defer func() {
		if recover() != nil {
			err = tc.ErrInvalid
		}
		if err != nil {
			err = &dataCaptureWireFailure{stage: stage, cause: err}
		}
	}()
	s.work.client.ResetSequence()
	payload := []byte{wire.COM_QUERY}
	// HasCapability reports explicit options, whereas CapabilityString reports
	// the negotiated flags, including library defaults.
	if strings.Contains("|"+s.work.client.CapabilityString()+"|", "|CLIENT_QUERY_ATTRIBUTES|") {
		payload = append(payload, 0, 1)
	}
	payload = append(payload, []byte(sql)...)
	packet := make([]byte, 4+len(payload))
	copy(packet[4:], payload)
	if e := s.work.client.WritePacket(packet); e != nil {
		return e
	}
	stage = "header"
	header, e := s.dataPacket(65536)
	if e != nil {
		return e
	}
	if len(header) >= 9 && header[0] == wire.ERR_HEADER {
		stage = "header.serverError"
		return s.work.client.HandleErrorPacket(header)
	}
	count, n, ok := lengthEncoded(header)
	if !ok || n != len(header) || int(count) != len(spec.Columns) {
		stage = "header.count"
		return tc.ErrChanged
	}
	byName := map[string]tc.Column{}
	for _, c := range d.Columns {
		byName[c.Name] = c
	}
	metadataBytes := 0
	stage = "fields"
	for _, name := range spec.Columns {
		data, e := s.dataPacket(65536)
		if e != nil {
			return e
		}
		metadataBytes += len(data)
		if metadataBytes > 1<<20 {
			return tc.ErrUnsupported
		}
		field, e := wire.FieldData(data).Parse()
		if e != nil || string(field.Name) != name {
			return tc.ErrChanged
		}
	}
	stage = "fieldsEOF"
	eof, e := s.dataPacket(65536)
	if e != nil || len(eof) != 5 || eof[0] != wire.EOF_HEADER {
		return tc.ErrInvalid
	}
	stage = "rows"
	for {
		data, e := s.dataPacket(tc.MaxRowBytes)
		if e != nil {
			return e
		}
		if len(data) == 5 && data[0] == wire.EOF_HEADER {
			target.Warnings = binary.LittleEndian.Uint16(data[1:3])
			target.Status = binary.LittleEndian.Uint16(data[3:5])
			if target.Warnings != 0 || target.Status&wire.SERVER_MORE_RESULTS_EXISTS != 0 {
				return tc.ErrUnsupported
			}
			return nil
		}
		if len(data) == 0 || data[0] == wire.ERR_HEADER {
			return tc.ErrInvalid
		}
		row, e := decodeDataTextRow(data, len(spec.Columns))
		if e != nil {
			return e
		}
		out.ObservedAtLeast++
		if out.StoredRows >= int64(spec.ReadLimit) {
			out.PartialReasons = []string{"readLimit"}
			continue
		}
		for i, v := range row {
			if v == nil {
				continue
			}
			if byName[spec.Columns[i]].Encoding == "base64" {
				value := base64.StdEncoding.EncodeToString([]byte(*v))
				row[i] = &value
			} else if !utf8.ValidString(*v) {
				return tc.ErrUnsupported
			}
		}
		if e = sink.Row(row); e != nil {
			return e
		}
		out.StoredRows++
	}
}

// Decode wire text bytes directly. RowData.Parse would convert numeric fields.
func decodeDataTextRow(data []byte, width int) ([]*string, error) {
	row := make([]*string, width)
	offset := 0
	for i := range row {
		if offset >= len(data) {
			return nil, tc.ErrInvalid
		}
		if data[offset] == 0xfb {
			offset++
			continue
		}
		length, n, ok := lengthEncoded(data[offset:])
		if !ok || length > uint64(len(data)-offset-n) {
			return nil, tc.ErrInvalid
		}
		offset += n
		value := string(data[offset : offset+int(length)])
		row[i] = &value
		offset += int(length)
	}
	if offset != len(data) {
		return nil, tc.ErrInvalid
	}
	return row, nil
}
