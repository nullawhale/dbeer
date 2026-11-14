package sqlite

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/browsevalue"
	"dbeer/helper/internal/protocol"
)

type columnInfo struct {
	Name, NativeType   string
	NotNull            bool
	PrimaryKey, Hidden int
	Default            *string
}

func (s *Session) tableInfo(ctx context.Context, schema, table string) ([]columnInfo, error) {
	if schema == "" {
		schema = "main"
	}
	rows, _, err := s.query(ctx, "SELECT name,type,\"notnull\",dflt_value,pk,hidden FROM pragma_table_xinfo(?,?) ORDER BY cid", table, schema)
	if err != nil {
		return nil, err
	}
	out := make([]columnInfo, 0, len(rows))
	for _, r := range rows {
		c := columnInfo{Name: text(r[0]), NativeType: text(r[1]), NotNull: integer(r[2]) != 0, PrimaryKey: integer(r[4]), Hidden: integer(r[5])}
		if r[3].Type != "null" {
			d := text(r[3])
			c.Default = &d
		}
		out = append(out, c)
	}
	if len(out) == 0 {
		return nil, errors.New("The SQLite table is unavailable.")
	}
	primary := []int{}
	for i, c := range out {
		if c.PrimaryKey > 0 {
			primary = append(primary, i)
		}
	}
	if len(primary) == 1 && strings.EqualFold(out[primary[0]].NativeType, "INTEGER") {
		// A genuine INTEGER PRIMARY KEY aliases rowid and cannot store NULL.
		// The historical PRIMARY KEY DESC exception has a separate PK index.
		indexes, _, e := s.query(ctx, "SELECT count(*) FROM pragma_index_list(?,?) WHERE origin='pk'", table, schema)
		if e != nil {
			return nil, e
		}
		if len(indexes) == 1 && integer(indexes[0][0]) == 0 {
			out[primary[0]].NotNull = true
		}
	}
	return out, nil
}
func (s *Session) editableTable(ctx context.Context, table string, cols []columnInfo) bool {
	rows, _, err := s.query(ctx, "SELECT type,sql FROM main.sqlite_schema WHERE name=?", table)
	if err != nil || len(rows) != 1 || text(rows[0][0]) != "table" || strings.HasPrefix(strings.ToUpper(strings.TrimSpace(text(rows[0][1]))), "CREATE VIRTUAL") {
		return false
	}
	without := strings.Contains(strings.ToUpper(text(rows[0][1])), "WITHOUT ROWID")
	pk := 0
	for _, c := range cols {
		if c.PrimaryKey > 0 {
			pk++
			if !c.NotNull && !without {
				return false
			}
		}
	}
	return pk > 0
}
func (s *Session) catalog(ctx context.Context, c protocol.Command, sink adapter.ResultSink) protocol.Response {
	r := c.Catalog
	if r == nil || !r.Valid() {
		return s.fail(c, ctx, errors.New("Invalid catalog request."))
	}
	if r.Kind == "completion" {
		return s.completion(ctx, c, sink)
	}
	schema := r.Schema
	if schema == "" {
		schema = "main"
	}
	if schema != "main" {
		return s.fail(c, ctx, errors.New("Catalog tools use the main database."))
	}
	var sql string
	var args []any
	switch r.Kind {
	case "schemas":
		sql = "SELECT 'main' AS name,'schema' AS kind"
	case "objects", "search":
		sql = "SELECT name,type AS kind,'main' AS schema,'' AS identity,NULL AS typeKind FROM main.sqlite_schema WHERE type IN ('table','view','trigger','index') AND substr(name,1,7) COLLATE NOCASE <> 'sqlite_' AND name NOT IN (SELECT name FROM pragma_table_list WHERE type='shadow')"
		if r.Kind == "objects" && r.ObjectKind != "" {
			sql += " AND type=?"
			args = append(args, r.ObjectKind)
		}
		if r.Kind == "search" {
			sql += " AND instr(lower(name),lower(?))>0"
			args = append(args, r.Search)
		}
		sql += " ORDER BY name"
		if !s.metadataCapture {
			sql += " LIMIT 200 OFFSET ?"
			args = append(args, r.Page*200)
		}
	case "columns":
		cols, err := s.tableInfo(ctx, schema, r.Object)
		if err != nil {
			return s.fail(c, ctx, err)
		}
		editable := s.editableTable(ctx, r.Object, cols) && !s.readOnly
		names := []string{"name", "nativeType", "nullable", "default", "generated", "primaryKey", "editable", "editReason", "comparison"}
		rows := [][]protocol.SQLiteValue{}
		for _, col := range cols {
			if col.Hidden == 1 {
				continue
			}
			reason := ""
			can := editable && col.Hidden == 0
			if !editable {
				reason = "Editing requires an ordinary table with a complete non-null primary key."
			} else if col.Hidden != 0 {
				reason = "SQLite generates this value."
			}
			def := protocol.SQLiteValue{Type: "null"}
			if col.Default != nil {
				def = stringValue(*col.Default)
			}
			native := col.NativeType
			if native == "" {
				native = "dynamic"
			}
			generated := ""
			if col.Hidden != 0 {
				generated = "generated"
			}
			rows = append(rows, []protocol.SQLiteValue{stringValue(col.Name), stringValue(native), stringValue(strconv.FormatBool(!col.NotNull)), def, stringValue(generated), stringValue(strconv.Itoa(col.PrimaryKey)), stringValue(strconv.FormatBool(can)), stringValue(reason), stringValue(sqliteComparisonJSON(col.NativeType))})
		}
		return s.catalogRows(ctx, c, names, rows, sink)
	case "referencingTables":
		if _, err := s.tableInfo(ctx, schema, r.Object); err != nil {
			return s.fail(c, ctx, err)
		}
		sql = `SELECT DISTINCT 'main' AS schema,t.name AS name,'table' AS kind
FROM main.sqlite_schema t JOIN pragma_foreign_key_list(t.name) k
WHERE t.type='table' AND substr(t.name,1,7) COLLATE NOCASE <> 'sqlite_'
AND t.name NOT IN (SELECT name FROM pragma_table_list WHERE type='shadow')
AND k."table" COLLATE NOCASE=? ORDER BY t.name COLLATE BINARY`
		args = []any{r.Object}
	case "foreignKeys":
		sql = `SELECT 'fk_'||id AS name,'main' AS targetSchema,"table" AS targetTable,"from" AS sourceColumn,"to" AS targetColumn,seq+1 AS position FROM pragma_foreign_key_list(?) ORDER BY id,seq`
		args = []any{r.Object}
	case "indexes":
		sql = `SELECT name,CASE WHEN "unique" THEN 'unique' ELSE 'index' END AS kind,(SELECT sql FROM main.sqlite_schema WHERE name=i.name) AS definition FROM pragma_index_list(?) i ORDER BY name`
		args = []any{r.Object}
	case "triggers":
		sql = "SELECT name,type AS kind,sql AS definition FROM main.sqlite_schema WHERE type='trigger' AND tbl_name=? ORDER BY name"
		args = []any{r.Object}
	case "keys", "constraints":
		sql = `SELECT name,'unique' AS kind,COALESCE((SELECT sql FROM main.sqlite_schema WHERE name=i.name),'Implicit SQLite constraint') AS definition FROM pragma_index_list(?) i WHERE "unique"=1 AND origin<>'pk' ORDER BY name`
		args = []any{r.Object}
	case "definition":
		sql = "SELECT name,sql AS definition FROM main.sqlite_schema WHERE name=?"
		args = []any{r.Object}
	case "name":
		sql = "SELECT ? AS name FROM main.sqlite_schema WHERE name=?"
		args = []any{quote(schema) + "." + quote(r.Object), r.Object}
	case "select":
		sql = "SELECT ? AS sql,? AS name FROM main.sqlite_schema WHERE name=?"
		args = []any{"SELECT * FROM " + quote(schema) + "." + quote(r.Object) + " LIMIT 200", quote(schema) + "." + quote(r.Object), r.Object}
	case "browse":
		cols, err := s.tableInfo(ctx, schema, r.Object)
		if err != nil {
			return s.fail(c, ctx, err)
		}
		if r.RelationshipScope != nil {
			if err = s.validateRelationshipScope(ctx, *r.RelationshipScope); err != nil {
				return s.fail(c, ctx, err)
			}
		}
		sql, args, err = buildBrowse(*r, cols)
		if err != nil {
			return s.fail(c, ctx, err)
		}
		old := s.internal
		s.internal = true
		defer func() { s.internal = old }()
		// Execute the bound catalog read through the same collector as SQL.
		return s.executeBound(ctx, c, sql, args, sink)
	default:
		return s.fail(c, ctx, errors.New("This SQLite catalog operation is unavailable."))
	}
	rows, names, err := s.query(ctx, sql, args...)
	if err != nil {
		return s.fail(c, ctx, err)
	}
	if r.Kind == "foreignKeys" {
		if err := s.resolveForeignKeyNames(ctx, r.Object, rows); err != nil {
			return s.fail(c, ctx, err)
		}
	}
	if r.Kind == "keys" || r.Kind == "constraints" {
		if cols, err := s.tableInfo(ctx, "main", r.Object); err == nil {
			primary := []columnInfo{}
			for _, column := range cols {
				if column.PrimaryKey > 0 {
					primary = append(primary, column)
				}
			}
			sort.Slice(primary, func(i, j int) bool { return primary[i].PrimaryKey < primary[j].PrimaryKey })
			if len(primary) > 0 {
				quoted := []string{}
				for _, col := range primary {
					quoted = append(quoted, quote(col.Name))
				}
				rows = append(rows, []protocol.SQLiteValue{stringValue("primary_key"), stringValue("primaryKey"), stringValue("PRIMARY KEY (" + strings.Join(quoted, ",") + ")")})
			}
		}
	}
	return s.catalogRows(ctx, c, names, rows, sink)
}
func stringValue(v string) protocol.SQLiteValue {
	return protocol.SQLiteValue{Type: "text", Value: base64.StdEncoding.EncodeToString([]byte(v))}
}
func (s *Session) catalogRows(ctx context.Context, c protocol.Command, names []string, rows [][]protocol.SQLiteValue, sink adapter.ResultSink) protocol.Response {
	r := protocol.Response{Type: "query.result", RequestID: c.RequestID, SessionID: c.SessionID, QueryID: c.QueryID, Connected: true, TransactionStatus: s.TransactionStatus(), Columns: []protocol.Column{}, Rows: [][]*string{}, SQLiteValues: [][]protocol.SQLiteValue{}, CommandTag: "SELECT", RowCount: int64(len(rows))}
	for i, n := range names {
		r.Columns = append(r.Columns, protocol.Column{Index: i, Name: n, Engine: "sqlite", NativeType: "dynamic"})
	}
	if sink != nil {
		if err := sink.Begin(0, r.Columns); err != nil {
			failure := s.fail(c, ctx, err)
			failure.SQLCompleted = true
			return failure
		}
	}
	bytes := 0
	for _, values := range rows {
		row := make([]*string, len(values))
		size := 0
		for i, v := range values {
			row[i] = display(v)
			size += len(v.Value) + 32
		}
		if sink != nil {
			if typed, ok := sink.(interface {
				SQLiteRow(int, []protocol.SQLiteValue) error
			}); ok {
				if err := typed.SQLiteRow(0, values); err != nil {
					failure := s.fail(c, ctx, err)
					failure.SQLCompleted = true
					return failure
				}
			}
			if err := sink.Row(0, row); err != nil {
				failure := s.fail(c, ctx, err)
				failure.SQLCompleted = true
				return failure
			}
		}
		if len(r.Rows) >= 1000 || bytes+size > 8<<20 {
			r.Truncated = true
			continue
		}
		bytes += size
		r.Rows = append(r.Rows, row)
		r.SQLiteValues = append(r.SQLiteValues, values)
	}
	r.DisplayedRowCount = len(r.Rows)
	if sink != nil {
		if err := sink.End(0, protocol.ResultSet{Columns: r.Columns, Rows: r.Rows, SQLiteValues: r.SQLiteValues, CommandTag: r.CommandTag, RowCount: r.RowCount, DisplayedRowCount: r.DisplayedRowCount, Truncated: r.Truncated, DisplayNotice: r.DisplayNotice}); err != nil {
			failure := s.fail(c, ctx, err)
			failure.SQLCompleted = true
			return failure
		}
	}
	return r
}
func buildBrowse(r protocol.CatalogRequest, cols []columnInfo) (string, []any, error) {
	known := map[string]bool{}
	var primary []columnInfo
	for _, c := range cols {
		known[c.Name] = true
		if c.PrimaryKey > 0 {
			primary = append(primary, c)
		}
	}
	sql := "SELECT * FROM main." + quote(r.Object)
	args := []any{}
	predicates := []string{}
	if r.RelationshipScope != nil {
		if !r.Valid() {
			return "", nil, errors.New("Invalid relationship scope.")
		}
		sql += " AS " + quote("__dbeer_child")
		predicate, values := relationshipPredicate(*r.RelationshipScope)
		predicates = append(predicates, predicate)
		args = append(args, values...)
	}
	expr, valid := r.EffectiveFilterExpression()
	if !valid {
		return "", nil, errors.New("Invalid filters.")
	}
	var compile func(protocol.CatalogFilterExpression) (string, error)
	compile = func(e protocol.CatalogFilterExpression) (string, error) {
		if e.Kind == "condition" {
			f := e.Condition
			if f == nil || !known[f.Column] {
				return "", errors.New("Unknown filter column.")
			}
			q := quote(f.Column)
			if f.Operator == "isNull" {
				return q + " IS NULL", nil
			}
			if f.Operator == "isNotNull" {
				return q + " IS NOT NULL", nil
			}
			if f.NativeValue != nil {
				scalar, err := browsevalue.SQLite(*f.NativeValue)
				if err != nil {
					return "", err
				}
				args = append(args, scalar)
				op := "="
				if f.Operator == "ne" {
					op = "<>"
				}
				return q + op + "?", nil
			}
			if f.SQLiteValue != nil {
				if !f.Valid() {
					return "", errors.New("Invalid SQLite filter operand.")
				}
				args = append(args, *f.SQLiteValue)
				op := "="
				if f.Operator == "ne" {
					op = "<>"
				}
				return q + op + "?", nil
			}
			if f.Value == nil {
				return "", errors.New("Missing filter operand.")
			}
			args = append(args, *f.Value)
			if f.Operator == "contains" {
				return "instr(" + q + ",?)>0", nil
			}
			op := map[string]string{"eq": "=", "ne": "<>", "lt": "<", "lte": "<=", "gt": ">", "gte": ">="}[f.Operator]
			if op == "" {
				return "", errors.New("Invalid operator.")
			}
			return q + op + "?", nil
		}
		parts := []string{}
		for _, child := range e.Children {
			p, err := compile(child)
			if err != nil {
				return "", err
			}
			parts = append(parts, p)
		}
		join := " AND "
		if e.Kind == "or" {
			join = " OR "
		}
		return "(" + strings.Join(parts, join) + ")", nil
	}
	if expr != nil {
		where, err := compile(*expr)
		if err != nil {
			return "", nil, err
		}
		predicates = append(predicates, where)
	}
	if len(predicates) > 0 {
		sql += " WHERE " + strings.Join(predicates, " AND ")
	}
	seen := map[string]bool{}
	order := []string{}
	for _, o := range r.Sort {
		if !known[o.Column] || seen[o.Column] || (o.Direction != "asc" && o.Direction != "desc") {
			return "", nil, errors.New("Invalid sort.")
		}
		seen[o.Column] = true
		order = append(order, quote(o.Column)+" "+strings.ToUpper(o.Direction))
	}
	sort.Slice(primary, func(i, j int) bool { return primary[i].PrimaryKey < primary[j].PrimaryKey })
	for _, p := range primary {
		if !seen[p.Name] {
			order = append(order, quote(p.Name)+" ASC")
		}
	}
	if len(order) > 0 {
		sql += " ORDER BY " + strings.Join(order, ",")
	}
	sql += fmt.Sprintf(" LIMIT 200 OFFSET %d", r.Page*200)
	return sql, args, nil
}
