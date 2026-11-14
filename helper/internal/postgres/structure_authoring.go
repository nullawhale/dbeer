package postgres

import (
	"context"
	"fmt"
	"reflect"
	"sort"
	"strings"

	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
	"github.com/jackc/pgx/v5"
)

func resolveStructureType(ctx context.Context, q structureReader, ref tableedit.TypeReference) (tableedit.TypeGuard, error) {
	q = pgCatalogReader(q)
	guard := tableedit.TypeGuard{Reference: ref, Collation: sc.Absent[sc.Ref]()}
	if !ref.Valid() {
		return guard, tableedit.ErrInvalid
	}
	var oid, storage, collationOID string
	var allowed bool
	if q.QueryRow(ctx, `SELECT t.oid::pg_catalog.text,t.typstorage::pg_catalog.text,t.typcollation::pg_catalog.text,t.typisdefined AND t.typtype<>'p' AND pg_catalog.has_type_privilege(t.oid,'USAGE') AND pg_catalog.has_schema_privilege(n.oid,'USAGE') FROM pg_catalog.pg_type t JOIN pg_catalog.pg_namespace n ON n.oid=t.typnamespace WHERE n.nspname=$1 AND t.typname=$2`, ref.Schema, ref.Name).Scan(&oid, &storage, &collationOID, &allowed) != nil || !allowed {
		return guard, tableedit.ErrUnsupported
	}
	limits := sc.Limits{Nodes: 128, Members: 1024, Bytes: 1 << 20, Scalar: 65536}
	sink := sc.NewCollector(ctx, limits)
	r := &schemaCapture{ctx: ctx, tx: q, sink: sink, spec: sc.CaptureSpec{Limits: limits}, types: map[string]sc.TypeUse{}, loading: map[string]bool{}, sequences: map[string]bool{}, skipCustomTypeFormatting: true}
	if q.QueryRow(ctx, "SELECT pg_catalog.current_setting('server_version_num')::pg_catalog.int4").Scan(&r.version) != nil {
		return guard, tableedit.ErrUnsupported
	}
	u, err := r.typeUse(oid, -1, 0)
	if err != nil {
		return guard, err
	}
	guard.Identity, guard.Use, guard.Storage, guard.Definitions = oid, u, storage, sink.Capture.Types
	if len(r.rawExpressions) > 0 {
		guard.RawExpressions = r.rawExpressions
		return guard, fmt.Errorf("Selected type expression metadata requires custom type support code. Its raw catalog proof is retained; Preview never invokes those routines. Use an explicit reviewed migration.")
	}
	for _, def := range sink.Capture.Types {
		if def.Kind.Value == nil || !def.Attributes.Complete || !def.Checks.Complete {
			return guard, tableedit.ErrUnsupported
		}
	}
	guard.Identity, guard.Use, guard.Storage, guard.Definitions = oid, u, storage, sink.Capture.Types
	if collationOID != "0" {
		var schema, name string
		if q.QueryRow(ctx, `SELECT n.nspname,c.collname FROM pg_catalog.pg_collation c JOIN pg_catalog.pg_namespace n ON n.oid=c.collnamespace WHERE c.oid=$1::pg_catalog.oid`, collationOID).Scan(&schema, &name) != nil {
			return guard, tableedit.ErrUnsupported
		}
		guard.Collation = sc.Known(sc.Ref{Kind: "collation", Schema: schema, Name: name})
		guard.CollationProperties, err = r.typeCollation(collationOID)
		if err != nil {
			return guard, err
		}
	}
	for _, def := range guard.Definitions {
		if def.Ref.Schema == ref.Schema && def.Ref.Name == ref.Name && def.Default.Value != nil {
			v := *def.Default.Value
			guard.InheritedDefault = &v
		}
	}
	return guard, nil
}

func (s *Session) resolveAuthoredTypes(ctx context.Context, b tableedit.Baseline, d tableedit.Draft) (tableedit.Draft, []tableedit.TypeGuard, error) {
	guards := []tableedit.TypeGuard{}
	d.Columns = append([]tableedit.Column(nil), d.Columns...)
	for i := range d.Columns {
		c := &d.Columns[i]
		if c.Type.Reference == nil {
			continue
		}
		guard, err := resolveStructureType(ctx, s.conn, *c.Type.Reference)
		if err != nil {
			return d, nil, err
		}
		c.Resolved = &guard
		found := false
		for _, old := range guards {
			if old.Reference == guard.Reference {
				found = true
			}
		}
		if !found {
			guards = append(guards, guard)
		}
	}
	return d, guards, nil
}

func verifyStructureTypes(ctx context.Context, q structureReader, guards []tableedit.TypeGuard) bool {
	for _, old := range guards {
		current, err := resolveStructureType(ctx, q, old.Reference)
		if err != nil || !reflect.DeepEqual(current, old) {
			return false
		}
	}
	return true
}

func pgIdentityDefinition(x tableedit.Identity) string {
	mode := map[string]string{"always": "ALWAYS", "byDefault": "BY DEFAULT"}[x.Kind]
	if mode == "" {
		return ""
	}
	value := " GENERATED " + mode + " AS IDENTITY"
	if options := tableedit.IdentitySQL(x); options != "" {
		value += " (" + options + ")"
	}
	return value
}

func validatePGAuthoredColumn(b tableedit.Baseline, c tableedit.Column) error {
	if c.Generated != nil && c.Generated.Storage != "none" {
		if b.Facts == nil || c.Generated.Storage == "virtual" && b.Facts.ServerVersion < 180000 {
			return fmt.Errorf("Virtual generated columns require PostgreSQL 18 or later.")
		}
		if c.Generated.Storage == "virtual" && c.Type.Reference != nil {
			return fmt.Errorf("Virtual generated columns require a built-in type; referenced types are available for stored generation.")
		}
		if _, err := tableedit.ExpressionSlot("postgresql", c.Generated.Expression); err != nil {
			return err
		}
	}
	if c.Identity != nil && c.Identity.Kind != "none" && pgIdentityDefinition(*c.Identity) == "" {
		return tableedit.ErrUnsupported
	}
	return nil
}

func pgGeneratedChange(b tableedit.Baseline, c tableedit.ColumnChange, target string) ([]string, error) {
	old, ok := tableedit.FindColumn(b, c.Name)
	if !ok || old.Generated.Value == nil || c.Generated == nil {
		return nil, tableedit.ErrUnsupported
	}
	prefix := "ALTER TABLE " + target + " ALTER COLUMN " + pgx.Identifier{c.Name}.Sanitize()
	if c.Generated.Storage == "none" {
		if old.Generated.Value.Kind == "none" {
			return nil, tableedit.ErrInvalid
		}
		if old.Generated.Value.Kind != "stored" {
			return nil, fmt.Errorf("Dropping generation is supported for stored columns only.")
		}
		return []string{prefix + " DROP EXPRESSION;"}, nil
	}
	if old.Generated.Value.Kind != c.Generated.Storage || b.Facts.ServerVersion < 170000 {
		return nil, fmt.Errorf("Changing a generation expression requires PostgreSQL 17 or later and the existing storage kind; adding generation to a base column requires reconstruction.")
	}
	value, err := tableedit.ExpressionSlot("postgresql", c.Generated.Expression)
	if err != nil {
		return nil, err
	}
	return []string{prefix + " SET EXPRESSION AS " + value + ";"}, nil
}

func pgIdentityChange(b tableedit.Baseline, c tableedit.ColumnChange, target string) ([]string, error) {
	old, ok := tableedit.FindColumn(b, c.Name)
	if !ok || old.Identity.Value == nil || c.Identity == nil {
		return nil, tableedit.ErrUnsupported
	}
	prefix := "ALTER TABLE " + target + " ALTER COLUMN " + pgx.Identifier{c.Name}.Sanitize()
	x := *c.Identity
	if x.Kind != "none" && x.Kind != "always" && x.Kind != "byDefault" {
		return nil, tableedit.ErrUnsupported
	}
	if x.Kind == "none" {
		if old.Identity.Value.Kind == "none" {
			return nil, tableedit.ErrInvalid
		}
		return []string{prefix + " DROP IDENTITY;"}, nil
	}
	if old.Type.Value == nil || old.Type.Value.Ref.Schema != "pg_catalog" || (old.Type.Value.Ref.Name != "int4" && old.Type.Value.Ref.Name != "int8") {
		return nil, tableedit.ErrUnsupported
	}
	if old.Identity.Value.Kind == "none" {
		if old.Nullable.Value == nil || *old.Nullable.Value || old.Default.Value == nil || old.Default.Value.Kind != "none" {
			return nil, fmt.Errorf("Adding identity requires an existing NOT NULL integer column without a default; review prerequisite changes separately.")
		}
		return []string{prefix + " ADD" + pgIdentityDefinition(x) + ";"}, nil
	}
	clause := "ALTER COLUMN " + pgx.Identifier{c.Name}.Sanitize()
	parts := []string{clause + " SET GENERATED " + map[string]string{"always": "ALWAYS", "byDefault": "BY DEFAULT"}[x.Kind]}
	for _, option := range tableedit.IdentityOptions(x) {
		parts = append(parts, clause+" "+option)
	}
	return []string{"ALTER TABLE " + target + " " + strings.Join(parts, ", ") + ";"}, nil
}

func readStructureSequences(ctx context.Context, q structureReader, t tableedit.Target, oid uint32) ([]sc.Sequence, error) {
	rows, err := q.Query(ctx, `SELECT n.nspname,s.relname,a.attname,q.seqtypid::pg_catalog.text,q.seqstart::pg_catalog.text,q.seqincrement::pg_catalog.text,q.seqmin::pg_catalog.text,q.seqmax::pg_catalog.text,q.seqcache::pg_catalog.text,q.seqcycle FROM pg_catalog.pg_depend d JOIN pg_catalog.pg_class s ON pg_catalog.oideq(d.classid,'pg_catalog.pg_class'::pg_catalog.regclass) AND pg_catalog.oideq(s.oid,d.objid) AND pg_catalog.chareq(s.relkind,'S') JOIN pg_catalog.pg_namespace n ON pg_catalog.oideq(n.oid,s.relnamespace) JOIN pg_catalog.pg_sequence q ON pg_catalog.oideq(q.seqrelid,s.oid) JOIN pg_catalog.pg_attribute a ON pg_catalog.oideq(a.attrelid,d.refobjid) AND pg_catalog.int4eq(a.attnum::pg_catalog.int4,d.refobjsubid) WHERE d.refclassid OPERATOR(pg_catalog.=) ANY(ARRAY['pg_catalog.pg_class'::pg_catalog.regclass::pg_catalog.oid]) AND d.refobjid OPERATOR(pg_catalog.=) ANY(ARRAY[$1::pg_catalog.oid]) AND (pg_catalog.chareq(d.deptype,'a') OR pg_catalog.chareq(d.deptype,'i'))`, oid)
	if err != nil {
		return nil, tableedit.ErrUnsupported
	}
	defer rows.Close()
	out := []sc.Sequence{}
	for rows.Next() {
		var schema, name, column, typeOID, start, increment, min, max, cache string
		var cycle bool
		if rows.Scan(&schema, &name, &column, &typeOID, &start, &increment, &min, &max, &cache, &cycle) != nil {
			return nil, tableedit.ErrUnsupported
		}
		kind := map[string]string{"23": "integer", "20": "bigint", "21": "smallint"}[typeOID]
		if kind == "" {
			return nil, tableedit.ErrUnsupported
		}
		typeUse := tableedit.ExpectedNewType("postgresql", tableedit.DataType{Kind: kind})
		if kind == "smallint" {
			typeUse.Ref.Name = "int2"
		}
		out = append(out, sc.Sequence{Ref: sc.Ref{Kind: "sequence", Schema: schema, Name: name}, Type: sc.Known(typeUse), Start: sc.Known(start), Increment: sc.Known(increment), Min: sc.Known(min), Max: sc.Known(max), Cache: sc.Known(cache), Cycle: sc.Known(cycle), Owner: sc.Known(sc.Ref{Kind: "column", Schema: t.Schema, Table: t.Table, Name: column})})
		if len(out) > tableedit.MaxColumns {
			return nil, tableedit.ErrUnsupported
		}
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i].Ref, out[j].Ref
		if a.Schema != b.Schema {
			return a.Schema < b.Schema
		}
		return a.Name < b.Name
	})
	return out, rows.Err()
}

func pgExpressionRisk() string {
	return strings.TrimSpace("Authored expressions, referenced type input/check functions and value generation may run only during Apply or later writes. Preview only reads catalog metadata and validates expression boundaries; it does not evaluate expressions or advance sequences. Concurrent changes to type/function definitions require a fresh preview.")
}
