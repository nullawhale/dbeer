package postgres

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"fmt"
	"github.com/jackc/pgx/v5"
	"sort"
	"strconv"
	"strings"
	"time"
)

type schemaQuery interface {
	Query(context.Context, string, ...any) (pgx.Rows, error)
}

type schemaCapture struct {
	indexAttributes          map[string]map[string]string
	indexBuiltinFunctions    map[string][]string
	indexDefaultCollations   map[string][]bool
	skipCustomTypeFormatting bool
	rawExpressions           map[string]string
	ctx                      context.Context
	tx                       schemaQuery
	sink                     sc.Sink
	spec                     sc.CaptureSpec
	version                  int
	members                  int
	types                    map[string]sc.TypeUse
	loading                  map[string]bool
	sequences                map[string]bool
}

// Every query runs in a new read-only repeatable-read transaction. No editor
// transaction, displayed DDL, row data, OID identity or sequence counter escapes.
func (s *Session) ReadSchema(ctx context.Context, spec sc.CaptureSpec, sink sc.Sink) error {
	tx, e := s.conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if e != nil {
		return e
	}
	defer func() {
		c, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = tx.Rollback(c)
	}()
	if _, e = tx.Exec(ctx, "SET LOCAL search_path = pg_catalog"); e != nil {
		return e
	}
	r := &schemaCapture{ctx: ctx, tx: tx, sink: sink, spec: spec, types: map[string]sc.TypeUse{}, loading: map[string]bool{}, sequences: map[string]bool{}}
	started := time.Now().UTC().Format(time.RFC3339Nano)
	rows, e := r.rows("SELECT pg_catalog.current_setting('server_version_num'),pg_catalog.version(),pg_catalog.current_database()")
	if e != nil || len(rows) != 1 {
		return sc.ErrInvalid
	}
	r.version, _ = strconv.Atoi(rows[0][0])
	if r.version < 140000 {
		return sc.ErrInvalid
	}
	capture := sc.CaptureContext{Engine: "postgresql", Version: rows[0][1], Database: rows[0][2], StartedAt: started, Consistency: "repeatableRead", Visibility: "complete", EngineContext: sc.Known([]sc.Option{})}
	actual := "''"
	if r.version >= 150000 {
		actual = "COALESCE(pg_catalog.pg_database_collation_actual_version(d.oid),'')"
	}
	collations, e := r.rows("SELECT datcollate,datctype,COALESCE(pg_catalog.to_jsonb(d)->>'datlocprovider',''),COALESCE(pg_catalog.to_jsonb(d)->>'datlocale',pg_catalog.to_jsonb(d)->>'daticulocale',''),COALESCE(pg_catalog.to_jsonb(d)->>'daticurules',''),COALESCE(pg_catalog.to_jsonb(d)->>'datcollversion','')," + actual + " FROM pg_catalog.pg_database d WHERE datname=pg_catalog.current_database()")
	if e != nil {
		return e
	}
	if len(collations) == 1 {
		options := []sc.Option{}
		for i, name := range []string{"collation", "ctype", "localeProvider", "locale", "icuRules", "collationVersion", "actualCollationVersion"} {
			options = append(options, sc.Option{Name: name, Value: collations[0][i]})
		}
		capture.EngineContext = sc.Known(options)
	}
	for _, schema := range spec.Schemas {
		inv := sc.Inventory{Schema: schema, Existence: "absent", Tables: sc.Complete[sc.Ref](nil), Types: sc.Complete[sc.Ref](nil)}
		names, e := r.rows("SELECT n.oid::pg_catalog.text,pg_catalog.has_schema_privilege(n.oid,'USAGE')::pg_catalog.text FROM pg_catalog.pg_namespace n WHERE n.nspname=$1", schema)
		if e != nil {
			return e
		}
		if len(names) == 0 {
			if e = sink.Inventory(inv); e != nil {
				return e
			}
			continue
		}
		inv.Existence = "present"
		if names[0][1] != "true" {
			capture.Visibility = "partial"
			inv.Tables.Complete = false
			inv.Types.Complete = false
			if e = r.issue(nil, "inventory", "inaccessible", "Schema access is unavailable."); e != nil {
				return e
			}
		}
		tables, e := r.rows("SELECT c.oid::pg_catalog.text,c.relname,c.relkind::pg_catalog.text,c.relpersistence::pg_catalog.text,c.relispartition::pg_catalog.text,(c.reloftype<>0)::pg_catalog.text,EXISTS(SELECT 1 FROM pg_catalog.pg_inherits WHERE inhrelid=c.oid)::pg_catalog.text,COALESCE(pg_catalog.array_to_json(c.reloptions)::pg_catalog.text,'[]'),pg_catalog.has_table_privilege(c.oid,'SELECT')::pg_catalog.text FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND (pg_catalog.chareq(c.relkind,'r') OR pg_catalog.chareq(c.relkind,'p') OR pg_catalog.chareq(c.relkind,'f')) ORDER BY c.relname COLLATE pg_catalog.\"C\"", schema)
		if e != nil {
			return e
		}
		if len(tables) > spec.Limits.Nodes {
			return sc.ErrLimit
		}
		for _, row := range tables {
			ref := sc.Ref{Kind: "table", Schema: schema, Name: row[1]}
			inv.Tables.Items = append(inv.Tables.Items, ref)
			if e = r.table(ref, row); e != nil {
				return e
			}
		}
		types, e := r.rows("SELECT t.oid::pg_catalog.text,t.typname FROM pg_catalog.pg_type t JOIN pg_catalog.pg_namespace n ON n.oid=t.typnamespace WHERE n.nspname=$1 AND (pg_catalog.chareq(t.typtype,'b') OR pg_catalog.chareq(t.typtype,'e') OR pg_catalog.chareq(t.typtype,'d') OR pg_catalog.chareq(t.typtype,'c') OR pg_catalog.chareq(t.typtype,'r') OR pg_catalog.chareq(t.typtype,'m')) AND NOT (EXISTS(SELECT 1 FROM pg_catalog.pg_type element WHERE element.oid=t.typelem AND element.typarray=t.oid)) AND (t.typrelid=0 OR EXISTS(SELECT 1 FROM pg_catalog.pg_class c WHERE c.oid=t.typrelid AND c.relkind='c')) ORDER BY t.typname COLLATE pg_catalog.\"C\"", schema)
		if e != nil {
			return e
		}
		if len(types)+len(tables) > spec.Limits.Nodes {
			return sc.ErrLimit
		}
		for _, t := range types {
			inv.Types.Items = append(inv.Types.Items, sc.Ref{Kind: "type", Schema: schema, Name: t[1]})
			if _, e = r.typeUse(t[0], -1, 0); e != nil {
				return e
			}
		}
		if e = sink.Inventory(inv); e != nil {
			return e
		}
	}
	capture.FinishedAt = time.Now().UTC().Format(time.RFC3339Nano)
	if e = sink.Context(capture); e != nil {
		return e
	}
	return tx.Commit(ctx)
}
func (r *schemaCapture) rows(sql string, args ...any) ([][]string, error) {
	queryArgs := append([]any{pgx.QueryExecModeExec}, args...)
	rows, e := r.tx.Query(r.ctx, sql, queryArgs...)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := [][]string{}
	for rows.Next() {
		if len(out) >= r.spec.Limits.Members {
			return nil, sc.ErrLimit
		}
		values, e := rows.Values()
		if e != nil {
			return nil, e
		}
		row := make([]string, len(values))
		for i, v := range values {
			if v != nil {
				row[i] = fmt.Sprint(v)
			}
			if len(row[i]) > r.spec.Limits.Scalar {
				return nil, sc.ErrLimit
			}
		}
		out = append(out, row)
	}
	return out, rows.Err()
}
func (r *schemaCapture) issue(ref *sc.Ref, property, code, message string) error {
	return r.sink.Issue(sc.Issue{Ref: ref, Property: property, Code: code, Message: message, BlocksEquality: true, Planning: "manual"})
}
func pgBool(s string) bool        { return s == "true" || s == "t" || s == "1" }
func pgInt(s string) int64        { n, _ := strconv.ParseInt(s, 10, 64); return n }
func pgStrings(s string) []string { v := []string{}; _ = json.Unmarshal([]byte(s), &v); return v }
func pgOptions(s string) sc.Collection[sc.Option] {
	out := []sc.Option{}
	for _, v := range pgStrings(s) {
		n, x, _ := strings.Cut(v, "=")
		out = append(out, sc.Option{Name: n, Value: x})
	}
	return sc.Complete(out)
}
func pgColumn(table sc.Ref, name string) sc.Ref {
	return sc.Ref{Kind: "column", Schema: table.Schema, Table: table.Name, Name: name}
}
func (r *schemaCapture) typeUse(oid string, mod int64, dimensions int) (sc.TypeUse, error) {
	if cached, ok := r.types[oid]; ok {
		return r.modifiers(oid, cached, mod, dimensions)
	}
	rows, e := r.rows("SELECT n.nspname,t.typname,t.typtype::pg_catalog.text,t.typelem::pg_catalog.text,t.typbasetype::pg_catalog.text,t.typtypmod::pg_catalog.text,t.typnotnull::pg_catalog.text,t.typrelid::pg_catalog.text,"+r.expressionProjection("t.typdefaultbin", "0")+",(EXISTS(SELECT 1 FROM pg_catalog.pg_type element WHERE element.oid=t.typelem AND element.typarray=t.oid))::pg_catalog.text,t.typisdefined::pg_catalog.text,COALESCE(cn.nspname,''),COALESCE(c.collname,''),t.typndims::pg_catalog.text,COALESCE((SELECT td.description FROM pg_catalog.pg_description td WHERE td.objoid OPERATOR(pg_catalog.=) ANY(ARRAY[t.oid]) AND pg_catalog.oideq(td.classoid,'pg_catalog.pg_type'::pg_catalog.regclass) AND pg_catalog.int4eq(td.objsubid,0::pg_catalog.int4)),''),(t.oid<16384)::pg_catalog.text,EXISTS(SELECT 1 FROM pg_catalog.pg_class rowtype WHERE rowtype.oid=t.typrelid AND rowtype.relkind<>'c')::pg_catalog.text,t.typcollation::pg_catalog.text FROM pg_catalog.pg_type t JOIN pg_catalog.pg_namespace n ON n.oid=t.typnamespace LEFT JOIN pg_catalog.pg_collation c ON c.oid=t.typcollation LEFT JOIN pg_catalog.pg_namespace cn ON cn.oid=c.collnamespace WHERE t.oid=$1::pg_catalog.oid", oid)
	if e != nil || len(rows) != 1 {
		return sc.TypeUse{}, sc.ErrInvalid
	}
	v := rows[0]
	ref := sc.Ref{Kind: "type", Schema: v[0], Name: v[1], RowType: pgBool(v[16])}
	u := sc.TypeUse{Ref: ref, Kind: v[2], Modifiers: sc.Known(sc.TypeModifiers{}), Labels: sc.Complete[string](nil)}
	// A provisional reference closes recursive catalog graphs without truncating
	// their definitions or confusing a cycle with unavailable metadata.
	r.types[oid] = u
	if pgBool(v[9]) {
		element, e := r.typeUse(v[3], -1, 0)
		if e != nil {
			return u, e
		}
		u.Kind = "array"
		u.Ref = element.Ref
		u.Element = &element
	} else if v[0] == "pg_catalog" && v[2] == "b" && pgBool(v[15]) {
		u.Kind = "builtin"
	} else {
		definition := sc.TypeDefinition{Ref: ref, Comment: &v[14], Kind: sc.Known(v[2]), Labels: sc.Complete[string](nil), Base: sc.Absent[sc.TypeUse](), Default: sc.Known(sc.Default{Kind: "none"}), Nullable: sc.Known(!pgBool(v[6])), Checks: sc.Complete[sc.Constraint](nil), Attributes: sc.Complete[sc.Column](nil)}
		switch v[2] {
		case "e":
			labels, e := r.rows("SELECT enumlabel FROM pg_catalog.pg_enum WHERE enumtypid=$1::pg_catalog.oid ORDER BY enumsortorder", oid)
			if e != nil {
				return u, e
			}
			for _, l := range labels {
				definition.Labels.Items = append(definition.Labels.Items, l[0])
			}
		case "d":
			base, e := r.typeUse(v[4], pgInt(v[5]), int(pgInt(v[13])))
			if e != nil {
				return u, e
			}
			definition.Base = sc.Known(base)
			if v[12] != "" {
				definition.Collation = &sc.Ref{Kind: "collation", Schema: v[11], Name: v[12]}
			}
			if v[8] != "" {
				expr, e := r.expression(v[8], "pg_type", oid)
				if e != nil {
					return u, e
				}
				definition.Default = sc.Known(sc.Default{Kind: "expression", Expression: &expr})
			}
			checks, e := r.constraints(ref, "contypid", oid)
			if e != nil {
				return u, e
			}
			definition.Checks = sc.Complete(checks)
		case "c":
			columns, e := r.columns(sc.Ref{Kind: "table", Schema: ref.Schema, Name: ref.Name}, v[7])
			if e != nil {
				return u, e
			}
			definition.Attributes = sc.Complete(columns)
		case "r":
			definition.Range, e = r.rangeType(oid)
			if e != nil {
				return u, e
			}
		case "m":
			ranges, err := r.rows("SELECT rngtypid::pg_catalog.text FROM pg_catalog.pg_range WHERE rngmultitypid=$1::pg_catalog.oid", oid)
			if err != nil || len(ranges) != 1 {
				return u, sc.ErrInvalid
			}
			base, err := r.typeUse(ranges[0][0], -1, 0)
			if err != nil {
				return u, err
			}
			definition.Base = sc.Known(base)
		case "b":
			definition.BaseType, e = r.baseType(oid)
			if e != nil {
				return u, e
			}
		default:
			definition.Kind = sc.Unknown[string]("unsupportedType")
			if e = r.issue(&ref, "type", "unsupportedType", "This type definition is not supported losslessly."); e != nil {
				return u, e
			}
		}
		if !pgBool(v[10]) {
			definition.Kind = sc.Unknown[string]("undefinedType")
			if e = r.issue(&ref, "type", "undefinedType", "This shell type has not been defined."); e != nil {
				return u, e
			}
		}
		definition.CollationProperties, e = r.typeCollation(v[17])
		if e != nil {
			return u, e
		}
		definition.Extension, e = r.typeExtension(oid)
		if e != nil {
			return u, e
		}
		if e = r.sink.Type(definition); e != nil {
			return u, e
		}
	}
	r.types[oid] = u
	return r.modifiers(oid, u, mod, dimensions)
}
func pgModifiers(u sc.TypeUse, mod int64, dimensions int) sc.TypeUse {
	if u.Kind == "array" {
		if u.Element != nil {
			element := pgModifiers(*u.Element, mod, 0)
			u.Element = &element
		}
		u.Modifiers = sc.Known(sc.TypeModifiers{ArrayDimensions: dimensions})
		return u
	}
	m := sc.TypeModifiers{ArrayDimensions: dimensions}
	if mod >= 0 {
		if u.Ref.Schema != "pg_catalog" {
			m.Raw = &mod
			u.Modifiers = sc.Known(m)
			return u
		}
		switch u.Ref.Name {
		case "varchar", "bpchar":
			n := mod - 4
			m.Length = &n
		case "numeric":
			p := ((mod - 4) >> 16) & 65535
			scale := (mod - 4) & 2047
			if scale >= 1024 {
				scale -= 2048
			}
			m.Precision = &p
			m.Scale = &scale
		case "timestamp", "timestamptz", "time", "timetz":
			m.DatetimePrecision = &mod
		case "bit", "varbit":
			m.Length = &mod
		case "interval":
			p := mod & 65535
			i := mod >> 16
			m.DatetimePrecision = &p
			m.Interval = &i
		default:
			m.Raw = &mod
		}
	}
	u.Modifiers = sc.Known(m)
	return u
}
func (r *schemaCapture) expression(text, class, oid string) (sc.Expression, error) {
	if unavailable, ok := r.unavailableExpression(text, class, oid); ok {
		return unavailable, nil
	}
	if !strings.HasPrefix(class, "pg_catalog.") {
		class = "pg_catalog." + class
	}
	expr := sc.Expression{Text: text, Dependencies: sc.Complete[sc.Ref](nil)}
	rows, e := r.rows("SELECT rc.relname::pg_catalog.text,COALESCE(n.nspname,tn.nspname,''),COALESCE(c.relname,t.typname,''),d.refobjsubid::pg_catalog.text,COALESCE(a.attname,''),COALESCE(c.relkind::pg_catalog.text,''),d.refobjid::pg_catalog.text FROM pg_catalog.pg_depend d JOIN pg_catalog.pg_class rc ON rc.oid=d.refclassid LEFT JOIN pg_catalog.pg_class c ON d.refclassid='pg_catalog.pg_class'::pg_catalog.regclass AND c.oid=d.refobjid LEFT JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid=c.oid AND a.attnum=d.refobjsubid LEFT JOIN pg_catalog.pg_type t ON d.refclassid='pg_catalog.pg_type'::pg_catalog.regclass AND t.oid=d.refobjid LEFT JOIN pg_catalog.pg_namespace tn ON tn.oid=t.typnamespace WHERE d.classid=$1::pg_catalog.regclass AND d.objid=$2::pg_catalog.oid", class, oid)
	if e != nil {
		return expr, e
	}
	sort.Slice(rows, func(i, j int) bool { return strings.Join(rows[i][:4], "\x00") < strings.Join(rows[j][:4], "\x00") })
	for _, d := range rows {
		ref := sc.Ref{Schema: d[1], Name: d[2]}
		switch d[0] {
		case "pg_class":
			ref.Kind = "table"
			if d[5] == "S" {
				ref.Kind = "sequence"
				if e := r.sequence(d[6]); e != nil {
					return expr, e
				}
			}
			if d[3] != "0" {
				ref.Kind = "column"
				ref.Table = d[2]
				ref.Name = d[4]
			}
		case "pg_type":
			u, e := r.typeUse(d[6], -1, 0)
			if e != nil {
				return expr, e
			}
			ref = u.Ref
		case "pg_collation":
			rows, e := r.rows("SELECT n.nspname,c.collname FROM pg_catalog.pg_collation c JOIN pg_catalog.pg_namespace n ON n.oid=c.collnamespace WHERE c.oid=$1::pg_catalog.oid", d[6])
			if e != nil || len(rows) != 1 {
				return expr, sc.ErrInvalid
			}
			ref = sc.Ref{Kind: "collation", Schema: rows[0][0], Name: rows[0][1]}
			properties, e := r.typeCollation(d[6])
			if e != nil || properties == nil {
				return expr, sc.ErrInvalid
			}
			expr.Collations = append(expr.Collations, sc.TypeCollation{Ref: ref, Properties: *properties})
		case "pg_proc":
			f, e := r.typeFunction(d[6], "expression")
			if e != nil || f == nil {
				return expr, sc.ErrInvalid
			}
			ref = f.Ref
			expr.Functions = append(expr.Functions, *f)
		case "pg_operator":
			op, e := r.expressionOperator(d[6])
			if e != nil {
				return expr, e
			}
			ref = op.Ref
			expr.Operators = append(expr.Operators, *op)
		case "pg_namespace", "pg_extension":
			// Namespace and extension membership belong to the type definition.
			continue
		default:
			expr.Dependencies.Complete = false
			expr.Dependencies.Code = "unresolvedExpressionDependency"
			continue
		}
		expr.Dependencies.Items = append(expr.Dependencies.Items, ref)
	}
	return expr, nil
}
func (r *schemaCapture) columns(table sc.Ref, oid string) ([]sc.Column, error) {
	rows, e := r.rows("SELECT a.attname,a.atttypid::pg_catalog.text,a.atttypmod::pg_catalog.text,a.attndims::pg_catalog.text,a.attnotnull::pg_catalog.text,a.attidentity::pg_catalog.text,a.attgenerated::pg_catalog.text,"+r.expressionProjection("d.adbin", "d.adrelid")+",COALESCE(d.oid::pg_catalog.text,''),COALESCE(cn.nspname,''),COALESCE(co.collname,''),COALESCE((SELECT cd.description FROM pg_catalog.pg_description cd WHERE cd.objoid OPERATOR(pg_catalog.=) ANY(ARRAY[a.attrelid]) AND pg_catalog.oideq(cd.classoid,'pg_catalog.pg_class'::pg_catalog.regclass) AND pg_catalog.int4eq(cd.objsubid,a.attnum::pg_catalog.int4)),''),a.attnum::pg_catalog.text,a.attcollation::pg_catalog.text FROM pg_catalog.pg_attribute a LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid OPERATOR(pg_catalog.=) ANY(ARRAY[a.attrelid]) AND pg_catalog.int2eq(d.adnum,a.attnum) LEFT JOIN pg_catalog.pg_collation co ON pg_catalog.oideq(co.oid,a.attcollation) LEFT JOIN pg_catalog.pg_namespace cn ON pg_catalog.oideq(cn.oid,co.collnamespace) WHERE a.attrelid OPERATOR(pg_catalog.=) ANY(ARRAY[$1::pg_catalog.oid]) AND pg_catalog.int2gt(a.attnum,0::pg_catalog.int2) AND NOT a.attisdropped ", oid)
	if e != nil {
		return nil, e
	}
	// Preserve native ordinal order without planner access-method inspection.
	sort.Slice(rows, func(i, j int) bool { return pgInt(rows[i][12]) < pgInt(rows[j][12]) })
	out := []sc.Column{}
	for i, v := range rows {
		r.members++
		if r.members > r.spec.Limits.Members {
			return nil, sc.ErrLimit
		}
		u, e := r.typeUse(v[1], pgInt(v[2]), int(pgInt(v[3])))
		if e != nil {
			return nil, e
		}
		c := sc.Column{Ref: pgColumn(table, v[0]), Ordinal: sc.Known(i), Type: sc.Known(u), Nullable: sc.Known(!pgBool(v[4])), Default: sc.Known(sc.Default{Kind: "none"}), Generated: sc.Known(sc.Generated{Kind: "none"}), Identity: sc.Known(sc.Identity{Kind: "none"}), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Visible: sc.Known(true), Comment: sc.Known(v[11]), OnUpdate: sc.Absent[sc.Expression]()}
		if v[10] != "" {
			c.Collation = sc.Known(sc.Ref{Kind: "collation", Schema: v[9], Name: v[10]})
			c.CollationProperties, e = r.typeCollation(v[13])
			if e != nil {
				return nil, e
			}
		}
		if v[7] != "" {
			expr, e := r.expression(v[7], "pg_attrdef", v[8])
			if e != nil {
				return nil, e
			}
			if v[6] != "" {
				kind := "stored"
				if v[6] == "v" {
					kind = "virtual"
				}
				c.Generated = sc.Known(sc.Generated{Kind: kind, Expression: &expr})
			} else {
				c.Default = sc.Known(sc.Default{Kind: "expression", Expression: &expr})
			}
		}
		if v[5] != "" {
			kind := "byDefault"
			if v[5] == "a" {
				kind = "always"
			}
			c.Identity = sc.Known(sc.Identity{Kind: kind})
		}
		out = append(out, c)
	}
	return out, nil
}
func (r *schemaCapture) table(ref sc.Ref, v []string) error {
	t := sc.Table{Ref: ref, Kind: sc.Known(v[2]), Storage: sc.Known(v[3]), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Options: pgOptions(v[7]), Columns: sc.Complete[sc.Column](nil), Constraints: sc.Complete[sc.Constraint](nil), Indexes: sc.Complete[sc.Index](nil), Dependencies: sc.Complete[sc.Dependency](nil)}
	if v[2] != "r" || pgBool(v[4]) || pgBool(v[5]) || pgBool(v[6]) {
		t.Kind = sc.Unknown[string]("tableKind")
		if e := r.issue(&ref, "kind", "tableKind", "Partitioned, inherited, foreign or typed tables require manual review."); e != nil {
			return e
		}
	}
	if !pgBool(v[8]) {
		t.Columns.Complete = false
		t.Constraints.Complete = false
		t.Indexes.Complete = false
		if e := r.issue(&ref, "access", "inaccessible", "Table SELECT access is unavailable."); e != nil {
			return e
		}
	}
	columns, e := r.columns(ref, v[0])
	if e != nil {
		return e
	}
	t.Columns.Items = columns
	constraints, e := r.constraints(ref, "conrelid", v[0])
	if e != nil {
		return e
	}
	t.Constraints.Items = constraints
	indexes, e := r.indexes(ref, v[0])
	if e != nil {
		return e
	}
	t.Indexes.Items = indexes
	seqs, e := r.rows("SELECT s.oid::pg_catalog.text,n.nspname,s.relname,a.attname,q.seqtypid::pg_catalog.text,q.seqstart::pg_catalog.text,q.seqincrement::pg_catalog.text,q.seqmin::pg_catalog.text,q.seqmax::pg_catalog.text,q.seqcache::pg_catalog.text,q.seqcycle::pg_catalog.text FROM pg_catalog.pg_depend d JOIN pg_catalog.pg_class s ON pg_catalog.oideq(d.classid,'pg_catalog.pg_class'::pg_catalog.regclass) AND pg_catalog.oideq(s.oid,d.objid) AND pg_catalog.chareq(s.relkind,'S') JOIN pg_catalog.pg_namespace n ON pg_catalog.oideq(n.oid,s.relnamespace) JOIN pg_catalog.pg_sequence q ON pg_catalog.oideq(q.seqrelid,s.oid) JOIN pg_catalog.pg_attribute a ON pg_catalog.oideq(a.attrelid,d.refobjid) AND pg_catalog.int4eq(a.attnum::pg_catalog.int4,d.refobjsubid) WHERE d.refclassid OPERATOR(pg_catalog.=) ANY(ARRAY['pg_catalog.pg_class'::pg_catalog.regclass::pg_catalog.oid]) AND d.refobjid OPERATOR(pg_catalog.=) ANY(ARRAY[$1::pg_catalog.oid]) AND (pg_catalog.chareq(d.deptype,'a') OR pg_catalog.chareq(d.deptype,'i'))", v[0])
	if e != nil {
		return e
	}
	sort.Slice(seqs, func(i, j int) bool {
		if seqs[i][1] != seqs[j][1] {
			return seqs[i][1] < seqs[j][1]
		}
		return seqs[i][2] < seqs[j][2]
	})
	for _, s := range seqs {
		u, e := r.typeUse(s[4], -1, 0)
		if e != nil {
			return e
		}
		owner := pgColumn(ref, s[3])
		seq := sc.Sequence{Ref: sc.Ref{Kind: "sequence", Schema: s[1], Name: s[2]}, Type: sc.Known(u), Start: sc.Known(s[5]), Increment: sc.Known(s[6]), Min: sc.Known(s[7]), Max: sc.Known(s[8]), Cache: sc.Known(s[9]), Cycle: sc.Known(pgBool(s[10])), Owner: sc.Known(owner)}
		for i := range t.Columns.Items {
			c := &t.Columns.Items[i]
			if c.Ref == owner && c.Identity.Value != nil && c.Identity.Value.Kind != "none" {
				c.Identity.Value.Sequence = &seq.Ref
			}
		}
		if !r.sequences[s[0]] {
			r.sequences[s[0]] = true
			if e = r.sink.Sequence(seq); e != nil {
				return e
			}
		}
	}
	return r.sink.Table(t)
}
func (r *schemaCapture) sequence(oid string) error {
	if r.sequences[oid] {
		return nil
	}
	r.sequences[oid] = true
	rows, e := r.rows("SELECT n.nspname,s.relname,q.seqtypid::pg_catalog.text,q.seqstart::pg_catalog.text,q.seqincrement::pg_catalog.text,q.seqmin::pg_catalog.text,q.seqmax::pg_catalog.text,q.seqcache::pg_catalog.text,q.seqcycle::pg_catalog.text,COALESCE(tn.nspname,''),COALESCE(t.relname,''),COALESCE(a.attname,'') FROM pg_catalog.pg_sequence q JOIN pg_catalog.pg_class s ON s.oid=q.seqrelid JOIN pg_catalog.pg_namespace n ON n.oid=s.relnamespace LEFT JOIN pg_catalog.pg_depend d ON d.classid='pg_catalog.pg_class'::pg_catalog.regclass AND d.objid=s.oid AND d.refclassid='pg_catalog.pg_class'::pg_catalog.regclass AND (pg_catalog.chareq(d.deptype,'a') OR pg_catalog.chareq(d.deptype,'i')) LEFT JOIN pg_catalog.pg_class t ON t.oid=d.refobjid LEFT JOIN pg_catalog.pg_namespace tn ON tn.oid=t.relnamespace LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid=t.oid AND a.attnum=d.refobjsubid WHERE s.oid=$1::pg_catalog.oid", oid)
	if e != nil {
		return e
	}
	if len(rows) != 1 {
		return sc.ErrInvalid
	}
	v := rows[0]
	u, e := r.typeUse(v[2], -1, 0)
	if e != nil {
		return e
	}
	seq := sc.Sequence{Ref: sc.Ref{Kind: "sequence", Schema: v[0], Name: v[1]}, Type: sc.Known(u), Start: sc.Known(v[3]), Increment: sc.Known(v[4]), Min: sc.Known(v[5]), Max: sc.Known(v[6]), Cache: sc.Known(v[7]), Cycle: sc.Known(pgBool(v[8])), Owner: sc.Absent[sc.Ref]()}
	if v[11] != "" {
		seq.Owner = sc.Known(sc.Ref{Kind: "column", Schema: v[9], Table: v[10], Name: v[11]})
	}
	return r.sink.Sequence(seq)
}
func (r *schemaCapture) constraints(table sc.Ref, field, oid string) ([]sc.Constraint, error) {
	if field != "conrelid" && field != "contypid" {
		return nil, sc.ErrInvalid
	}
	enforced := "true"
	temporal := "false"
	setColumns := "'[]'"
	if r.version >= 150000 {
		setColumns = "COALESCE((SELECT pg_catalog.json_agg(a.attname ORDER BY x.ord)::pg_catalog.text FROM pg_catalog.unnest(c.confdelsetcols) WITH ORDINALITY x(num,ord) JOIN pg_catalog.pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=x.num),'[]')"
	}
	if r.version >= 180000 {
		enforced = "c.conenforced"
		temporal = "c.conperiod"
	}
	rows, e := r.rows("SELECT c.oid::pg_catalog.text,c.conname,c.contype::pg_catalog.text,c.condeferrable::pg_catalog.text,c.condeferred::pg_catalog.text,c.convalidated::pg_catalog.text,"+enforced+"::pg_catalog.text,c.conislocal::pg_catalog.text,(c.coninhcount>0)::pg_catalog.text,c.connoinherit::pg_catalog.text,"+r.expressionProjection("c.conbin", "c.conrelid")+",COALESCE(n.nspname,''),COALESCE(f.relname,''),c.confupdtype::pg_catalog.text,c.confdeltype::pg_catalog.text,c.confmatchtype::pg_catalog.text,COALESCE((SELECT pg_catalog.json_agg(a.attname ORDER BY k.ord)::pg_catalog.text FROM pg_catalog.unnest(c.conkey) WITH ORDINALITY k(num,ord) JOIN pg_catalog.pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k.num),'[]'),COALESCE((SELECT pg_catalog.json_agg(a.attname ORDER BY k.ord)::pg_catalog.text FROM pg_catalog.unnest(c.confkey) WITH ORDINALITY k(num,ord) JOIN pg_catalog.pg_attribute a ON a.attrelid=c.confrelid AND a.attnum=k.num),'[]'),COALESCE(ix.relname,''),"+setColumns+","+temporal+"::pg_catalog.text FROM pg_catalog.pg_constraint c LEFT JOIN pg_catalog.pg_class f ON f.oid=c.confrelid LEFT JOIN pg_catalog.pg_namespace n ON n.oid=f.relnamespace LEFT JOIN pg_catalog.pg_class ix ON ix.oid=c.conindid WHERE c."+field+"=$1::pg_catalog.oid ORDER BY c.conname COLLATE pg_catalog.\"C\"", oid)
	if e != nil {
		return nil, e
	}
	out := []sc.Constraint{}
	for _, v := range rows {
		ref := sc.Ref{Kind: "constraint", Schema: table.Schema, Table: table.Name, Name: v[1]}
		c := sc.NewConstraint(ref, v[2])
		c.Deferrable = sc.Known(pgBool(v[3]))
		c.InitiallyDeferred = sc.Known(pgBool(v[4]))
		c.Validated = sc.Known(pgBool(v[5]))
		c.Enforced = sc.Known(pgBool(v[6]))
		c.Local = sc.Known(pgBool(v[7]))
		c.Inherited = sc.Known(pgBool(v[8]))
		c.NoInherit = sc.Known(pgBool(v[9]))
		if v[10] != "" {
			expr, e := r.expression(v[10], "pg_constraint", v[0])
			if e != nil {
				return nil, e
			}
			c.Check = sc.Known(expr)
		}
		for _, name := range pgStrings(v[16]) {
			c.Columns.Items = append(c.Columns.Items, pgColumn(table, name))
		}
		if v[2] == "f" {
			target := sc.Ref{Kind: "table", Schema: v[11], Name: v[12]}
			c.Target = sc.Known(target)
			foreign := pgStrings(v[17])
			if len(foreign) != len(c.Columns.Items) {
				return nil, sc.ErrInvalid
			}
			for i, name := range foreign {
				c.ForeignKeys.Items = append(c.ForeignKeys.Items, sc.ColumnPair{Source: c.Columns.Items[i], Target: pgColumn(target, name)})
			}
			c.Update = sc.Known(v[13])
			c.Delete = sc.Known(v[14])
			c.Match = sc.Known(v[15])
		}
		if v[18] != "" && (v[2] == "p" || v[2] == "u" || v[2] == "x") {
			c.BackingIndex = sc.Known(sc.Ref{Kind: "index", Schema: table.Schema, Table: table.Name, Name: v[18]})
		}
		for _, name := range pgStrings(v[19]) {
			c.SetColumns.Items = append(c.SetColumns.Items, pgColumn(table, name))
		}
		if v[2] == "x" || pgBool(v[20]) {
			c.Kind = sc.Unknown[string]("unsupportedConstraint")
			if e = r.issue(&ref, "constraint", "unsupportedConstraint", "Exclusion or temporal constraints require manual review."); e != nil {
				return nil, e
			}
		}
		out = append(out, c)
	}
	return out, nil
}
func (r *schemaCapture) indexes(table sc.Ref, oid string) ([]sc.Index, error) {
	previousSafety := r.skipCustomTypeFormatting
	r.skipCustomTypeFormatting = true
	defer func() { r.skipCustomTypeFormatting = previousSafety }()
	nulls := "false"
	if r.version >= 150000 {
		nulls = "i.indnullsnotdistinct"
	}
	rows, e := r.rows("SELECT c.oid::pg_catalog.text,c.relname,am.amname,i.indisunique::pg_catalog.text,"+nulls+"::pg_catalog.text,i.indisvalid::pg_catalog.text,i.indisready::pg_catalog.text,"+r.expressionProjection("i.indpred", "i.indrelid")+",COALESCE(pg_catalog.array_to_json(c.reloptions)::pg_catalog.text,'[]'),COALESCE(con.conname,''),i.indnkeyatts::pg_catalog.text,EXISTS(SELECT 1 FROM pg_catalog.pg_depend WHERE classid='pg_catalog.pg_class'::pg_catalog.regclass AND objid=c.oid AND deptype='e')::pg_catalog.text,"+r.expressionProjection("i.indexprs", "i.indrelid")+",COALESCE(i.indexprs::pg_catalog.text,''),COALESCE((SELECT ic.description FROM pg_catalog.pg_description ic WHERE ic.objoid OPERATOR(pg_catalog.=) ANY(ARRAY[c.oid]) AND pg_catalog.oideq(ic.classoid,'pg_catalog.pg_class'::pg_catalog.regclass) AND pg_catalog.int4eq(ic.objsubid,0::pg_catalog.int4)),''),c.reltablespace::pg_catalog.text,i.indisclustered::pg_catalog.text,i.indisreplident::pg_catalog.text,COALESCE((SELECT pg_catalog.json_agg(pg_catalog.json_build_array(a.attnum,a.attstattarget) ORDER BY a.attnum)::pg_catalog.text FROM pg_catalog.pg_attribute a WHERE a.attrelid=c.oid AND a.attnum>0 AND a.attstattarget<>-1),'[]') FROM pg_catalog.pg_index i JOIN pg_catalog.pg_class c ON c.oid=i.indexrelid JOIN pg_catalog.pg_am am ON am.oid=c.relam LEFT JOIN pg_catalog.pg_constraint con ON con.conindid=c.oid AND con.conrelid=i.indrelid AND (pg_catalog.chareq(con.contype,'p') OR pg_catalog.chareq(con.contype,'u') OR pg_catalog.chareq(con.contype,'x')) WHERE i.indrelid=$1::pg_catalog.oid ORDER BY c.relname COLLATE pg_catalog.\"C\"", oid)
	if e != nil {
		return nil, e
	}
	functions, err := r.rows(`SELECT oid::pg_catalog.text,proname FROM pg_catalog.pg_proc WHERE pronamespace='pg_catalog'::pg_catalog.regnamespace AND proname IN ('lower','upper') AND proargtypes='25'::pg_catalog.oidvector AND prorettype=25`)
	if err != nil {
		return nil, err
	}
	builtinFunctions := map[string]string{}
	for _, function := range functions {
		builtinFunctions[function[0]] = function[1]
	}
	out := []sc.Index{}
	for _, v := range rows {
		ref := sc.Ref{Kind: "index", Schema: table.Schema, Table: table.Name, Name: v[1]}
		x := sc.Index{Ref: ref, Method: sc.Known(v[2]), Unique: sc.Known(pgBool(v[3])), NullsDistinct: sc.Known(!pgBool(v[4])), Keys: sc.Complete[sc.IndexKey](nil), Includes: sc.Complete[sc.Ref](nil), Predicate: sc.Absent[sc.Expression](), Options: pgOptions(v[8]), Visible: sc.Known(true), Valid: sc.Known(pgBool(v[5])), Ready: sc.Known(pgBool(v[6])), Constraint: sc.Absent[sc.Ref]()}
		attributes := map[string]string{}
		if v[14] != "" {
			attributes["comment"] = v[14]
		}
		if v[15] != "0" {
			attributes["tablespace"] = v[15]
		}
		if pgBool(v[16]) {
			attributes["clustered"] = v[16]
		}
		if pgBool(v[17]) {
			attributes["replicaIdentity"] = v[17]
		}
		if v[18] != "[]" {
			attributes["statisticsTargets"] = v[18]
		}
		if len(attributes) > 0 {
			names := []string{}
			for key := range attributes {
				names = append(names, key)
			}
			sort.Strings(names)
			attributes["reason"] = strings.Join(names, ", ")
			if r.indexAttributes == nil {
				r.indexAttributes = map[string]map[string]string{}
			}
			r.indexAttributes[v[1]] = attributes
			x.Options.Complete = false
			x.Options.State = "unavailable"
			x.Options.Code = "unmodeledIndexProperties"
			if err := r.issue(&ref, "index", "unmodeledIndexProperties", "Index properties outside the exposed definition require an explicit reviewed migration: "+attributes["reason"]); err != nil {
				return nil, err
			}
		}
		if v[7] != "" {
			expr, e := r.expression(v[7], "pg_class", v[0])
			if e != nil {
				return nil, e
			}
			x.Predicate = sc.Known(expr)
		}
		if v[9] != "" {
			x.Constraint = sc.Known(sc.Ref{Kind: "constraint", Schema: table.Schema, Table: table.Name, Name: v[9]})
		}
		if pgBool(v[11]) {
			x.Method = sc.Unknown[string]("indexMethodOrOptions")
			if e = r.issue(&ref, "index", "indexMethodOrOptions", "Index method or options require manual review."); e != nil {
				return nil, e
			}
		}
		expressions, expressionsOK := tableedit.SplitExpressionList("postgresql", v[12])
		expressionOrdinal := 0
		expressionCollations, collationsOK := catalogIndexExpressionCollations(v[13])
		keyDefinition := "CASE WHEN k.num>0 THEN '' ELSE pg_catalog.chr(1)||'catalog:'||COALESCE(i.indexprs::pg_catalog.text,'') END"
		keys, e := r.rows("SELECT k.ord::pg_catalog.text,COALESCE(a.attname,''),"+keyDefinition+",COALESCE(onsp.nspname,''),COALESCE(op.opcname,''),COALESCE(cn.nspname,''),COALESCE(co.collname,''),COALESCE(i.indoption[k.ord::pg_catalog.int4-1],0)::pg_catalog.text,COALESCE(pg_catalog.array_to_json(ia.attoptions)::pg_catalog.text,'[]'),COALESCE(a.attcollation::pg_catalog.text,'0'),COALESCE(i.indcollation[k.ord::pg_catalog.int4-1],0)::pg_catalog.text FROM pg_catalog.pg_index i CROSS JOIN pg_catalog.unnest(i.indkey) WITH ORDINALITY k(num,ord) LEFT JOIN pg_catalog.pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=k.num LEFT JOIN pg_catalog.pg_opclass op ON op.oid=i.indclass[k.ord::pg_catalog.int4-1] LEFT JOIN pg_catalog.pg_namespace onsp ON onsp.oid=op.opcnamespace LEFT JOIN pg_catalog.pg_collation co ON co.oid=i.indcollation[k.ord::pg_catalog.int4-1] LEFT JOIN pg_catalog.pg_namespace cn ON cn.oid=co.collnamespace LEFT JOIN pg_catalog.pg_attribute ia ON ia.attrelid=i.indexrelid AND ia.attnum=k.ord WHERE i.indexrelid=$1::pg_catalog.oid ORDER BY k.ord", v[0])
		if e != nil {
			return nil, e
		}
		if r.indexDefaultCollations == nil {
			r.indexDefaultCollations = map[string][]bool{}
		}
		if r.indexBuiltinFunctions == nil {
			r.indexBuiltinFunctions = map[string][]string{}
		}
		for i, k := range keys {
			if i >= int(pgInt(v[10])) {
				x.Includes.Items = append(x.Includes.Items, pgColumn(table, k[1]))
				continue
			}
			defaultCollation := k[10] == "0"
			if k[1] != "" {
				defaultCollation = k[9] == k[10]
			} else if collationsOK && expressionOrdinal < len(expressionCollations) && expressionCollations[expressionOrdinal].known {
				defaultCollation = expressionCollations[expressionOrdinal].oid == k[10]
			}
			r.indexDefaultCollations[v[1]] = append(r.indexDefaultCollations[v[1]], defaultCollation)
			function := ""
			if k[1] == "" && collationsOK && expressionOrdinal < len(expressionCollations) {
				function = builtinFunctions[expressionCollations[expressionOrdinal].functionID]
			}
			r.indexBuiltinFunctions[v[1]] = append(r.indexBuiltinFunctions[v[1]], function)
			key := sc.IndexKey{Column: sc.Absent[sc.Ref](), Expression: sc.Absent[sc.Expression](), Opclass: sc.Absent[sc.Ref](), Collation: sc.Absent[sc.Ref](), Descending: sc.Known(pgInt(k[7])&1 != 0), NullsFirst: sc.Known(pgInt(k[7])&2 != 0), PrefixLength: sc.Absent[int64](), Options: pgOptions(k[8])}
			if k[1] != "" {
				key.Column = sc.Known(pgColumn(table, k[1]))
			} else {
				if expressionsOK && expressionOrdinal < len(expressions) {
					expr, err := r.expression(expressions[expressionOrdinal], "pg_class", v[0])
					if err != nil {
						return nil, err
					}
					key.Expression = sc.Known(expr)

				} else {
					if r.rawExpressions == nil {
						r.rawExpressions = map[string]string{}
					}
					r.rawExpressions["pg_index:"+v[0]] = v[13]
					code := "indexExpressionSyntax"
					if strings.HasPrefix(v[12], unavailableCatalogExpression) {
						code = "customTypeSupport"
					}
					key.Expression = sc.Known(sc.Expression{Text: "/* index expression metadata unavailable */", Dependencies: sc.Collection[sc.Ref]{Items: []sc.Ref{}, State: "unavailable", Code: code}})
				}
				expressionOrdinal++
			}
			if k[4] != "" {
				key.Opclass = sc.Known(sc.Ref{Kind: "opclass", Schema: k[3], Name: k[4]})

			}
			if k[6] != "" {
				key.Collation = sc.Known(sc.Ref{Kind: "collation", Schema: k[5], Name: k[6]})
			}
			x.Keys.Items = append(x.Keys.Items, key)
		}
		out = append(out, x)
	}
	return out, nil
}
