package mysql

import (
	"context"
	"crypto/sha256"
	"dbeer/helper/internal/protocol"
	sc "dbeer/helper/internal/schemacompare"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	wire "github.com/go-mysql-org/go-mysql/mysql"
	"strconv"
	"strings"
	"time"
)

type mysqlSchemaRead struct {
	sql    string
	args   []any
	digest string
}
type mysqlSchemaCapture struct {
	s                 *Session
	spec              sc.CaptureSpec
	sink              sc.Sink
	reads             []mysqlSchemaRead
	members           int
	sqlMode           string
	explicitTimestamp bool
	gipk              bool
}

func (s *Session) ReadSchema(ctx context.Context, spec sc.CaptureSpec, sink sc.Sink) error {
	var captured error
	reply := s.executeWith(ctx, protocol.Command{}, func(_ *collector, _ *wire.Result) error {
		r := &mysqlSchemaCapture{s: s, spec: spec, sink: sink}
		captured = r.capture()
		return captured
	})
	if captured != nil {
		return captured
	}
	if reply.Type != "query.result" {
		return sc.ErrInvalid
	}
	return nil
}
func (r *mysqlSchemaCapture) rows(sql string, args ...any) ([][]*string, error) {
	loaded, e := r.s.work.client.Execute(sql+" LIMIT "+strconv.Itoa(r.spec.Limits.Members+1), args...)
	if e != nil {
		return nil, e
	}
	defer loaded.Close()
	if loaded.RowNumber() > r.spec.Limits.Members || loaded.Warnings > 0 {
		return nil, sc.ErrLimit
	}
	rows := make([][]*string, loaded.RowNumber())
	for i := range rows {
		rows[i] = make([]*string, len(loaded.Fields))
		for j := range loaded.Fields {
			if loaded.Values[i][j].Type == wire.FieldValueTypeNull {
				continue
			}
			v, e := loaded.GetString(i, j)
			if e != nil {
				return nil, e
			}
			if len(v) > r.spec.Limits.Scalar {
				return nil, sc.ErrLimit
			}
			v = strings.Clone(v)
			rows[i][j] = &v
		}
	}
	return rows, nil
}
func (r *mysqlSchemaCapture) tracked(sql string, args ...any) ([][]*string, error) {
	rows, e := r.rows(sql, args...)
	if e == nil {
		b, _ := json.Marshal(mysqlRawRows(rows))
		d := sha256.Sum256(b)
		r.reads = append(r.reads, mysqlSchemaRead{sql, args, hex.EncodeToString(d[:])})
	}
	return rows, e
}
func myText(row []*string, i int) string {
	if row[i] == nil {
		return ""
	}
	return *row[i]
}
func myNumber(s string) *int64 {
	if s == "" {
		return nil
	}
	n, e := strconv.ParseInt(s, 10, 64)
	if e != nil {
		return nil
	}
	return &n
}
func (r *mysqlSchemaCapture) issue(ref *sc.Ref, p, code, message string) error {
	return r.sink.Issue(sc.Issue{Ref: ref, Property: p, Code: code, Message: message, BlocksEquality: true, Planning: "manual"})
}
func (r *mysqlSchemaCapture) capture() error {
	started := time.Now().UTC().Format(time.RFC3339Nano)
	rows, e := r.rows("SELECT VERSION(),DATABASE(),@@sql_mode,@@explicit_defaults_for_timestamp,CURRENT_USER(),CURRENT_ROLE(),@@lower_case_table_names,@@partial_revokes")
	if e != nil || len(rows) != 1 {
		return sc.ErrInvalid
	}
	v := rows[0]
	version := myText(v, 0)
	parts := strings.Split(version, ".")
	if len(parts) < 3 || parts[0] != "8" && parts[0] != "9" || strings.Contains(strings.ToLower(version), "mariadb") {
		return sc.ErrInvalid
	}
	minor, _ := strconv.Atoi(parts[1])
	patch, _ := strconv.Atoi(strings.Split(parts[2], "-")[0])
	if parts[0] == "8" && minor == 0 && patch < 30 {
		return sc.ErrInvalid
	}
	r.sqlMode = myText(v, 2)
	r.explicitTimestamp = myText(v, 3) == "1"
	r.gipk = true
	probe, e := r.s.work.client.Execute("SET SESSION show_gipk_in_create_table_and_information_schema = ON")
	if e != nil {
		r.gipk = false
	} else {
		probe.Close()
	}
	capture := sc.CaptureContext{Engine: "mysql", Version: version, Database: myText(v, 1), StartedAt: started, Consistency: "bestEffort", Visibility: "complete", EngineContext: sc.Known([]sc.Option{{Name: "sqlMode", Value: r.sqlMode}, {Name: "explicitDefaultsForTimestamp", Value: myText(v, 3)}, {Name: "lowerCaseTableNames", Value: myText(v, 6)}})}
	principal := myText(v, 4)
	user, host, valid := strings.Cut(principal, "@")
	grantProof := valid && strings.Count(principal, "@") == 1 && myText(v, 5) == "NONE" && myText(v, 7) == "0"
	grantee := "'" + strings.ReplaceAll(user, "'", "''") + "'@'" + strings.ReplaceAll(host, "'", "''") + "'"
	global := false
	if grantProof {
		grants, e := r.rows("SELECT PRIVILEGE_TYPE FROM information_schema.USER_PRIVILEGES WHERE GRANTEE=? AND PRIVILEGE_TYPE='SELECT'", grantee)
		if e != nil {
			return e
		}
		global = len(grants) > 0
	}
	for _, schema := range r.spec.Schemas {
		visible := global
		if grantProof && !visible {
			grants, e := r.rows("SELECT PRIVILEGE_TYPE FROM information_schema.SCHEMA_PRIVILEGES WHERE GRANTEE=? AND TABLE_SCHEMA=? AND PRIVILEGE_TYPE='SELECT'", grantee, schema)
			if e != nil {
				return e
			}
			visible = len(grants) > 0
		}
		inv := sc.Inventory{Schema: schema, Existence: "unknown", Tables: sc.Complete[sc.Ref](nil), Types: sc.Complete[sc.Ref](nil)}
		schemas, e := r.tracked("SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME=?", schema)
		if e != nil {
			return e
		}
		if len(schemas) > 0 {
			inv.Existence = "present"
		} else if visible {
			inv.Existence = "absent"
		}
		if !visible {
			capture.Visibility = "unknown"
			inv.Tables.Complete = false
			inv.Types.Complete = false
			if e = r.issue(nil, "inventory", "visibilityUnknown", "Schema-wide metadata visibility could not be proven from direct grants."); e != nil {
				return e
			}
		}
		tables, e := r.tracked("SELECT TABLE_NAME,ENGINE,TABLE_COLLATION,CREATE_OPTIONS,TABLE_COMMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA=? AND TABLE_TYPE='BASE TABLE' ORDER BY BINARY TABLE_NAME", schema)
		if e != nil {
			return e
		}
		if len(tables) > r.spec.Limits.Nodes {
			return sc.ErrLimit
		}
		for _, row := range tables {
			ref := sc.Ref{Kind: "table", Schema: schema, Name: myText(row, 0)}
			inv.Tables.Items = append(inv.Tables.Items, ref)
			if e = r.table(ref, row); e != nil {
				return e
			}
		}
		if e = r.sink.Inventory(inv); e != nil {
			return e
		}
	}
	for _, read := range r.reads {
		rows, e := r.rows(read.sql, read.args...)
		if e != nil {
			return e
		}
		b, _ := json.Marshal(mysqlRawRows(rows))
		d := sha256.Sum256(b)
		if hex.EncodeToString(d[:]) != read.digest {
			capture.Visibility = "partial"
			if e = r.issue(nil, "capture", "concurrentDDL", "Metadata changed during the best-effort capture."); e != nil {
				return e
			}
			break
		}
	}
	capture.FinishedAt = time.Now().UTC().Format(time.RFC3339Nano)
	return r.sink.Context(capture)
}
func (r *mysqlSchemaCapture) table(ref sc.Ref, row []*string) error {
	collation := myText(row, 2)
	charset := strings.Split(collation, "_")[0]
	options := sc.Complete[sc.Option](nil)
	if v := myText(row, 3); v != "" {
		options.Items = append(options.Items, sc.Option{Name: "createOptions", Value: v})
	}
	if comment := myText(row, 4); comment != "" {
		options.Items = append(options.Items, sc.Option{Name: "comment", Value: comment})
	}
	t := sc.Table{Ref: ref, Kind: sc.Known("table"), Storage: sc.Known(myText(row, 1)), Charset: sc.Known(charset), Collation: sc.Known(sc.Ref{Kind: "collation", Name: collation}), Options: options, Columns: sc.Complete[sc.Column](nil), Constraints: sc.Complete[sc.Constraint](nil), Indexes: sc.Complete[sc.Index](nil), Dependencies: sc.Complete[sc.Dependency](nil)}
	if myText(row, 1) != "InnoDB" || myText(row, 3) != "" {
		t.Kind = sc.Unknown[string]("tableEngineOrOptions")
		if e := r.issue(&ref, "kind", "tableEngineOrOptions", "Non-InnoDB, partitioning or table options require manual review."); e != nil {
			return e
		}
	}
	columns, e := r.tracked("SELECT COLUMN_NAME,ORDINAL_POSITION,DATA_TYPE,COLUMN_TYPE,IS_NULLABLE,COLUMN_DEFAULT,EXTRA,GENERATION_EXPRESSION,CHARACTER_SET_NAME,COLLATION_NAME,COLUMN_COMMENT,CHARACTER_MAXIMUM_LENGTH,NUMERIC_PRECISION,NUMERIC_SCALE,DATETIME_PRECISION,SRS_ID FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=? AND TABLE_NAME=? ORDER BY ORDINAL_POSITION", ref.Schema, ref.Name)
	if e != nil {
		return e
	}
	for _, v := range columns {
		r.members++
		if r.members > r.spec.Limits.Members {
			return sc.ErrLimit
		}
		name, datatype, definition, extra := myText(v, 0), myText(v, 2), myText(v, 3), myText(v, 6)
		typ := mysqlSchemaType(datatype, definition, myText(v, 8), myText(v, 11), myText(v, 12), myText(v, 13), myText(v, 14), myText(v, 15))
		c := sc.Column{Ref: sc.Ref{Kind: "column", Schema: ref.Schema, Table: ref.Name, Name: name}, Ordinal: sc.Known(intValue(myText(v, 1)) - 1), Type: sc.Known(typ), Nullable: sc.Known(myText(v, 4) == "YES"), Default: sc.Known(sc.Default{Kind: "none"}), Generated: sc.Known(sc.Generated{Kind: "none"}), Identity: sc.Known(sc.Identity{Kind: "none"}), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Visible: sc.Known(!strings.Contains(extra, "INVISIBLE")), Comment: sc.Known(myText(v, 10)), OnUpdate: sc.Absent[sc.Expression]()}
		if v[8] != nil {
			c.Charset = sc.Known(myText(v, 8))
		} else if datatype == "enum" || datatype == "set" {
			c.Charset = sc.Known("binary")
		}
		if v[9] != nil {
			c.Collation = sc.Known(sc.Ref{Kind: "collation", Name: myText(v, 9)})
		}
		if expr := myText(v, 7); expr != "" {
			kind := "virtual"
			if strings.Contains(extra, "STORED GENERATED") {
				kind = "stored"
			}
			c.Generated = sc.Known(sc.Generated{Kind: kind, Expression: &sc.Expression{Text: expr, Dependencies: sc.Collection[sc.Ref]{Items: []sc.Ref{}, State: "unavailable", Code: "expressionDependencies", Complete: false}}})
		} else if v[5] != nil {
			if strings.Contains(extra, "DEFAULT_GENERATED") {
				c.Default = sc.Known(sc.Default{Kind: "expression", Expression: &sc.Expression{Text: *v[5], Dependencies: sc.Collection[sc.Ref]{Items: []sc.Ref{}, State: "unavailable", Code: "expressionDependencies", Complete: false}}})
			} else {
				value := *v[5]
				c.Default = sc.Known(sc.Default{Kind: "literal", Type: &typ, Encoding: "text", Value: &value})
				if datatype == "binary" || datatype == "varbinary" || typ.LabelEncoding == "base64" {
					// I_S renders binary defaults as 0x... and older supported
					// servers truncate that representation at the first NUL.
					// Evaluate the constant default without reading table rows.
					defaults, err := r.tracked("SELECT HEX(DEFAULT(t." + QuoteIdentifier(name) + ")) FROM " + QuoteIdentifier(ref.Schema) + "." + QuoteIdentifier(ref.Name) + " AS t RIGHT JOIN (SELECT 1 AS n) AS d ON FALSE")
					if err != nil {
						return err
					}
					if len(defaults) != 1 || defaults[0][0] == nil {
						return sc.ErrInvalid
					}
					bytes, err := hex.DecodeString(*defaults[0][0])
					if err != nil {
						return sc.ErrInvalid
					}
					value = base64.StdEncoding.EncodeToString(bytes)
					c.Default = sc.Known(sc.Default{Kind: "literal", Type: &typ, Encoding: "base64", Value: &value})
				}
			}
		} else if c.Nullable.Value != nil && *c.Nullable.Value {
			c.Default = sc.Known(sc.Default{Kind: "sqlNull"})
		}
		if datatype == "timestamp" && !r.explicitTimestamp {
			c.Default = sc.Unknown[sc.Default]("implicitTimestampDefault")
		}
		if strings.Contains(extra, "auto_increment") {
			c.Identity = sc.Known(sc.Identity{Kind: "autoIncrement"})
		}
		if _, update, ok := strings.Cut(extra, "on update "); ok {
			c.OnUpdate = sc.Known(sc.Expression{Text: strings.TrimSuffix(update, " INVISIBLE"), Dependencies: sc.Complete[sc.Ref](nil)})
		}
		t.Columns.Items = append(t.Columns.Items, c)
	}
	if !r.gipk {
		t.Columns.Complete = false
		t.Constraints.Complete = false
		t.Indexes.Complete = false
		if e = r.issue(&ref, "columns", "hiddenGIPK", "Generated invisible primary-key visibility could not be enabled."); e != nil {
			return e
		}
	}
	constraints, e := r.constraints(ref)
	if e != nil {
		return e
	}
	t.Constraints.Items = constraints
	indexes, e := r.indexes(ref, constraints)
	if e != nil {
		return e
	}
	t.Indexes.Items = indexes
	return r.sink.Table(t)
}
func intValue(s string) int { n, _ := strconv.Atoi(s); return n }
func (r *mysqlSchemaCapture) constraints(table sc.Ref) ([]sc.Constraint, error) {
	rows, e := r.tracked("SELECT tc.CONSTRAINT_NAME,tc.CONSTRAINT_TYPE,tc.ENFORCED,cc.CHECK_CLAUSE,rc.UNIQUE_CONSTRAINT_SCHEMA,rc.REFERENCED_TABLE_NAME,rc.UPDATE_RULE,rc.DELETE_RULE,rc.MATCH_OPTION FROM information_schema.TABLE_CONSTRAINTS tc LEFT JOIN information_schema.CHECK_CONSTRAINTS cc ON cc.CONSTRAINT_SCHEMA=tc.CONSTRAINT_SCHEMA AND cc.CONSTRAINT_NAME=tc.CONSTRAINT_NAME LEFT JOIN information_schema.REFERENTIAL_CONSTRAINTS rc ON rc.CONSTRAINT_SCHEMA=tc.CONSTRAINT_SCHEMA AND rc.TABLE_NAME=tc.TABLE_NAME AND rc.CONSTRAINT_NAME=tc.CONSTRAINT_NAME WHERE tc.TABLE_SCHEMA=? AND tc.TABLE_NAME=? ORDER BY BINARY tc.CONSTRAINT_NAME", table.Schema, table.Name)
	if e != nil {
		return nil, e
	}
	out := []sc.Constraint{}
	for _, v := range rows {
		ref := sc.Ref{Kind: "constraint", Schema: table.Schema, Table: table.Name, Name: myText(v, 0)}
		kind := map[string]string{"PRIMARY KEY": "p", "UNIQUE": "u", "FOREIGN KEY": "f", "CHECK": "c"}[myText(v, 1)]
		c := sc.NewConstraint(ref, kind)
		c.Enforced = sc.Known(myText(v, 2) == "YES")
		if kind == "p" || kind == "u" {
			c.BackingIndex = sc.Known(sc.Ref{Kind: "index", Schema: table.Schema, Table: table.Name, Name: ref.Name})
			c.NullsDistinct = sc.Known(true)
		}
		if v[3] != nil {
			c.Check = sc.Known(sc.Expression{Text: *v[3], Dependencies: sc.Collection[sc.Ref]{Items: []sc.Ref{}, State: "unavailable", Code: "expressionDependencies"}})
		}
		keys, e := r.tracked("SELECT COLUMN_NAME,REFERENCED_TABLE_SCHEMA,REFERENCED_TABLE_NAME,REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA=? AND TABLE_NAME=? AND CONSTRAINT_NAME=? ORDER BY ORDINAL_POSITION", table.Schema, table.Name, ref.Name)
		if e != nil {
			return nil, e
		}
		for _, k := range keys {
			source := sc.Ref{Kind: "column", Schema: table.Schema, Table: table.Name, Name: myText(k, 0)}
			c.Columns.Items = append(c.Columns.Items, source)
			if k[3] != nil {
				c.ForeignKeys.Items = append(c.ForeignKeys.Items, sc.ColumnPair{Source: source, Target: sc.Ref{Kind: "column", Schema: myText(k, 1), Table: myText(k, 2), Name: myText(k, 3)}})
			}
		}
		if kind == "f" {
			c.Target = sc.Known(sc.Ref{Kind: "table", Schema: myText(v, 4), Name: myText(v, 5)})
			c.Update = sc.Known(myText(v, 6))
			c.Delete = sc.Known(myText(v, 7))
			c.Match = sc.Known(myText(v, 8))
		}
		out = append(out, c)
	}
	return out, nil
}
func (r *mysqlSchemaCapture) indexes(table sc.Ref, constraints []sc.Constraint) ([]sc.Index, error) {
	rows, e := r.tracked("SELECT INDEX_NAME,NON_UNIQUE,SEQ_IN_INDEX,COLUMN_NAME,COLLATION,SUB_PART,INDEX_TYPE,IS_VISIBLE,EXPRESSION,INDEX_COMMENT FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=? AND TABLE_NAME=? ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX", table.Schema, table.Name)
	if e != nil {
		return nil, e
	}
	out := []sc.Index{}
	for _, v := range rows {
		name := myText(v, 0)
		if len(out) == 0 || out[len(out)-1].Ref.Name != name {
			x := sc.Index{Ref: sc.Ref{Kind: "index", Schema: table.Schema, Table: table.Name, Name: name}, Method: sc.Known(myText(v, 6)), Unique: sc.Known(myText(v, 1) == "0"), NullsDistinct: sc.Known(true), Keys: sc.Complete[sc.IndexKey](nil), Includes: sc.Complete[sc.Ref](nil), Predicate: sc.Absent[sc.Expression](), Options: sc.Complete[sc.Option](nil), Visible: sc.Known(myText(v, 7) == "YES"), Valid: sc.Known(true), Ready: sc.Known(true), Constraint: sc.Absent[sc.Ref]()}
			for _, c := range constraints {
				if c.BackingIndex.Value != nil && c.BackingIndex.Value.Name == name {
					x.Constraint = sc.Known(c.Ref)
				}
			}
			if method := myText(v, 6); method != "BTREE" && method != "HASH" && method != "SPATIAL" && method != "RTREE" {
				x.Method = sc.Unknown[string]("indexMethod")
			}
			if myText(v, 9) != "" {
				x.Options.Items = append(x.Options.Items, sc.Option{Name: "comment", Value: myText(v, 9)})
			}
			out = append(out, x)
		}
		key := sc.IndexKey{Column: sc.Absent[sc.Ref](), Expression: sc.Absent[sc.Expression](), Opclass: sc.Absent[sc.Ref](), Collation: sc.Absent[sc.Ref](), Descending: sc.Known(myText(v, 4) == "D"), NullsFirst: sc.Known(myText(v, 4) != "D"), PrefixLength: sc.Absent[int64](), Options: sc.Complete[sc.Option](nil)}
		if v[3] != nil {
			key.Column = sc.Known(sc.Ref{Kind: "column", Schema: table.Schema, Table: table.Name, Name: *v[3]})
		}
		if v[8] != nil {
			key.Expression = sc.Known(sc.Expression{Text: *v[8], Dependencies: sc.Collection[sc.Ref]{Items: []sc.Ref{}, State: "unavailable", Code: "expressionDependencies"}})
		}
		// RTREE SUB_PART is the internal MBR key length, not a declared SQL
		// prefix. MySQL rejects a prefix length on a SPATIAL index.
		if n := myNumber(myText(v, 5)); n != nil && myText(v, 6) != "RTREE" && myText(v, 6) != "SPATIAL" {
			key.PrefixLength = sc.Known(*n)
		}
		out[len(out)-1].Keys.Items = append(out[len(out)-1].Keys.Items, key)
	}
	return out, nil
}
