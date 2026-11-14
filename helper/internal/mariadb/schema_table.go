package mariadb

import (
	sc "dbeer/helper/internal/schemacompare"
	"encoding/base64"
	"encoding/json"
	"fmt"
	wire "github.com/go-mysql-org/go-mysql/mysql"
	"strconv"
	"strings"
	"unicode/utf8"
)

func (r *mariaSchemaCapture) table(ref sc.Ref, row []*string) error {
	collation := mariaText(row, 2)
	charsetRows, e := r.tracked("SELECT CHARACTER_SET_NAME FROM information_schema.COLLATION_CHARACTER_SET_APPLICABILITY WHERE BINARY FULL_COLLATION_NAME=BINARY ?", collation)
	if e != nil {
		return e
	}
	if len(charsetRows) != 1 || len(charsetRows[0]) != 1 || charsetRows[0][0] == nil {
		return fmt.Errorf("%w: collation metadata", sc.ErrInvalid)
	}
	charset := *charsetRows[0][0]
	options := sc.Complete[sc.Option](nil)
	if v := mariaText(row, 3); v != "" {
		options.Items = append(options.Items, sc.Option{Name: "createOptions", Value: v})
	}
	if comment := mariaText(row, 4); comment != "" {
		options.Items = append(options.Items, sc.Option{Name: "comment", Value: comment})
	}
	t := sc.Table{Ref: ref, Kind: sc.Known("table"), Storage: sc.Known(mariaText(row, 1)), Charset: sc.Known(charset), Collation: sc.Known(sc.Ref{Kind: "collation", Name: collation}), Options: options, Columns: sc.Complete[sc.Column](nil), Constraints: sc.Complete[sc.Constraint](nil), Indexes: sc.Complete[sc.Index](nil), Dependencies: sc.Complete[sc.Dependency](nil)}
	if len(row) > 5 && mariaText(row, 5) == "SYSTEM VERSIONED" {
		t.Kind = sc.Known("systemVersioned")
	}
	if strings.Contains(mariaText(row, 3), "partitioned") && mariaText(row, 5) != "SYSTEM VERSIONED" {
		t.Kind = sc.Known("partitioned")
	}
	columns, e := r.tracked("SELECT COLUMN_NAME,ORDINAL_POSITION,DATA_TYPE,CAST(COLUMN_TYPE AS BINARY),IS_NULLABLE,CAST(COLUMN_DEFAULT AS BINARY),EXTRA,CAST(GENERATION_EXPRESSION AS BINARY),CHARACTER_SET_NAME,COLLATION_NAME,COLUMN_COMMENT,CHARACTER_MAXIMUM_LENGTH,NUMERIC_PRECISION,NUMERIC_SCALE,DATETIME_PRECISION,NULL AS SRS_ID FROM information_schema.COLUMNS WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? ORDER BY ORDINAL_POSITION", ref.Schema, ref.Name)
	if e != nil {
		return e
	}
	// Verify the owning table kind before any out-of-band native witness.
	if _, e := r.definition(ref); e != nil {
		return e
	}
	names := []string{}
	for _, v := range columns {
		if len(v) == 16 && mariaStoredDefaultType(mariaText(v, 2), mariaText(v, 8)) && v[5] != nil {
			if _, literal := mariaCatalogLiteral(*v[5]); literal {
				names = append(names, mariaText(v, 0))
			}
		}
	}
	var native map[string]*wire.Field
	if len(names) > 0 {
		native, e = r.trackNativeDefaults(ref, names)
		if e != nil {
			return e
		}
	}
	for _, v := range columns {
		if len(v) != 16 || v[0] == nil || v[1] == nil || v[2] == nil || v[3] == nil || v[4] == nil {
			return fmt.Errorf("%w: column fields", sc.ErrInvalid)
		}
		if mariaText(v, 4) != "YES" && mariaText(v, 4) != "NO" {
			return fmt.Errorf("%w: column nullability", sc.ErrInvalid)
		}
		ordinal, e := strconv.Atoi(*v[1])
		if e != nil || ordinal != len(t.Columns.Items)+1 {
			return fmt.Errorf("%w: column ordinal", sc.ErrInvalid)
		}
		name, datatype, definition, extra := mariaText(v, 0), mariaText(v, 2), mariaText(v, 3), mariaText(v, 6)
		typ := mariaSchemaType(datatype, definition, mariaText(v, 8), mariaText(v, 11), mariaText(v, 12), mariaText(v, 13), mariaText(v, 14))
		c := sc.Column{Ref: sc.Ref{Kind: "column", Schema: ref.Schema, Table: ref.Name, Name: name}, Ordinal: sc.Known(ordinal - 1), Type: sc.Known(typ), Nullable: sc.Known(mariaText(v, 4) == "YES"), Default: sc.Known(sc.Default{Kind: "none"}), Generated: sc.Known(sc.Generated{Kind: "none"}), Identity: sc.Known(sc.Identity{Kind: "none"}), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Visible: sc.Known(!strings.Contains(extra, "INVISIBLE")), Comment: sc.Known(mariaText(v, 10)), OnUpdate: sc.Absent[sc.Expression]()}
		if (datatype == "enum" || datatype == "set") && !typ.Labels.Complete {
			if e := r.issue(&c.Ref, "labels", typ.Labels.Code, "Native enum/set text metadata cannot prove the original label bytes; use an explicitly reviewed native definition."); e != nil {
				return e
			}
		}

		if v[8] != nil {
			c.Charset = sc.Known(mariaText(v, 8))
		} else if datatype == "enum" || datatype == "set" {
			c.Charset = sc.Known("binary")
		}
		if v[9] != nil {
			c.Collation = sc.Known(sc.Ref{Kind: "collation", Name: mariaText(v, 9)})
		}
		if expr := mariaText(v, 7); expr != "" {
			kind := "virtual"
			if strings.Contains(extra, "STORED GENERATED") {
				kind = "stored"
			}
			c.Generated = sc.Known(sc.Generated{Kind: kind, Expression: &sc.Expression{Text: expr, Dependencies: sc.Collection[sc.Ref]{Items: []sc.Ref{}, State: "unavailable", Code: "expressionDependencies", Complete: false}}})
		} else {
			c.Default = mariaSchemaDefault(v[5], typ, mariaText(v, 8))
		}
		if field := native[name]; field != nil {
			binary := mariaText(v, 8) == "binary" || mariaBinaryDefaultType(datatype, mariaText(v, 8))
			if binary && field.Charset != 63 {
				return fmt.Errorf("%w: binary default charset", sc.ErrInvalid)
			}
			if !binary && (field.Charset == 63 || !utf8.Valid(field.DefaultValue)) {
				return fmt.Errorf("%w: text default encoding", sc.ErrInvalid)
			}
			if field.Type != wire.MYSQL_TYPE_STRING && field.Type != wire.MYSQL_TYPE_VAR_STRING && field.Type != wire.MYSQL_TYPE_VARCHAR && field.Type != wire.MYSQL_TYPE_BLOB && field.Type != wire.MYSQL_TYPE_TINY_BLOB && field.Type != wire.MYSQL_TYPE_MEDIUM_BLOB && field.Type != wire.MYSQL_TYPE_LONG_BLOB {
				return fmt.Errorf("%w: binary default type", sc.ErrInvalid)
			}
			value, encoding := string(field.DefaultValue), "text"
			if binary {
				value = base64.StdEncoding.EncodeToString(field.DefaultValue)
				encoding = "base64"
			}
			c.Default = sc.Known(sc.Default{Kind: "literal", Type: &typ, Encoding: encoding, Value: &value})
		}
		if expr := mariaText(v, 7); expr == "ROW START" || expr == "ROW END" {
			kind := "systemRowStart"
			if expr == "ROW END" {
				kind = "systemRowEnd"
			}
			c.Generated = sc.Known(sc.Generated{Kind: kind})
			c.Default = sc.Known(sc.Default{Kind: "none"})
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
		nativeExtra := mariaUnmodeledExtra(extra)
		if strings.Contains(extra, "WITHOUT SYSTEM VERSIONING") {
			t.Options.Items = append(t.Options.Items, sc.Option{Name: "columnSystemVersioning:" + name, Value: "without"})
		}
		if nativeExtra != "" {
			t.Options.Items = append(t.Options.Items, sc.Option{Name: "columnExtra:" + name, Value: nativeExtra})
			t.Options.Complete = false
			t.Options.State = "unavailable"
			t.Options.Code = "nativeColumnProperties"
			if e := r.issue(&c.Ref, "extra", "nativeColumnProperties", "Native column properties require explicit manual review."); e != nil {
				return e
			}
		}
		t.Columns.Items = append(t.Columns.Items, c)
	}
	if mariaText(row, 5) == "SYSTEM VERSIONED" {
		metadata := make([]MariaDBPeriodColumn, 0, len(columns))
		for _, v := range columns {
			metadata = append(metadata, MariaDBPeriodColumn{Name: mariaText(v, 0), NativeType: mariaText(v, 3), DataType: mariaText(v, 2), Generated: mariaText(v, 7)})
		}
		periods, e := r.nativePeriods(ref, metadata)
		if e != nil {
			return e
		}
		for _, period := range periods {
			raw, e := json.Marshal(period)
			if e != nil {
				return sc.ErrInvalid
			}
			t.Options.Items = append(t.Options.Items, sc.Option{Name: "systemPeriod:" + period.Generated, Value: string(raw)})
		}
	}
	if strings.Contains(mariaText(row, 3), "partitioned") {
		raw := r.definitions[ref.Schema+"\x00"+ref.Name]
		tail, known := mariaPartitionTail(raw, r.sqlMode)
		if known {
			t.Options.Items = append(t.Options.Items, sc.Option{Name: "nativePartitionDefinition", Value: tail})
		} else {
			t.Options.Complete = false
			t.Options.State = "unavailable"
			t.Options.Code = "nativePartitionDefinition"
			if e := r.issue(&ref, "partition", "nativePartitionDefinition", "Native partition properties are not completely represented."); e != nil {
				return e
			}
		}
	}
	applicationPeriods, known := mariaApplicationPeriods(r.definitions[ref.Schema+"\x00"+ref.Name], r.sqlMode)
	if !known || len(applicationPeriods) > 0 {
		for _, clause := range applicationPeriods {
			t.Options.Items = append(t.Options.Items, sc.Option{Name: "nativeApplicationPeriod", Value: clause})
		}
		t.Options.Complete = false
		t.Options.State = "unavailable"
		t.Options.Code = "nativeApplicationPeriod"
		if e := r.issue(&ref, "period", "nativeApplicationPeriod", "Application-time period properties require an explicit reviewed native migration."); e != nil {
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
func mariaIntValue(s string) int { n, _ := strconv.Atoi(s); return n }
func (r *mariaSchemaCapture) constraints(table sc.Ref) ([]sc.Constraint, error) {
	rows, e := r.tracked("SELECT tc.CONSTRAINT_NAME,tc.CONSTRAINT_TYPE,'YES',cc.CHECK_CLAUSE,rc.UNIQUE_CONSTRAINT_SCHEMA,rc.REFERENCED_TABLE_NAME,rc.UPDATE_RULE,rc.DELETE_RULE,rc.MATCH_OPTION FROM information_schema.TABLE_CONSTRAINTS tc LEFT JOIN information_schema.CHECK_CONSTRAINTS cc ON BINARY cc.CONSTRAINT_SCHEMA=BINARY tc.CONSTRAINT_SCHEMA AND BINARY cc.CONSTRAINT_NAME=BINARY tc.CONSTRAINT_NAME AND BINARY cc.TABLE_NAME=BINARY tc.TABLE_NAME LEFT JOIN information_schema.REFERENTIAL_CONSTRAINTS rc ON BINARY rc.CONSTRAINT_SCHEMA=BINARY tc.CONSTRAINT_SCHEMA AND BINARY rc.TABLE_NAME=BINARY tc.TABLE_NAME AND BINARY rc.CONSTRAINT_NAME=BINARY tc.CONSTRAINT_NAME WHERE BINARY tc.TABLE_SCHEMA=BINARY ? AND BINARY tc.TABLE_NAME=BINARY ? ORDER BY BINARY tc.CONSTRAINT_NAME", table.Schema, table.Name)
	if e != nil {
		return nil, e
	}
	out := []sc.Constraint{}
	for _, v := range rows {
		if len(v) != 9 || v[0] == nil || v[1] == nil {
			return nil, fmt.Errorf("%w: constraint metadata", sc.ErrInvalid)
		}
		ref := sc.Ref{Kind: "constraint", Schema: table.Schema, Table: table.Name, Name: mariaText(v, 0)}
		kind := map[string]string{"PRIMARY KEY": "p", "UNIQUE": "u", "FOREIGN KEY": "f", "CHECK": "c"}[mariaText(v, 1)]
		c := sc.NewConstraint(ref, kind)
		c.Enforced = sc.Known(mariaText(v, 2) == "YES")
		if kind == "p" || kind == "u" {
			c.BackingIndex = sc.Known(sc.Ref{Kind: "index", Schema: table.Schema, Table: table.Name, Name: ref.Name})
			c.NullsDistinct = sc.Known(true)
		}
		if v[3] != nil {
			c.Check = sc.Known(sc.Expression{Text: *v[3], Dependencies: sc.Collection[sc.Ref]{Items: []sc.Ref{}, State: "unavailable", Code: "expressionDependencies"}})
		}
		keys, e := r.tracked("SELECT COLUMN_NAME,REFERENCED_TABLE_SCHEMA,REFERENCED_TABLE_NAME,REFERENCED_COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? AND BINARY CONSTRAINT_NAME=BINARY ? ORDER BY ORDINAL_POSITION", table.Schema, table.Name, ref.Name)
		if e != nil {
			return nil, e
		}
		for _, k := range keys {
			if len(k) != 4 || k[0] == nil {
				return nil, fmt.Errorf("%w: constraint column metadata", sc.ErrInvalid)
			}
			source := sc.Ref{Kind: "column", Schema: table.Schema, Table: table.Name, Name: mariaText(k, 0)}
			c.Columns.Items = append(c.Columns.Items, source)
			if k[3] != nil {
				c.ForeignKeys.Items = append(c.ForeignKeys.Items, sc.ColumnPair{Source: source, Target: sc.Ref{Kind: "column", Schema: mariaText(k, 1), Table: mariaText(k, 2), Name: mariaText(k, 3)}})
			}
		}
		if kind == "f" {
			c.Target = sc.Known(sc.Ref{Kind: "table", Schema: mariaText(v, 4), Name: mariaText(v, 5)})
			c.Update = sc.Known(mariaText(v, 6))
			c.Delete = sc.Known(mariaText(v, 7))
			c.Match = sc.Known(mariaText(v, 8))
		}
		out = append(out, c)
	}
	return out, nil
}
func (r *mariaSchemaCapture) indexes(table sc.Ref, constraints []sc.Constraint) ([]sc.Index, error) {
	rows, e := r.tracked("SELECT INDEX_NAME,NON_UNIQUE,SEQ_IN_INDEX,COLUMN_NAME,COLLATION,SUB_PART,INDEX_TYPE,IGNORED,NULL AS EXPRESSION,INDEX_COMMENT FROM information_schema.STATISTICS WHERE BINARY TABLE_SCHEMA=BINARY ? AND BINARY TABLE_NAME=BINARY ? ORDER BY BINARY INDEX_NAME,SEQ_IN_INDEX", table.Schema, table.Name)
	if e != nil {
		return nil, e
	}
	rawDefinition, present := r.definitions[table.Schema+"\x00"+table.Name]
	var err error
	if !present {
		rawDefinition, err = r.definition(table)
	}
	if err != nil {
		return nil, err
	}
	attributes, known, parsed := mariaIndexAttributeEvidence(rawDefinition, r.sqlMode)
	r.indexAttributes = attributes

	out := []sc.Index{}
	for _, v := range rows {
		if len(v) != 10 || v[0] == nil || v[1] == nil || v[2] == nil || v[3] == nil || (mariaText(v, 7) != "YES" && mariaText(v, 7) != "NO") {
			return nil, fmt.Errorf("%w: index metadata", sc.ErrInvalid)
		}
		name := mariaText(v, 0)
		if len(out) == 0 || out[len(out)-1].Ref.Name != name {
			x := sc.Index{Ref: sc.Ref{Kind: "index", Schema: table.Schema, Table: table.Name, Name: name}, Method: sc.Known(mariaText(v, 6)), Unique: sc.Known(mariaText(v, 1) == "0"), NullsDistinct: sc.Known(true), Keys: sc.Complete[sc.IndexKey](nil), Includes: sc.Complete[sc.Ref](nil), Predicate: sc.Absent[sc.Expression](), Options: sc.Complete[sc.Option](nil), Visible: sc.Known(mariaText(v, 7) == "NO"), Valid: sc.Known(true), Ready: sc.Known(true), Constraint: sc.Absent[sc.Ref]()}
			for _, c := range constraints {
				if c.BackingIndex.Value != nil && c.BackingIndex.Value.Name == name {
					x.Constraint = sc.Known(c.Ref)
				}
			}
			if method := mariaText(v, 6); method != "BTREE" && method != "HASH" && method != "SPATIAL" && method != "RTREE" && method != "FULLTEXT" {
				x.Method = sc.Unknown[string]("indexMethod")
			}
			if mariaText(v, 9) != "" {
				x.Options.Items = append(x.Options.Items, sc.Option{Name: "comment", Value: mariaText(v, 9)})
			}
			if !parsed || !known[name] {
				if r.indexAttributes == nil {
					r.indexAttributes = map[string]map[string]string{}
				}
				r.indexAttributes[name] = map[string]string{"reason": "unrecognized SHOW CREATE index metadata", "definition": rawDefinition}
			}
			if attrs := r.indexAttributes[name]; len(attrs) > 0 {
				x.Options.Complete = false
				x.Options.State = "unavailable"
				x.Options.Code = "unmodeledIndexProperties"
				if err := r.issue(&x.Ref, "index", "unmodeledIndexProperties", "Index properties require an explicit reviewed migration: "+attrs["reason"]); err != nil {
					return nil, err
				}
			}
			out = append(out, x)
		}
		key := sc.IndexKey{Column: sc.Absent[sc.Ref](), Expression: sc.Absent[sc.Expression](), Opclass: sc.Absent[sc.Ref](), Collation: sc.Absent[sc.Ref](), Descending: sc.Known(mariaText(v, 4) == "D"), NullsFirst: sc.Known(mariaText(v, 4) != "D"), PrefixLength: sc.Absent[int64](), Options: sc.Complete[sc.Option](nil)}
		if v[3] != nil {
			key.Column = sc.Known(sc.Ref{Kind: "column", Schema: table.Schema, Table: table.Name, Name: *v[3]})
		}
		if v[8] != nil {
			key.Expression = sc.Known(sc.Expression{Text: *v[8], Dependencies: sc.Collection[sc.Ref]{Items: []sc.Ref{}, State: "unavailable", Code: "expressionDependencies"}})
		}
		// RTREE SUB_PART describes the internal MBR key, not a SQL prefix.
		if v[4] == nil {
			key.Descending = sc.Absent[bool]()
			key.NullsFirst = sc.Absent[bool]()
		}
		if n := mariaNumber(mariaText(v, 5)); n != nil && mariaText(v, 6) != "RTREE" && mariaText(v, 6) != "SPATIAL" {
			key.PrefixLength = sc.Known(*n)
		}
		out[len(out)-1].Keys.Items = append(out[len(out)-1].Keys.Items, key)
	}
	return out, nil
}

func mariaBinaryDefaultType(kind, charset string) bool {
	if (kind == "enum" || kind == "set") && (charset == "" || charset == "binary") {
		return true
	}
	switch kind {
	case "binary", "varbinary", "blob", "tinyblob", "mediumblob", "longblob":
		return true
	}
	return false
}

func mariaStoredDefaultType(kind, charset string) bool {
	if mariaBinaryDefaultType(kind, charset) {
		return true
	}
	switch kind {
	case "char", "varchar", "tinytext", "text", "mediumtext", "longtext", "enum", "set":
		return true
	}
	return false
}
