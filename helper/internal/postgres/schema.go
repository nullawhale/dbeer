package postgres

import (
	"context"
	sc "dbeer/helper/internal/schemacompare"
	"encoding/json"
	"fmt"
	"github.com/jackc/pgx/v5"
	"strconv"
	"strings"
	"time"
)

type schemaCapture struct {
	ctx       context.Context
	tx        pgx.Tx
	sink      sc.Sink
	spec      sc.CaptureSpec
	version   int
	members   int
	types     map[string]sc.TypeUse
	loading   map[string]bool
	sequences map[string]bool
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
	rows, e := r.rows("SELECT current_setting('server_version_num'),version(),current_database()")
	if e != nil || len(rows) != 1 {
		return sc.ErrInvalid
	}
	r.version, _ = strconv.Atoi(rows[0][0])
	if r.version < 140000 {
		return sc.ErrInvalid
	}
	capture := sc.CaptureContext{Engine: "postgresql", Version: rows[0][1], Database: rows[0][2], StartedAt: started, Consistency: "repeatableRead", Visibility: "complete", EngineContext: sc.Known([]sc.Option{})}
	collations, e := r.rows("SELECT datcollate,datctype FROM pg_database WHERE datname=current_database()")
	if e != nil {
		return e
	}
	if len(collations) == 1 {
		capture.EngineContext = sc.Known([]sc.Option{{Name: "collation", Value: collations[0][0]}, {Name: "ctype", Value: collations[0][1]}})
	}
	collationContext, e := r.rows("SELECT n.nspname,c.collname,c.collprovider::text,COALESCE(c.collversion,''),COALESCE(pg_collation_actual_version(c.oid),'') FROM pg_collation c JOIN pg_namespace n ON n.oid=c.collnamespace WHERE c.oid IN (SELECT a.attcollation FROM pg_attribute a JOIN pg_class t ON t.oid=a.attrelid JOIN pg_namespace ns ON ns.oid=t.relnamespace WHERE ns.nspname=ANY($1::text[]) AND a.attnum>0 AND NOT a.attisdropped) ORDER BY n.nspname COLLATE \"C\",c.collname COLLATE \"C\"", spec.Schemas)
	if e != nil {
		return e
	}
	for _, v := range collationContext {
		b, _ := json.Marshal(v)
		*capture.EngineContext.Value = append(*capture.EngineContext.Value, sc.Option{Name: "collationContext", Value: string(b)})
	}
	for _, schema := range spec.Schemas {
		inv := sc.Inventory{Schema: schema, Existence: "absent", Tables: sc.Complete[sc.Ref](nil), Types: sc.Complete[sc.Ref](nil)}
		names, e := r.rows("SELECT n.oid::text,has_schema_privilege(n.oid,'USAGE')::text FROM pg_namespace n WHERE n.nspname=$1", schema)
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
		tables, e := r.rows("SELECT c.oid::text,c.relname,c.relkind::text,c.relpersistence::text,c.relispartition::text,(c.reloftype<>0)::text,EXISTS(SELECT 1 FROM pg_inherits WHERE inhrelid=c.oid)::text,COALESCE(array_to_json(c.reloptions)::text,'[]'),has_table_privilege(c.oid,'SELECT')::text FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname=$1 AND c.relkind IN ('r','p','f') ORDER BY c.relname COLLATE \"C\"", schema)
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
		types, e := r.rows("SELECT t.oid::text,t.typname FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace WHERE n.nspname=$1 AND t.typtype IN ('e','d','c','r','m') AND (t.typrelid=0 OR EXISTS(SELECT 1 FROM pg_class c WHERE c.oid=t.typrelid AND c.relkind='c')) ORDER BY t.typname COLLATE \"C\"", schema)
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
	rows, e := r.tx.Query(r.ctx, sql, args...)
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
		return pgModifiers(cached, mod, dimensions), nil
	}
	rows, e := r.rows("SELECT n.nspname,t.typname,t.typtype::text,t.typelem::text,t.typbasetype::text,t.typtypmod::text,t.typnotnull::text,t.typrelid::text,COALESCE(pg_get_expr(t.typdefaultbin,0,false),''),EXISTS(SELECT 1 FROM pg_depend WHERE classid='pg_type'::regclass AND objid=t.oid AND deptype='e')::text FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace WHERE t.oid=$1::oid", oid)
	if e != nil || len(rows) != 1 {
		return sc.TypeUse{}, sc.ErrInvalid
	}
	v := rows[0]
	ref := sc.Ref{Kind: "type", Schema: v[0], Name: v[1]}
	u := sc.TypeUse{Ref: ref, Kind: v[2], Modifiers: sc.Known(sc.TypeModifiers{}), Labels: sc.Complete[string](nil)}
	if r.loading[oid] {
		u.Modifiers = sc.Unknown[sc.TypeModifiers]("recursiveType")
		return u, r.issue(&ref, "type", "recursiveType", "Recursive type metadata requires manual review.")
	}
	r.loading[oid] = true
	defer delete(r.loading, oid)
	if v[3] != "0" && v[2] == "b" {
		element, e := r.typeUse(v[3], mod, 0)
		if e != nil {
			return u, e
		}
		u.Kind = "array"
		u.Ref = element.Ref
		u.Element = &element
	} else if v[0] == "pg_catalog" && v[2] == "b" {
		u.Kind = "builtin"
	} else {
		definition := sc.TypeDefinition{Ref: ref, Kind: sc.Known(v[2]), Labels: sc.Complete[string](nil), Base: sc.Absent[sc.TypeUse](), Default: sc.Known(sc.Default{Kind: "none"}), Nullable: sc.Known(!pgBool(v[6])), Checks: sc.Complete[sc.Constraint](nil), Attributes: sc.Complete[sc.Column](nil)}
		switch v[2] {
		case "e":
			labels, e := r.rows("SELECT enumlabel FROM pg_enum WHERE enumtypid=$1::oid ORDER BY enumsortorder", oid)
			if e != nil {
				return u, e
			}
			for _, l := range labels {
				definition.Labels.Items = append(definition.Labels.Items, l[0])
			}
		case "d":
			base, e := r.typeUse(v[4], pgInt(v[5]), 0)
			if e != nil {
				return u, e
			}
			definition.Base = sc.Known(base)
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
		default:
			definition.Kind = sc.Unknown[string]("unsupportedType")
			if e = r.issue(&ref, "type", "unsupportedType", "This type definition is not supported losslessly."); e != nil {
				return u, e
			}
		}
		if pgBool(v[9]) {
			definition.Kind = sc.Unknown[string]("extensionType")
			if e = r.issue(&ref, "type", "extensionType", "Extension type behavior requires manual review."); e != nil {
				return u, e
			}
		}
		if e = r.sink.Type(definition); e != nil {
			return u, e
		}
	}
	r.types[oid] = u
	return pgModifiers(u, mod, dimensions), nil
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
			u.Modifiers = sc.Unknown[sc.TypeModifiers]("typeModifier")
			return u
		}
	}
	u.Modifiers = sc.Known(m)
	return u
}
func (r *schemaCapture) expression(text, class, oid string) (sc.Expression, error) {
	expr := sc.Expression{Text: text, Dependencies: sc.Complete[sc.Ref](nil)}
	rows, e := r.rows("SELECT d.refclassid::regclass::text,COALESCE(n.nspname,tn.nspname,''),COALESCE(c.relname,t.typname,''),d.refobjsubid::text,COALESCE(a.attname,''),COALESCE(c.relkind::text,''),d.refobjid::text FROM pg_depend d LEFT JOIN pg_class c ON d.refclassid='pg_class'::regclass AND c.oid=d.refobjid LEFT JOIN pg_namespace n ON n.oid=c.relnamespace LEFT JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum=d.refobjsubid LEFT JOIN pg_type t ON d.refclassid='pg_type'::regclass AND t.oid=d.refobjid LEFT JOIN pg_namespace tn ON tn.oid=t.typnamespace WHERE d.classid=$1::regclass AND d.objid=$2::oid ORDER BY 1,2,3,4", class, oid)
	if e != nil {
		return expr, e
	}
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
			ref.Kind = "type"
			if _, e := r.typeUse(d[6], -1, 0); e != nil {
				return expr, e
			}
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
	rows, e := r.rows("SELECT a.attname,a.atttypid::text,a.atttypmod::text,a.attndims::text,a.attnotnull::text,a.attidentity::text,a.attgenerated::text,COALESCE(pg_get_expr(d.adbin,d.adrelid,false),''),COALESCE(d.oid::text,''),COALESCE(cn.nspname,''),COALESCE(co.collname,''),COALESCE(col_description(a.attrelid,a.attnum),''),a.attnum::text FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum LEFT JOIN pg_collation co ON co.oid=a.attcollation LEFT JOIN pg_namespace cn ON cn.oid=co.collnamespace WHERE a.attrelid=$1::oid AND a.attnum>0 AND NOT a.attisdropped ORDER BY a.attnum", oid)
	if e != nil {
		return nil, e
	}
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
	seqs, e := r.rows("SELECT s.oid::text,n.nspname,s.relname,a.attname,q.seqtypid::text,q.seqstart::text,q.seqincrement::text,q.seqmin::text,q.seqmax::text,q.seqcache::text,q.seqcycle::text FROM pg_depend d JOIN pg_class s ON d.classid='pg_class'::regclass AND s.oid=d.objid AND s.relkind='S' JOIN pg_namespace n ON n.oid=s.relnamespace JOIN pg_sequence q ON q.seqrelid=s.oid JOIN pg_attribute a ON a.attrelid=d.refobjid AND a.attnum=d.refobjsubid WHERE d.refclassid='pg_class'::regclass AND d.refobjid=$1::oid AND d.deptype IN ('a','i') ORDER BY n.nspname,s.relname", v[0])
	if e != nil {
		return e
	}
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
	rows, e := r.rows("SELECT n.nspname,s.relname,q.seqtypid::text,q.seqstart::text,q.seqincrement::text,q.seqmin::text,q.seqmax::text,q.seqcache::text,q.seqcycle::text,COALESCE(tn.nspname,''),COALESCE(t.relname,''),COALESCE(a.attname,'') FROM pg_sequence q JOIN pg_class s ON s.oid=q.seqrelid JOIN pg_namespace n ON n.oid=s.relnamespace LEFT JOIN pg_depend d ON d.classid='pg_class'::regclass AND d.objid=s.oid AND d.refclassid='pg_class'::regclass AND d.deptype IN ('a','i') LEFT JOIN pg_class t ON t.oid=d.refobjid LEFT JOIN pg_namespace tn ON tn.oid=t.relnamespace LEFT JOIN pg_attribute a ON a.attrelid=t.oid AND a.attnum=d.refobjsubid WHERE s.oid=$1::oid", oid)
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
		setColumns = "COALESCE((SELECT json_agg(a.attname ORDER BY x.ord)::text FROM unnest(c.confdelsetcols) WITH ORDINALITY x(num,ord) JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=x.num),'[]')"
	}
	if r.version >= 180000 {
		enforced = "c.conenforced"
		temporal = "c.conperiod"
	}
	rows, e := r.rows("SELECT c.oid::text,c.conname,c.contype::text,c.condeferrable::text,c.condeferred::text,c.convalidated::text,"+enforced+"::text,c.conislocal::text,(c.coninhcount>0)::text,c.connoinherit::text,COALESCE(pg_get_expr(c.conbin,c.conrelid,false),''),COALESCE(n.nspname,''),COALESCE(f.relname,''),c.confupdtype::text,c.confdeltype::text,c.confmatchtype::text,COALESCE((SELECT json_agg(a.attname ORDER BY k.ord)::text FROM unnest(c.conkey) WITH ORDINALITY k(num,ord) JOIN pg_attribute a ON a.attrelid=c.conrelid AND a.attnum=k.num),'[]'),COALESCE((SELECT json_agg(a.attname ORDER BY k.ord)::text FROM unnest(c.confkey) WITH ORDINALITY k(num,ord) JOIN pg_attribute a ON a.attrelid=c.confrelid AND a.attnum=k.num),'[]'),COALESCE(ix.relname,''),"+setColumns+","+temporal+"::text FROM pg_constraint c LEFT JOIN pg_class f ON f.oid=c.confrelid LEFT JOIN pg_namespace n ON n.oid=f.relnamespace LEFT JOIN pg_class ix ON ix.oid=c.conindid WHERE c."+field+"=$1::oid ORDER BY c.conname COLLATE \"C\"", oid)
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
	nulls := "false"
	if r.version >= 150000 {
		nulls = "i.indnullsnotdistinct"
	}
	rows, e := r.rows("SELECT c.oid::text,c.relname,am.amname,i.indisunique::text,"+nulls+"::text,i.indisvalid::text,i.indisready::text,COALESCE(pg_get_expr(i.indpred,i.indrelid,false),''),COALESCE(array_to_json(c.reloptions)::text,'[]'),COALESCE(con.conname,''),i.indnkeyatts::text,EXISTS(SELECT 1 FROM pg_depend WHERE classid='pg_class'::regclass AND objid=c.oid AND deptype='e')::text FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid JOIN pg_am am ON am.oid=c.relam LEFT JOIN pg_constraint con ON con.conindid=c.oid AND con.conrelid=i.indrelid AND con.contype IN ('p','u','x') WHERE i.indrelid=$1::oid ORDER BY c.relname COLLATE \"C\"", oid)
	if e != nil {
		return nil, e
	}
	out := []sc.Index{}
	for _, v := range rows {
		ref := sc.Ref{Kind: "index", Schema: table.Schema, Table: table.Name, Name: v[1]}
		x := sc.Index{Ref: ref, Method: sc.Known(v[2]), Unique: sc.Known(pgBool(v[3])), NullsDistinct: sc.Known(!pgBool(v[4])), Keys: sc.Complete[sc.IndexKey](nil), Includes: sc.Complete[sc.Ref](nil), Predicate: sc.Absent[sc.Expression](), Options: pgOptions(v[8]), Visible: sc.Known(true), Valid: sc.Known(pgBool(v[5])), Ready: sc.Known(pgBool(v[6])), Constraint: sc.Absent[sc.Ref]()}
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
		if v[2] != "btree" || pgBool(v[11]) || len(x.Options.Items) > 0 {
			x.Method = sc.Unknown[string]("indexMethodOrOptions")
			if e = r.issue(&ref, "index", "indexMethodOrOptions", "Index method or options require manual review."); e != nil {
				return nil, e
			}
		}
		keys, e := r.rows("SELECT k.ord::text,COALESCE(a.attname,''),pg_get_indexdef(i.indexrelid,k.ord::integer,false),COALESCE(onsp.nspname,''),COALESCE(op.opcname,''),COALESCE(cn.nspname,''),COALESCE(co.collname,''),COALESCE(i.indoption[k.ord::int-1],0)::text,COALESCE(array_to_json(ia.attoptions)::text,'[]') FROM pg_index i CROSS JOIN unnest(i.indkey) WITH ORDINALITY k(num,ord) LEFT JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=k.num LEFT JOIN pg_opclass op ON op.oid=i.indclass[k.ord::int-1] LEFT JOIN pg_namespace onsp ON onsp.oid=op.opcnamespace LEFT JOIN pg_collation co ON co.oid=i.indcollation[k.ord::int-1] LEFT JOIN pg_namespace cn ON cn.oid=co.collnamespace LEFT JOIN pg_attribute ia ON ia.attrelid=i.indexrelid AND ia.attnum=k.ord WHERE i.indexrelid=$1::oid ORDER BY k.ord", v[0])
		if e != nil {
			return nil, e
		}
		for i, k := range keys {
			if i >= int(pgInt(v[10])) {
				x.Includes.Items = append(x.Includes.Items, pgColumn(table, k[1]))
				continue
			}
			key := sc.IndexKey{Column: sc.Absent[sc.Ref](), Expression: sc.Absent[sc.Expression](), Opclass: sc.Absent[sc.Ref](), Collation: sc.Absent[sc.Ref](), Descending: sc.Known(pgInt(k[7])&1 != 0), NullsFirst: sc.Known(pgInt(k[7])&2 != 0), PrefixLength: sc.Absent[int64](), Options: pgOptions(k[8])}
			if k[1] != "" {
				key.Column = sc.Known(pgColumn(table, k[1]))
			} else {
				key.Expression = sc.Known(sc.Expression{Text: k[2], Dependencies: sc.Collection[sc.Ref]{Items: []sc.Ref{}, State: "unavailable", Code: "expressionIndexKey", Complete: false}})
				if e = r.issue(&ref, "keys", "expressionIndexKey", "Expression index keys require manual review."); e != nil {
					return nil, e
				}
			}
			if k[4] != "" {
				key.Opclass = sc.Known(sc.Ref{Kind: "opclass", Schema: k[3], Name: k[4]})
				if k[3] != "pg_catalog" {
					key.Opclass = sc.Unknown[sc.Ref]("extensionOpclass")
				}
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
