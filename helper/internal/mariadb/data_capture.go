package mariadb

import (
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"dbeer/helper/internal/mysql"
	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	tc "dbeer/helper/internal/tablecapture"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

// These adapters own an idle physical connection. Their consistent read does
// not change session isolation, encoding, SQL mode, role, database or time zone.
func (s *Session) flowBegin(ctx context.Context) (*changeExecution, mariaDBWriteScope, error) {
	if s.closed.Load() || s.TransactionStatus() != "idle" {
		return nil, mariaDBWriteScope{}, tc.ErrUnsupported
	}
	if deadline, ok := ctx.Deadline(); ok {
		_ = s.work.transport.SetDeadline(deadline.Add(RecoveryTimeout))
	}
	x := s.newChangeExecution(ctx)
	scope, err := loadMariaDBWriteScope(x)
	if err != nil {
		x.finish()
		if !s.closed.Load() {
			_ = s.work.transport.SetDeadline(time.Time{})
		}
		return nil, scope, err
	}
	if scope.state[6] != "1" || scope.state[9] != "DEFAULT" {
		x.finish()
		if !s.closed.Load() {
			_ = s.work.transport.SetDeadline(time.Time{})
		}
		return nil, scope, tc.ErrUnsupported
	}
	return x, scope, nil
}
func flowQuery(x *changeExecution, sql string, args ...any) error {
	r, e := x.query(sql, args...)
	if r != nil {
		r.Close()
	}
	return e
}
func (s *Session) flowSnapshot(x *changeExecution) error {
	rows, e := mariaDBMetadataRows(x, "SELECT @@SESSION.tx_isolation")
	if e != nil {
		return e
	}
	if len(rows) != 1 || rowText(rows[0], 0) != "REPEATABLE-READ" {
		return tc.ErrUnsupported
	}
	return flowQuery(x, "START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY")
}
func (s *Session) flowFinish(x *changeExecution, transaction bool) error {
	x.finish()
	if s.closed.Load() {
		return tc.ErrInvalid
	}
	if transaction {
		_ = s.work.transport.SetDeadline(time.Now().Add(RecoveryTimeout))
		r, e := s.work.client.Execute("ROLLBACK AND NO CHAIN NO RELEASE")
		if r != nil {
			r.Close()
		}
		if e != nil {
			s.Close()
			return e
		}
	}
	s.updateTransaction()
	_ = s.work.transport.SetDeadline(time.Time{})
	return nil
}

func (s *Session) describeFlowTable(x *changeExecution, table tc.Table, scope mariaDBWriteScope) (tc.Descriptor, error) {
	d := tc.Descriptor{Engine: "mariadb", Table: table, Columns: []tc.Column{}}
	if !table.Valid() || !mariaDBNameValid(table.Schema) || !mariaDBNameValid(table.Name) {
		return d, tc.ErrInvalid
	}
	name := QuoteIdentifier(table.Schema) + "." + QuoteIdentifier(table.Name)
	r, e := x.query("SHOW CREATE TABLE " + name)
	if e != nil {
		return d, e
	}
	raw, e := r.GetString(0, 1)
	permanent := e == nil && r.RowNumber() == 1 && strings.HasPrefix(raw, "CREATE TABLE ")
	r.Close()
	if !permanent {
		return d, tc.ErrUnsupported
	}
	tables, e := mariaDBMetadataRows(x, "SELECT TABLE_TYPE,ENGINE,TABLE_COLLATION,CREATE_OPTIONS,CAST(CREATE_TIME AS CHAR) FROM information_schema.TABLES WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? LIMIT 2", table.Schema, table.Name)
	if e != nil {
		return d, e
	}
	if len(tables) != 1 || (rowText(tables[0], 0) != "BASE TABLE" && rowText(tables[0], 0) != "SYSTEM VERSIONED") {
		return d, tc.ErrUnsupported
	}
	engine := rowText(tables[0], 1)
	if engine != "InnoDB" && engine != "MyISAM" && engine != "Aria" {
		return d, tc.ErrUnsupported
	}
	principal, e := mariaDBMetadataRows(x, "SELECT CURRENT_USER()")
	if e != nil {
		return d, e
	}
	if len(principal) != 1 || strings.Count(rowText(principal[0], 0), "@") != 1 {
		return d, tc.ErrUnsupported
	}
	user, host, _ := strings.Cut(rowText(principal[0], 0), "@")
	grantee := "'" + strings.ReplaceAll(user, "'", "''") + "'@'" + strings.ReplaceAll(host, "'", "''") + "'"
	privilege, e := mariaDBMetadataRows(x, "SELECT (EXISTS(SELECT 1 FROM information_schema.USER_PRIVILEGES WHERE BINARY GRANTEE=BINARY ? AND PRIVILEGE_TYPE='SELECT') OR EXISTS(SELECT 1 FROM information_schema.SCHEMA_PRIVILEGES WHERE BINARY GRANTEE=BINARY ? AND BINARY TABLE_SCHEMA=BINARY ? AND PRIVILEGE_TYPE='SELECT') OR EXISTS(SELECT 1 FROM information_schema.TABLE_PRIVILEGES WHERE BINARY GRANTEE=BINARY ? AND BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? AND PRIVILEGE_TYPE='SELECT'))", grantee, grantee, table.Schema, grantee, table.Schema, table.Name)
	if e != nil {
		return d, e
	}
	if len(privilege) != 1 || rowText(privilege[0], 0) != "1" {
		return d, tc.ErrUnsupported
	}
	columns, e := mariaDBMetadataRows(x, "SELECT COLUMN_NAME,ORDINAL_POSITION,DATA_TYPE,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT,EXTRA,COALESCE(GENERATION_EXPRESSION,''),CHARACTER_SET_NAME,COLLATION_NAME,CHARACTER_MAXIMUM_LENGTH,NUMERIC_PRECISION,NUMERIC_SCALE,DATETIME_PRECISION,PRIVILEGES FROM information_schema.COLUMNS WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? ORDER BY ORDINAL_POSITION LIMIT 4097", table.Schema, table.Name)
	if e != nil {
		return d, e
	}
	if len(columns) == 0 || len(columns) > tc.MaxColumns {
		return d, tc.ErrUnsupported
	}
	keys, e := mariaDBMetadataRows(x, "SELECT COLUMN_NAME,ORDINAL_POSITION FROM information_schema.KEY_COLUMN_USAGE WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? AND CONSTRAINT_NAME='PRIMARY' ORDER BY ORDINAL_POSITION", table.Schema, table.Name)
	if e != nil {
		return d, e
	}
	primary := map[string]int{}
	for _, k := range keys {
		n, ok := rowInt(k, 1)
		if !ok || n < 1 || primary[rowText(k, 0)] != 0 {
			return d, tc.ErrUnsupported
		}
		primary[rowText(k, 0)] = n
	}
	periodColumns := []MariaDBPeriodColumn{}
	for i, c := range columns {
		ordinal, ok := rowInt(c, 1)
		kind := rowText(c, 2)
		if len(c) != 15 || !ok || ordinal != i+1 || !MariaDBEditableKind(kind) || !strings.Contains(","+strings.ToLower(rowText(c, 14))+",", ",select,") {
			return d, tc.ErrUnsupported
		}
		typ := mysql.CatalogTypeShape(kind, rowText(c, 3), rowText(c, 8), rowText(c, 10), rowText(c, 11), rowText(c, 12), rowText(c, 13), "")
		if (kind == "inet4" || kind == "inet6") && rowText(c, 3) == kind {
			typ.Modifiers = sc.Known(sc.TypeModifiers{Length: flowNumber(rowText(c, 10)), Precision: flowNumber(rowText(c, 11)), Scale: flowNumber(rowText(c, 12)), DatetimePrecision: flowNumber(rowText(c, 13))})
		}
		native, err := json.Marshal(struct {
			Type               any
			Charset, Collation string
		}{typ, rowText(c, 8), rowText(c, 9)})
		if err != nil {
			return d, err
		}
		definition, err := json.Marshal(c)
		if err != nil {
			return d, err
		}
		encoding := ""
		if mariaDBBinaryType(kind) || rowText(c, 8) == "binary" || (kind == "enum" || kind == "set") && rowText(c, 8) == "" {
			encoding = "base64"
		}
		if kind == "enum" || kind == "set" {
			encoding = ""
		}
		comparison := ""
		if typ.Modifiers.State != "known" {
			comparison = "unresolved"
		}
		if (kind == "enum" || kind == "set") && (rowText(c, 8) == "" || rowText(c, 8) == "binary" || strings.Contains(rowText(c, 3), "?")) {
			comparison = "unresolved"
		}
		if rowText(tables[0], 0) == "SYSTEM VERSIONED" {
			comparison = "unresolved"
		}
		d.Columns = append(d.Columns, tc.Column{Index: i, Name: rowText(c, 0), NativeType: string(native), TypeLabel: rowText(c, 3), Encoding: encoding, PrimaryKey: primary[rowText(c, 0)], Numeric: strings.Contains("|tinyint|smallint|mediumint|int|bigint|decimal|numeric|float|double|", "|"+kind+"|"), Generated: rowText(c, 7) != "" || strings.Contains(rowText(c, 6), "GENERATED"), Identity: strings.Contains(rowText(c, 6), "auto_increment"), Nullable: rowText(c, 4) == "YES", Definition: definition, ValueComparison: comparison})
		periodColumns = append(periodColumns, MariaDBPeriodColumn{Name: rowText(c, 0), NativeType: rowText(c, 3), DataType: kind, Generated: rowText(c, 7)})
	}
	periods, e := MariaDBSystemPeriods(x.query, table.Schema, table.Name, rowText(tables[0], 0), periodColumns)
	if e != nil {
		return d, e
	}
	actor, e := mariaDBMetadataRows(x, "SELECT CURRENT_USER(),CURRENT_ROLE()")
	if e != nil {
		return d, e
	}
	// SHOW CREATE includes volatile AUTO_INCREMENT counters. Ordered native column,
	// key, storage and period metadata supply the descriptor without that counter.
	d.Definition, e = json.Marshal(struct {
		Server               string
		Actor                [][]*string
		State                []string
		Table, Columns, Keys [][]*string
		Periods              []MariaDBPeriodColumn
	}{s.serverIdentity, actor, scope.state, tables, columns, keys, periods})
	if e != nil {
		return d, e
	}
	return d, d.Seal()
}
func (s *Session) DescribeTable(ctx context.Context, table tc.Table) (d tc.Descriptor, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, ExecuteTimeout)
	defer cancel()
	x, scope, e := s.flowBegin(ctx)
	if e != nil {
		return d, e
	}
	defer func() {
		if e := s.flowFinish(x, false); err == nil {
			err = e
		}
	}()
	d, err = s.describeFlowTable(x, table, scope)
	if err == nil {
		err = scope.verify(x)
	}
	return
}
func (s *Session) CaptureTable(ctx context.Context, spec tc.Spec, sink tc.Sink) (d tc.Descriptor, out tc.Outcome, err error) {
	out = tc.Outcome{Engine: "mariadb", Table: spec.Table, StartedAt: time.Now().UTC().Format(time.RFC3339Nano), ReadLimit: spec.ReadLimit, Consistency: "repeatableReadBestEffortMetadata", Rendering: "mariadbNativeUTCUTF8v1", PartialReasons: []string{}}
	defer func() { out.FinishedAt = time.Now().UTC().Format(time.RFC3339Nano); out.DescriptorDigest = d.Digest }()
	if sink == nil {
		return d, out, tc.ErrInvalid
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, ExecuteTimeout)
	defer cancel()
	x, scope, e := s.flowBegin(ctx)
	if e != nil {
		return d, out, e
	}
	transaction := false
	defer func() {
		if e := s.flowFinish(x, transaction); err == nil {
			err = e
		}
		if ctx.Err() != nil && err != tc.ErrQuota {
			err = ctx.Err()
		}
	}()
	if err = s.flowSnapshot(x); err != nil {
		return
	}
	transaction = true
	d, err = s.describeFlowTable(x, spec.Table, scope)
	if err != nil {
		return
	}
	if err = tc.Validate(d, spec); err != nil {
		return
	}
	var metadata struct{ Table [][]*string }
	if json.Unmarshal(d.Definition, &metadata) != nil {
		return d, out, tc.ErrInvalid
	}
	if rowText(metadata.Table[0], 1) != "InnoDB" {
		out.Consistency = "bestEffortNontransactionalMetadataAndRows"
	}
	statement, e := mariaDBDataSQL(d, spec)
	if e != nil {
		return d, out, e
	}
	if err = s.readFlowRows(x, scope.wrap(statement), d, spec.Columns, spec.ReadLimit, sink, &out); err != nil {
		return
	}
	var after tc.Descriptor
	after, err = s.describeFlowTable(x, spec.Table, scope)
	if err != nil {
		return
	}
	if after.Digest != d.Digest {
		return d, out, tc.ErrChanged
	}
	err = scope.verify(x)
	return
}

func mariaDBDataSQL(d tc.Descriptor, spec tc.Spec) (string, error) {
	byName := map[string]tc.Column{}
	for _, c := range d.Columns {
		byName[c.Name] = c
	}
	fields := []string{}
	for _, name := range spec.Columns {
		c, ok := byName[name]
		if !ok {
			return "", tc.ErrInvalid
		}
		expr := MariaDBStableProjection(name, flowKind(c))
		if flowKind(c) == "enum" || flowKind(c) == "set" {
			q := QuoteIdentifier(name)
			expr = "IF(" + q + " IS NULL,NULL,JSON_ARRAY(CAST(" + q + " AS UNSIGNED),HEX(" + q + ")))"
		}
		fields = append(fields, expr+" AS "+QuoteIdentifier(name))
	}
	predicates := []string{}
	ops := map[string]string{"eq": "=", "ne": "<>", "lt": "<", "lte": "<=", "gt": ">", "gte": ">="}
	for _, f := range spec.Filters {
		c, ok := byName[f.Column]
		if !ok || !f.Valid() {
			return "", tc.ErrInvalid
		}
		name := QuoteIdentifier(c.Name)
		if f.Operator == "isNull" || f.Operator == "isNotNull" {
			suffix := " IS NULL"
			if f.Operator == "isNotNull" {
				suffix = " IS NOT NULL"
			}
			predicates = append(predicates, name+suffix)
			continue
		}
		if MariaDBStorageKind(flowKind(c)) || mariaDBSpatialKind(flowKind(c)) {
			return "", tc.ErrUnsupported
		}
		literal, e := flowLiteral(protocol.CellValue{Kind: "text", Value: f.Value})
		if c.Encoding == "base64" {
			literal, e = flowLiteral(protocol.CellValue{Kind: "binary", Value: f.Value})
		}
		if e != nil {
			return "", e
		}
		if c.Numeric {
			template, value, e := flowNumericParameter(flowKind(c), *f.Value)
			if e != nil {
				return "", tc.ErrInvalid
			}
			literal, e = flowLiteral(protocol.CellValue{Kind: "text", Value: &value})
			if e != nil {
				return "", e
			}
			literal = strings.Replace(template, "?", literal, 1)
		}
		if f.Operator == "contains" {
			if c.Numeric {
				return "", tc.ErrUnsupported
			}
			predicates = append(predicates, "LOCATE("+literal+","+name+")>0")
			continue
		}
		op, ok := ops[f.Operator]
		if !ok {
			return "", tc.ErrInvalid
		}
		predicates = append(predicates, name+op+literal)
	}
	sql := "SELECT " + strings.Join(fields, ",") + " FROM " + QuoteIdentifier(spec.Table.Schema) + "." + QuoteIdentifier(spec.Table.Name)
	if len(predicates) > 0 {
		sql += " WHERE " + strings.Join(predicates, " AND ")
	}
	order := []string{}
	for _, k := range spec.Keys {
		if _, ok := byName[k]; !ok {
			return "", tc.ErrInvalid
		}
		order = append(order, QuoteIdentifier(k)+" ASC")
	}
	if len(order) > 0 {
		sql += " ORDER BY " + strings.Join(order, ",")
	}
	if spec.ReadLimit > 0 {
		sql += " LIMIT " + strconv.Itoa(spec.ReadLimit+1)
	}
	return sql, nil
}
func flowKind(c tc.Column) string { return strings.Split(strings.Split(c.TypeLabel, "(")[0], " ")[0] }
func mariaDBSpatialKind(kind string) bool {
	return strings.Contains("|geometry|point|linestring|polygon|multipoint|multilinestring|multipolygon|geometrycollection|", "|"+kind+"|")
}

type flowPacket struct {
	data  []byte
	limit int
}

func (p *flowPacket) Write(b []byte) (int, error) {
	if len(b) > p.limit-len(p.data) {
		return 0, tc.ErrUnsupported
	}
	p.data = append(p.data, b...)
	return len(b), nil
}
func (s *Session) flowPacket(limit int) ([]byte, error) {
	p := &flowPacket{limit: limit}
	e := s.work.client.ReadPacketTo(p)
	return p.data, e
}

// Read the text protocol directly: generic RowData.Parse converts exact numeric
// spellings through float64. On an undrained stream, retire instead of reusing it.
func (s *Session) readFlowRows(x *changeExecution, sql string, d tc.Descriptor, names []string, limit int, sink tc.Sink, out *tc.Outcome) (err error) {
	drained := false
	defer func() {
		x.gate.Lock()
		x.active = false
		x.gate.Unlock()
		if recover() != nil {
			err = tc.ErrInvalid
		}
		if !drained {
			s.Close()
		}
	}()
	if e := x.ctx.Err(); e != nil {
		return e
	}
	x.gate.Lock()
	x.active = true
	x.gate.Unlock()
	if e := s.sendTextQuery(sql); e != nil {
		return e
	}
	header, e := s.flowPacket(65536)
	if e != nil {
		return e
	}
	if len(header) > 0 && header[0] == wire.ERR_HEADER {
		drained = true
		return s.work.client.HandleErrorPacket(header)
	}
	count, n, ok := lengthEncoded(header)
	if !ok || n != len(header) || int(count) != len(names) {
		return tc.ErrChanged
	}
	metadataBytes := 0
	for _, name := range names {
		data, e := s.flowPacket(65536)
		if e != nil {
			return e
		}
		metadataBytes += len(data)
		if metadataBytes > 1<<20 {
			return tc.ErrUnsupported
		}
		f, e := wire.FieldData(data).Parse()
		if e != nil || string(f.Name) != name {
			return tc.ErrChanged
		}
	}
	eof, e := s.flowPacket(65536)
	if e != nil || len(eof) != 5 || eof[0] != wire.EOF_HEADER {
		return tc.ErrInvalid
	}
	byName := map[string]tc.Column{}
	for _, c := range d.Columns {
		byName[c.Name] = c
	}
	for {
		data, e := s.flowPacket(tc.MaxRowBytes)
		if e != nil {
			return e
		}
		if len(data) == 5 && data[0] == wire.EOF_HEADER {
			if binary.LittleEndian.Uint16(data[3:5])&wire.SERVER_MORE_RESULTS_EXISTS != 0 {
				return tc.ErrUnsupported
			}
			drained = true
			if binary.LittleEndian.Uint16(data[1:3]) != 0 {
				return tc.ErrUnsupported
			}
			return nil
		}
		if len(data) == 0 || data[0] == wire.ERR_HEADER {
			return tc.ErrInvalid
		}
		row, e := decodeFlowRow(data, len(names))
		if e != nil {
			return e
		}
		out.ObservedAtLeast++
		if limit > 0 && out.StoredRows >= int64(limit) {
			out.PartialReasons = []string{"readLimit"}
			continue
		}
		for i, v := range row {
			if v == nil {
				continue
			}
			if byName[names[i]].Encoding == "base64" {
				text := base64.StdEncoding.EncodeToString([]byte(*v))
				row[i] = &text
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
func decodeFlowRow(data []byte, width int) ([]*string, error) {
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
		v := string(data[offset : offset+int(length)])
		row[i] = &v
		offset += int(length)
	}
	if offset != len(data) {
		return nil, tc.ErrInvalid
	}
	return row, nil
}

var _ tc.Reader = (*Session)(nil)

func flowNumber(s string) *int64 {
	v, e := strconv.ParseInt(s, 10, 64)
	if e != nil {
		return nil
	}
	return &v
}
