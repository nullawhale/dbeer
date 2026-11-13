package postgres

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type structureReader interface {
	Query(context.Context, string, ...any) (pgx.Rows, error)
	QueryRow(context.Context, string, ...any) pgx.Row
}

func (s *Session) StructureLoad(ctx context.Context, t tableedit.Target) (tableedit.Baseline, error) {
	if !t.Valid() || s.TransactionStatus() != "idle" || !nativePostgresEncodingSafe(s.conn.PgConn().ParameterStatus("client_encoding"), s.conn.PgConn().ParameterStatus("server_encoding")) {
		return tableedit.Baseline{}, tableedit.ErrUnsupported
	}
	tx, e := s.conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if e != nil {
		return tableedit.Baseline{}, tableedit.ErrUnsupported
	}
	defer func() {
		cleanup, stop := context.WithTimeout(context.Background(), 3*time.Second)
		defer stop()
		if err := tx.Rollback(cleanup); err != nil && !errors.Is(err, pgx.ErrTxClosed) {
			closeConnection(s.conn)
		}
	}()
	b, e := readStructure(ctx, tx, t)
	if e != nil {
		return b, e
	}
	if tx.Commit(ctx) != nil {
		return b, tableedit.ErrUnsupported
	}
	return b, nil
}
func structureRollback(tx pgx.Tx) {
	ctx, c := context.WithTimeout(context.Background(), 3*time.Second)
	defer c()
	_ = tx.Rollback(ctx)
}
func readStructure(ctx context.Context, q structureReader, t tableedit.Target) (tableedit.Baseline, error) {
	observe := t.Reconcile
	t.Reconcile = false
	b := tableedit.Baseline{Target: t, Engine: "postgresql", Columns: []tableedit.ObservedColumn{}, Keys: []tableedit.Key{}, Indexes: []tableedit.Index{}, Limitations: []string{"Only ordinary permanent tables are supported. Appended columns are nullable; required-column backfills and physical reconstruction require a separate reviewed plan.", "DDL acquires locks. Apply uses BEGIN, a bounded lock wait, metadata recheck, DDL and COMMIT; Discard cannot undo acknowledged changes."}}
	var environment string
	var schemaOID uint32
	var schemaAllowed bool
	e := q.QueryRow(ctx, `SELECT n.oid, pg_catalog.has_schema_privilege(n.oid, 'USAGE') AND pg_catalog.has_schema_privilege(n.oid, 'CREATE'), pg_catalog.current_database() || ':' || pg_catalog.current_setting('server_version_num') || ':' || pg_catalog.current_setting('server_encoding') || ':' || current_user || ':' || pg_catalog.current_setting('search_path') || ':' || pg_catalog.current_setting('standard_conforming_strings') FROM pg_catalog.pg_namespace n WHERE n.nspname=$1`, t.Schema).Scan(&schemaOID, &schemaAllowed, &environment)
	if e != nil || !schemaAllowed || strings.HasPrefix(t.Schema, "pg_") || t.Schema == "information_schema" {
		return b, tableedit.ErrUnsupported
	}
	b.Scope = tableedit.Fingerprint([]any{environment, schemaOID})
	var oid uint32
	var eligible bool
	var facts string
	e = q.QueryRow(ctx, `SELECT c.oid, c.relkind='r' AND c.relpersistence='p' AND NOT c.relrowsecurity AND NOT c.relforcerowsecurity AND c.reloftype=0 AND NOT c.relispartition AND NOT EXISTS(SELECT 1 FROM pg_catalog.pg_inherits i WHERE i.inhrelid=c.oid OR i.inhparent=c.oid), pg_catalog.row_to_json(c)::pg_catalog.text FROM pg_catalog.pg_class c WHERE c.relnamespace=$1 AND c.relname=$2`, schemaOID, t.Table).Scan(&oid, &eligible, &facts)
	if errors.Is(e, pgx.ErrNoRows) {
		if !t.Create {
			return b, tableedit.ErrUnsupported
		}
		b.Facts, e = readStructureDefaults(ctx, q, t)
		if e != nil {
			return b, e
		}
		tableedit.Summarize(&b)
		b.Fingerprint = tableedit.Fingerprint([]any{environment, schemaOID, t, b.Facts})
		return b, nil
	}
	if t.Create && observe {
		t.Create = false
		b.Target.Create = false
	}
	if e != nil || t.Create || !eligible {
		return b, tableedit.ErrUnsupported
	}
	// Ignore volatile planner statistics; retain identity and structural attributes.
	var class map[string]any
	if json.Unmarshal([]byte(facts), &class) != nil {
		return b, tableedit.ErrUnsupported
	}
	for _, k := range []string{"relpages", "reltuples", "relallvisible", "relallfrozen", "relfrozenxid", "relminmxid", "relhasindex"} {
		delete(class, k)
	}
	// row_to_json(pg_attribute) describes attmissingval, which can call a
	// custom element output routine even when expression deparsing is disabled.
	var unsafeMissing bool
	if err := q.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_type t ON t.oid=a.atttypid WHERE a.attrelid=$1 AND a.attnum>0 AND NOT a.attisdropped AND a.atthasmissing AND (t.oid>=16384 OR t.typoutput>=16384 OR t.typmodout>=16384 OR t.typtype='p'))`, oid).Scan(&unsafeMissing); err != nil {
		return b, tableedit.ErrUnsupported
	}
	if unsafeMissing {
		return b, errors.New("Stored fast-default metadata requires custom type support; use an explicit reviewed migration without evaluating that support during structure observation.")
	}
	rows, e := q.Query(ctx, `SELECT a.attname, pg_catalog.format_type(a.atttypid,NULL), NOT a.attnotnull, NULL::pg_catalog.text, pg_catalog.row_to_json(a)::pg_catalog.text, a.attisdropped FROM pg_catalog.pg_attribute a LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum WHERE a.attrelid=$1 AND a.attnum>0 ORDER BY a.attnum LIMIT 130`, oid)
	if e != nil {
		return b, tableedit.ErrUnsupported
	}
	defer rows.Close()
	attributes := []string{}
	b.Attributes = map[string]map[string]any{}
	for rows.Next() {
		var c tableedit.ObservedColumn
		var raw string
		var dropped bool
		if rows.Scan(&c.Name, &c.NativeType, &c.Nullable, &c.DefaultExpression, &raw, &dropped) != nil {
			return b, tableedit.ErrUnsupported
		}
		attributes = append(attributes, raw)
		var properties map[string]any
		if json.Unmarshal([]byte(raw), &properties) != nil {
			return b, tableedit.ErrUnsupported
		}
		b.Attributes[c.Name] = properties
		if len(attributes) > tableedit.MaxColumns {
			return b, tableedit.ErrUnsupported
		}
		if !dropped {
			b.Columns = append(b.Columns, c)
		}
	}
	if rows.Err() != nil {
		return b, tableedit.ErrUnsupported
	}
	factsCapture, e := readStructureFacts(ctx, q, t, oid)
	if e != nil {
		return b, e
	}
	b.Identity = strconv.FormatUint(uint64(oid), 10)
	guard := map[string]any{}
	for _, name := range []string{"relowner", "relam", "reltablespace", "relpersistence", "relkind", "relrowsecurity", "relforcerowsecurity", "reloftype", "relispartition", "reloptions", "relacl"} {
		guard[name] = class[name]
	}
	b.Guard = tableedit.Fingerprint(guard)
	b.Facts = factsCapture
	if len(factsCapture.RawExpressions) > 0 {
		b.Limitations = append(b.Limitations, "Some expressions require custom type support code to describe. Raw catalog proof is retained; affected attribute changes and dependent renames require an explicit reviewed migration. Untouched raw proof is compared without invoking those routines.")
	}
	tableedit.Summarize(&b)
	for i := range b.Columns {
		c := &b.Columns[i]
		if actual, ok := tableedit.FindColumn(b, c.Name); ok {
			if actual.Generated.Value != nil && actual.Generated.Value.Expression != nil {
				v := actual.Generated.Value.Expression.Text
				c.DefaultExpression = &v
			} else if actual.Default.Value != nil && actual.Default.Value.Expression != nil {
				v := actual.Default.Value.Expression.Text
				c.DefaultExpression = &v
			}
		}
		if typ := c.EditableType; typ != nil {
			switch typ.Kind {
			case "varchar":
				c.NativeType += fmt.Sprintf("(%d)", typ.Length)
			case "numeric":
				c.NativeType += fmt.Sprintf("(%d,%d)", typ.Precision, typ.Scale)
			}
		}
	}
	b.Fingerprint = tableedit.Fingerprint([]any{environment, schemaOID, oid, class, attributes, b.Columns, b.Facts})
	return b, nil
}

var structureNumeric = regexp.MustCompile(`^[+-]?[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$`)

func structureColumn(c tableedit.Column) (string, error) {
	if !c.Valid() {
		return "", tableedit.ErrInvalid
	}
	typ := map[string]string{"integer": "pg_catalog.int4", "bigint": "pg_catalog.int8", "boolean": "pg_catalog.bool", "text": "pg_catalog.text"}[c.Type.Kind]
	switch c.Type.Kind {
	case "reference":
		if c.Type.Reference == nil || c.Resolved == nil || c.Resolved.Reference != *c.Type.Reference {
			return "", tableedit.ErrUnsupported
		}
		typ = pgx.Identifier{c.Type.Reference.Schema, c.Type.Reference.Name}.Sanitize()
	case "varchar":
		typ = fmt.Sprintf("pg_catalog.varchar(%d)", c.Type.Length)
	case "numeric":
		typ = fmt.Sprintf("pg_catalog.numeric(%d,%d)", c.Type.Precision, c.Type.Scale)
	}
	if typ == "" {
		return "", tableedit.ErrUnsupported
	}
	out := pgx.Identifier{c.Name}.Sanitize() + " " + typ
	if !c.Nullable {
		out += " NOT NULL"
	}
	switch c.Default.Kind {
	case "none":
	case "null":
		out += " DEFAULT NULL"
	case "text":
		if c.Type.Kind != "text" && c.Type.Kind != "varchar" && c.Type.Kind != "reference" {
			return "", tableedit.ErrInvalid
		}
		out += " DEFAULT " + postgresTextLiteral(*c.Default.Value)
	case "numeric":
		if c.Type.Kind != "integer" && c.Type.Kind != "bigint" && c.Type.Kind != "numeric" && c.Type.Kind != "reference" || !structureNumeric.MatchString(*c.Default.Value) {
			return "", tableedit.ErrInvalid
		}
		out += " DEFAULT " + *c.Default.Value
	case "boolean":
		if c.Type.Kind != "boolean" && c.Type.Kind != "reference" || (*c.Default.Value != "true" && *c.Default.Value != "false") {
			return "", tableedit.ErrInvalid
		}
		out += " DEFAULT " + *c.Default.Value
	case "expression":
		expr, err := tableedit.ExpressionSlot("postgresql", *c.Default.Value)
		if err != nil {
			return "", err
		}
		out += " DEFAULT " + expr
	default:
		return "", tableedit.ErrInvalid
	}
	if c.Generated != nil && c.Generated.Storage != "none" {
		expr, err := tableedit.ExpressionSlot("postgresql", c.Generated.Expression)
		if err != nil {
			return "", err
		}
		out += " GENERATED ALWAYS AS " + expr + " " + strings.ToUpper(c.Generated.Storage)
	}
	if c.Identity != nil && c.Identity.Kind != "none" {
		x := pgIdentityDefinition(*c.Identity)
		if x == "" {
			return "", tableedit.ErrUnsupported
		}
		out += x
	}
	return out, nil
}
func (s *Session) StructureRender(b tableedit.Baseline, d tableedit.Draft) ([]string, []string, error) {
	if !d.Valid() || !b.Target.Valid() {
		return nil, nil, tableedit.ErrInvalid
	}
	parts := []string{}
	for _, c := range d.Columns {
		for _, old := range b.Columns {
			if old.Name == c.Name {
				return nil, nil, tableedit.ErrInvalid
			}
		}
		x, e := structureColumn(c)
		if e != nil {
			return nil, nil, e
		}
		parts = append(parts, x)
	}
	target := pgx.Identifier{b.Target.Schema, b.Target.Table}.Sanitize()
	sql := "CREATE TABLE " + target + " (" + strings.Join(parts, ", ") + ");"
	if !b.Target.Create {
		if len(parts) != 1 || !d.Columns[0].Nullable {
			return nil, nil, tableedit.ErrInvalid
		}
		sql = "ALTER TABLE " + target + " ADD COLUMN " + parts[0] + ";"
	}
	return []string{sql}, []string{"Apply uses a dedicated session and a short transaction with a 5-second lock timeout. Existing tables are locked ACCESS EXCLUSIVE before the baseline recheck. DDL may block other sessions or scan/rewrite the table. No automatic replay or rollback of acknowledged changes."}, nil
}
func (s *Session) StructureApply(ctx context.Context, b tableedit.Baseline, sql []string) tableedit.Execution {
	return s.applyStructureStep(ctx, b, sql, nil)
}

type structureGuards struct {
	Types   []tableedit.TypeGuard
	Indexes []tableedit.IndexGuard
}

func (s *Session) applyStructureStep(ctx context.Context, b tableedit.Baseline, sql []string, refs []tableedit.Baseline, guardSets ...structureGuards) tableedit.Execution {
	fail := func(state, message string) tableedit.Execution {
		return tableedit.Execution{State: state, Message: message}
	}
	if ctx.Err() != nil {
		return fail("notStarted", "Cancelled before dispatch.")
	}
	if len(sql) != 1 || s.TransactionStatus() != "idle" {
		return fail("notStarted", "The DDL session is not idle.")
	}
	tx, e := s.conn.BeginTx(ctx, pgx.TxOptions{})
	if e != nil {
		return fail("notStarted", "Cannot begin the DDL transaction.")
	}
	defer func() {
		cleanup, stop := context.WithTimeout(context.Background(), 3*time.Second)
		defer stop()
		if err := tx.Rollback(cleanup); err != nil && !errors.Is(err, pgx.ErrTxClosed) {
			closeConnection(s.conn)
		}
	}()
	if _, e = tx.Exec(ctx, "SET LOCAL lock_timeout = '5s'"); e != nil {
		return fail("notStarted", "Cannot set the declared lock timeout.")
	}
	if !b.Target.Create {
		if _, e = tx.Exec(ctx, "LOCK TABLE "+pgx.Identifier{b.Target.Schema, b.Target.Table}.Sanitize()+" IN ACCESS EXCLUSIVE MODE"); e != nil {
			return fail("notStarted", "The table lock could not be acquired. No DDL was sent.")
		}
	}
	for _, ref := range refs {
		if _, e = tx.Exec(ctx, "LOCK TABLE "+pgx.Identifier{ref.Target.Schema, ref.Target.Table}.Sanitize()+" IN ACCESS EXCLUSIVE MODE"); e != nil {
			return fail("notStarted", "Referenced table lock could not be acquired.")
		}
		observed, err := readStructure(ctx, tx, ref.Target)
		if err != nil || observed.Fingerprint != ref.Fingerprint {
			return fail("notStarted", tableedit.ErrStale.Error())
		}
	}
	fresh, e := readStructure(ctx, tx, b.Target)
	if e != nil || fresh.Fingerprint != b.Fingerprint {
		return fail("notStarted", tableedit.ErrStale.Error())
	}
	for _, guards := range guardSets {
		if !verifyStructureTypes(ctx, tx, guards.Types) || !verifyIndexGuards(ctx, tx, guards.Indexes) {
			return fail("notStarted", "A referenced type, index method, operator class, collation or its privileges changed. Prepare a fresh preview.")
		}
	}
	if ctx.Err() != nil {
		return fail("notStarted", "Cancelled before DDL dispatch.")
	}
	if _, e = tx.Exec(ctx, sql[0]); e != nil {
		var server *pgconn.PgError
		if errors.As(e, &server) {
			return fail("failed", "PostgreSQL rejected the DDL. No commit was sent.")
		}
		return fail("unknown", "DDL completion could not be confirmed. Reconcile before another edit.")
	}
	commit := func() error { return tx.Commit(ctx) }
	if s.structureCommitOverride != nil {
		e = s.structureCommitOverride(commit)
	} else {
		e = commit()
	}
	if e != nil {
		return fail("unknown", "Commit acknowledgement was lost. The change may have been applied.")
	}
	return fail("applied", "")
}
