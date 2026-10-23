package postgres

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"sort"
	"strconv"
	"strings"

	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/textdiff"
	"github.com/jackc/pgx/v5"
)

// RenderSchemaDefinition formats frozen catalog facts without opening a
// connection. Arbitrary SQL expressions retain their captured spelling.
func RenderSchemaDefinition(ctx context.Context, capture sc.Capture, ref sc.Ref) (sc.Definition, error) {
	r := pgDefinition{w: &sc.DefinitionWriter{Context: ctx}, types: map[sc.Ref]sc.TypeDefinition{}}
	for _, t := range capture.Types {
		r.types[t.Ref] = t
	}
	switch ref.Kind {
	case "table":
		for _, t := range capture.Tables {
			if t.Ref == ref {
				r.table(t)
				return r.w.Finish()
			}
		}
	case "type":
		for _, t := range capture.Types {
			if t.Ref == ref {
				r.typeDefinition(t)
				return r.w.Finish()
			}
		}
	case "sequence":
		for _, s := range capture.Sequences {
			if s.Ref == ref {
				r.sequence(s)
				return r.w.Finish()
			}
		}
	case "schema":
		r.w.Note("Schema existence and ownership are available in metadata; a SQL definition is unavailable.")
		return r.w.Finish()
	}
	r.w.Note("This property is not represented in SQL; see metadata details.")
	return r.w.Finish()
}

type pgDefinition struct {
	w     *sc.DefinitionWriter
	types map[sc.Ref]sc.TypeDefinition
}

func pgDefinitionRequired[T any](w *sc.DefinitionWriter, label string, f sc.Fact[T]) *T {
	v := sc.DefinitionFact(w, label, f)
	if v == nil && f.State == "known" {
		w.Note("Unavailable " + label + ".")
	}
	return v
}

func (r pgDefinition) write(parts ...string) {
	for _, s := range parts {
		r.w.Write(s)
	}
}

// Bound scalars before escaping, decoding, or concatenating them. Catalog limits
// allow megabyte expressions, whereas the whole definition preview is 128 KiB.
func (r pgDefinition) scalar(s string) string {
	if len(s) <= textdiff.MaxTextBytes {
		return s
	}
	r.w.Note("A catalog value exceeds the SQL preview limit.")
	return strings.ToValidUTF8(s[:textdiff.MaxTextBytes], "")
}
func (r pgDefinition) name(name string) string { return pgx.Identifier{r.scalar(name)}.Sanitize() }
func (r pgDefinition) ref(ref sc.Ref) string {
	if ref.Schema == "" {
		return r.name(ref.Name)
	}
	return r.name(ref.Schema) + "." + r.name(ref.Name)
}
func (r pgDefinition) literal(value string) string {
	return "E'" + strings.NewReplacer("\\", "\\\\", "'", "''", "\x00", "\\000", "\n", "\\n", "\r", "\\r").Replace(r.scalar(value)) + "'"
}
func (r pgDefinition) expr(label string, expression *sc.Expression) {
	if expression == nil {
		r.w.Note("Unavailable " + label + " expression.")
		r.write("/* expression unavailable */")
		return
	}
	sc.DefinitionItems(r.w, label+" dependencies", expression.Dependencies)
	r.write(r.scalar(expression.Text))
}
func (r pgDefinition) typ(u sc.TypeUse) { r.typeAt(u, 0) }
func (r pgDefinition) typeAt(u sc.TypeUse, depth int) {
	if depth >= 32 {
		r.w.Note("Recursive type exceeds the SQL preview limit.")
		r.write("/* type unavailable */")
		return
	}
	if u.Kind == "array" {
		if u.Element == nil {
			r.w.Note("Unavailable array element type.")
			r.write("/* type unavailable */")
			return
		}
		dimensions := 1
		if m := pgDefinitionRequired(r.w, "array dimensions", u.Modifiers); m != nil && m.ArrayDimensions > 0 {
			dimensions = m.ArrayDimensions
		}
		if dimensions > 32 {
			r.w.Note("Unsupported array dimensions.")
			dimensions = 1
		}
		r.typeAt(*u.Element, depth+1)
		r.write(strings.Repeat("[]", dimensions))
		return
	}
	if u.Ref.Name == "" {
		r.w.Note("Unavailable column type.")
		r.write("/* type unavailable */")
		return
	}
	if u.Ref.Schema != "pg_catalog" {
		r.write(r.ref(u.Ref))
		if m := pgDefinitionRequired(r.w, "type modifiers", u.Modifiers); m != nil && m.Raw != nil {
			if m.SQL != nil {
				r.write(r.scalar(*m.SQL))
			} else {
				r.w.Note("Unavailable user-defined type modifier SQL.")
			}
		}
		if m := pgDefinitionRequired(r.w, "type modifiers", u.Modifiers); m != nil && (m.Length != nil || m.Precision != nil || m.Scale != nil || m.DatetimePrecision != nil || m.Interval != nil) {
			r.w.Note("User-defined type modifiers require metadata review.")
		}
		return
	}
	aliases := map[string]string{"int2": "smallint", "int4": "integer", "int8": "bigint", "float4": "real", "float8": "double precision", "bpchar": "character", "varchar": "character varying", "bool": "boolean", "varbit": "bit varying", "timestamp": "timestamp", "timestamptz": "timestamp", "time": "time", "timetz": "time", "numeric": "numeric", "interval": "interval", "bit": "bit"}
	if alias, ok := aliases[u.Ref.Name]; ok {
		r.write(alias)
	} else {
		r.write(r.ref(u.Ref))
	}
	m := pgDefinitionRequired(r.w, "type modifiers", u.Modifiers)
	if m != nil {
		switch u.Ref.Name {
		case "numeric":
			if m.Precision != nil {
				r.write("(", strconv.FormatInt(*m.Precision, 10))
				if m.Scale != nil {
					r.write(", ", strconv.FormatInt(*m.Scale, 10))
				}
				r.write(")")
			}
		case "varchar", "bpchar", "bit", "varbit":
			if m.Length != nil {
				r.write("(", strconv.FormatInt(*m.Length, 10), ")")
			}
		case "timestamp", "timestamptz", "time", "timetz":
			if m.DatetimePrecision != nil {
				r.write("(", strconv.FormatInt(*m.DatetimePrecision, 10), ")")
			}
		case "interval":
			if m.Interval != nil && *m.Interval != 32767 {
				fields := map[int64]string{4: "YEAR", 2: "MONTH", 6: "YEAR TO MONTH", 8: "DAY", 1024: "HOUR", 2048: "MINUTE", 4096: "SECOND", 1032: "DAY TO HOUR", 3080: "DAY TO MINUTE", 7176: "DAY TO SECOND", 3072: "HOUR TO MINUTE", 7168: "HOUR TO SECOND", 6144: "MINUTE TO SECOND"}
				if field, ok := fields[*m.Interval]; ok {
					r.write(" ", field)
				} else {
					r.w.Note("Unsupported interval fields.")
				}
			}
			if m.DatetimePrecision != nil && *m.DatetimePrecision != 65535 {
				r.write("(", strconv.FormatInt(*m.DatetimePrecision, 10), ")")
			}
		}
	}
	if u.Ref.Name == "timestamptz" || u.Ref.Name == "timetz" {
		r.write(" with time zone")
	}
}
func (r pgDefinition) defaultSQL(d sc.Default) {
	switch d.Kind {
	case "none":
		return
	case "sqlNull":
		r.write(" DEFAULT NULL")
		return
	case "expression":
		r.write(" DEFAULT ")
		r.expr("default", d.Expression)
		return
	case "sequence":
		if d.Sequence != nil {
			r.write(" DEFAULT nextval(", r.literal(r.ref(*d.Sequence)), "::regclass)")
			return
		}
	case "literal":
		if d.Value != nil {
			if d.Encoding == "base64" {
				if len(*d.Value) <= textdiff.MaxTextBytes {
					if b, e := base64.StdEncoding.DecodeString(*d.Value); e == nil {
						r.write(" DEFAULT ", r.literal("\\x"+hex.EncodeToString(b)), "::bytea")
						return
					}
				}
				r.w.Note("Binary default is unavailable or exceeds the SQL preview limit.")
				return
			}
			if d.Encoding != "" && d.Encoding != "utf8" && d.Encoding != "text" {
				r.w.Note("Unsupported literal default encoding.")
				return
			}
			r.write(" DEFAULT ", r.literal(*d.Value))
			return
		}
	}
	r.w.Note("Unavailable default.")
}
func (r pgDefinition) column(c sc.Column, attribute bool) {
	r.write(r.name(c.Ref.Name), " ")
	if typ := pgDefinitionRequired(r.w, "column type", c.Type); typ != nil {
		r.typ(*typ)
	} else {
		r.w.Note("Unavailable column type.")
		r.write("/* type unavailable */")
	}
	if collation := sc.DefinitionFact(r.w, "column collation", c.Collation); collation != nil {
		r.write(" COLLATE ", r.ref(*collation))
	}
	if attribute {
		return
	}
	if nullable := pgDefinitionRequired(r.w, "column nullability", c.Nullable); nullable != nil && !*nullable {
		r.write(" NOT NULL")
	}
	if d := pgDefinitionRequired(r.w, "column default", c.Default); d != nil {
		r.defaultSQL(*d)
	}
	if generated := pgDefinitionRequired(r.w, "generated column", c.Generated); generated != nil && generated.Kind != "none" {
		storage := map[string]string{"stored": "STORED", "virtual": "VIRTUAL"}[generated.Kind]
		if storage == "" {
			r.w.Note("Unsupported generated column kind.")
		} else {
			r.write(" GENERATED ALWAYS AS (")
			r.expr("generated column", generated.Expression)
			r.write(") ", storage)
		}
	}
	if identity := pgDefinitionRequired(r.w, "column identity", c.Identity); identity != nil && identity.Kind != "none" {
		mode := map[string]string{"always": "ALWAYS", "byDefault": "BY DEFAULT"}[identity.Kind]
		if mode == "" {
			r.w.Note("Unsupported identity kind.")
		} else {
			r.write(" GENERATED ", mode, " AS IDENTITY")
			if identity.Sequence != nil {
				r.write(" (SEQUENCE NAME ", r.ref(*identity.Sequence), ")")
			}
		}
	}
	if visible := pgDefinitionRequired(r.w, "column visibility", c.Visible); visible != nil && !*visible {
		r.w.Note("Unsupported invisible PostgreSQL column.")
	}
}
func (r pgDefinition) columns(c sc.Collection[sc.Ref], label string) {
	items := sc.DefinitionItems(r.w, label, c)
	if len(items) == 0 {
		r.w.Note("Unavailable " + label + ".")
		r.write("/* columns unavailable */")
		return
	}
	for i, ref := range items {
		if r.w.Full() {
			break
		}
		if i > 0 {
			r.write(", ")
		}
		r.write(r.name(ref.Name))
	}
}
func (r pgDefinition) constraint(c sc.Constraint, backing *sc.Index, domain bool) {
	kind := pgDefinitionRequired(r.w, "constraint kind", c.Kind)
	if kind == nil {
		r.write("/* constraint unavailable */")
		return
	}
	r.write("CONSTRAINT ", r.name(c.Ref.Name), " ")
	switch *kind {
	case "p", "u":
		if *kind == "p" {
			r.write("PRIMARY KEY")
		} else {
			r.write("UNIQUE")
			nulls := sc.DefinitionFact(r.w, "constraint null semantics", c.NullsDistinct)
			if nulls == nil && backing != nil {
				nulls = sc.DefinitionFact(r.w, "backing index null semantics", backing.NullsDistinct)
			}
			if nulls != nil && !*nulls {
				r.write(" NULLS NOT DISTINCT")
			}
		}
		r.write(" (")
		r.columns(c.Columns, "constraint columns")
		r.write(")")
		if backing != nil {
			if len(sc.DefinitionItems(r.w, "constraint included columns", backing.Includes)) > 0 {
				r.write(" INCLUDE (")
				r.columns(backing.Includes, "constraint included columns")
				r.write(")")
			}
			r.options(backing.Options, " WITH (")
			r.indexState(*backing)
		}
	case "n":
		r.write("NOT NULL ")
		r.columns(c.Columns, "not-null column")
		if v := pgDefinitionRequired(r.w, "constraint inheritance", c.NoInherit); v != nil && *v {
			r.write(" NO INHERIT")
		}
	case "c":
		r.write("CHECK (")
		r.expr("check constraint", sc.DefinitionFact(r.w, "check", c.Check))
		r.write(")")
		if v := pgDefinitionRequired(r.w, "constraint inheritance", c.NoInherit); v != nil && *v {
			if domain {
				r.w.Note("Unsupported domain constraint inheritance.")
			} else {
				r.write(" NO INHERIT")
			}
		}
	case "f":
		r.write("FOREIGN KEY (")
		r.columns(c.Columns, "foreign-key columns")
		r.write(") REFERENCES ")
		if target := pgDefinitionRequired(r.w, "foreign-key target", c.Target); target != nil {
			r.write(r.ref(*target))
		} else {
			r.write("/* target unavailable */")
		}
		r.write(" (")
		pairs := sc.DefinitionItems(r.w, "foreign-key mapping", c.ForeignKeys)
		if len(pairs) == 0 {
			r.w.Note("Unavailable referenced columns.")
			r.write("/* columns unavailable */")
		}
		for i, pair := range pairs {
			if r.w.Full() {
				break
			}
			if i > 0 {
				r.write(", ")
			}
			r.write(r.name(pair.Target.Name))
		}
		r.write(")")
		if match := pgDefinitionRequired(r.w, "foreign-key match", c.Match); match != nil {
			switch *match {
			case "f":
				r.write(" MATCH FULL")
			case "p":
				r.write(" MATCH PARTIAL")
			case "s":
			default:
				r.w.Note("Unsupported foreign-key match.")
			}
		}
		for _, action := range []struct {
			name string
			fact sc.Fact[string]
		}{{"UPDATE", c.Update}, {"DELETE", c.Delete}} {
			if v := pgDefinitionRequired(r.w, "foreign-key "+action.name, action.fact); v != nil {
				a := map[string]string{"a": "NO ACTION", "r": "RESTRICT", "c": "CASCADE", "n": "SET NULL", "d": "SET DEFAULT"}[*v]
				if a == "" {
					r.w.Note("Unsupported foreign-key action.")
				} else {
					r.write(" ON ", action.name, " ", a)
					if action.name == "DELETE" {
						set := sc.DefinitionItems(r.w, "foreign-key SET columns", c.SetColumns)
						if len(set) > 0 {
							if *v == "n" || *v == "d" {
								r.write(" (")
								r.columns(c.SetColumns, "SET columns")
								r.write(")")
							} else {
								r.w.Note("Unexpected foreign-key SET columns.")
							}
						}
					}
				}
			}
		}
	default:
		r.w.Note("Unsupported constraint kind.")
		r.write("/* definition unavailable */")
	}
	if v := pgDefinitionRequired(r.w, "constraint deferrability", c.Deferrable); v != nil && *v {
		if domain || *kind == "c" {
			r.w.Note("Unsupported constraint deferrability.")
		} else {
			r.write(" DEFERRABLE")
			if initial := pgDefinitionRequired(r.w, "constraint initial deferral", c.InitiallyDeferred); initial != nil {
				if *initial {
					r.write(" INITIALLY DEFERRED")
				} else {
					r.write(" INITIALLY IMMEDIATE")
				}
			}
		}
	}
	if v := pgDefinitionRequired(r.w, "constraint enforcement", c.Enforced); v != nil && !*v {
		if !domain && (*kind == "c" || *kind == "f") {
			r.write(" NOT ENFORCED")
		} else {
			r.w.Note("Unsupported constraint enforcement.")
		}
	}
	if v := pgDefinitionRequired(r.w, "constraint locality", c.Local); v != nil && !*v {
		r.w.Note("Inherited constraint definition requires metadata review.")
	}
	if v := pgDefinitionRequired(r.w, "constraint inheritance", c.Inherited); v != nil && *v {
		r.w.Note("Inherited constraint definition requires metadata review.")
	}
}
func (r pgDefinition) indexState(x sc.Index) {
	for _, state := range []struct {
		name string
		fact sc.Fact[bool]
	}{{"index validity", x.Valid}, {"index readiness", x.Ready}} {
		if value := pgDefinitionRequired(r.w, state.name, state.fact); value != nil && !*value {
			r.w.Note("Unavailable " + state.name + "; index is not ready for use.")
		}
	}
}
func (r pgDefinition) index(x sc.Index, table sc.Ref) {
	if sc.DefinitionFact(r.w, "index constraint", x.Constraint) != nil {
		return
	}
	r.write("CREATE ")
	if unique := pgDefinitionRequired(r.w, "index uniqueness", x.Unique); unique != nil && *unique {
		r.write("UNIQUE ")
	}
	r.write("INDEX ", r.name(x.Ref.Name), " ON ", r.ref(table))
	if method := pgDefinitionRequired(r.w, "index method", x.Method); method != nil {
		r.write(" USING ", r.name(*method))
	} else {
		r.write(" USING /* method unavailable */")
	}
	r.write(" (")
	keys := sc.DefinitionItems(r.w, "index keys", x.Keys)
	if len(keys) == 0 {
		r.w.Note("Unavailable index keys.")
		r.write("/* keys unavailable */")
	}
	for i, k := range keys {
		if r.w.Full() {
			break
		}
		if i > 0 {
			r.write(", ")
		}
		column := sc.DefinitionFact(r.w, "index column", k.Column)
		expression := sc.DefinitionFact(r.w, "index expression", k.Expression)
		if column != nil {
			r.write(r.name(column.Name))
		} else if expression != nil {
			// pg_get_indexdef(index, column, false) captured a complete key,
			// including its suffixes. Do not duplicate or parse arbitrary SQL.
			if expression.Dependencies.Code == "expressionIndexKey" {
				r.expr("index key", expression)
				continue
			}
			r.write("(")
			r.expr("index key", expression)
			r.write(")")
		} else {
			r.w.Note("Unavailable index key.")
			r.write("/* key unavailable */")
		}
		if collation := sc.DefinitionFact(r.w, "index collation", k.Collation); collation != nil {
			r.write(" COLLATE ", r.ref(*collation))
		}
		if opclass := sc.DefinitionFact(r.w, "index operator class", k.Opclass); opclass != nil {
			r.write(" ", r.ref(*opclass))
			r.options(k.Options, " (")
		} else if len(sc.DefinitionItems(r.w, "index key options", k.Options)) > 0 {
			r.w.Note("Index key options require an available operator class.")
		}
		if desc := pgDefinitionRequired(r.w, "index order", k.Descending); desc != nil {
			if *desc {
				r.write(" DESC")
			} else {
				r.write(" ASC")
			}
		}
		if first := pgDefinitionRequired(r.w, "index null order", k.NullsFirst); first != nil {
			if *first {
				r.write(" NULLS FIRST")
			} else {
				r.write(" NULLS LAST")
			}
		}
	}
	r.write(")")
	if len(sc.DefinitionItems(r.w, "index included columns", x.Includes)) > 0 {
		r.write(" INCLUDE (")
		r.columns(x.Includes, "included columns")
		r.write(")")
	}
	if v := pgDefinitionRequired(r.w, "index null semantics", x.NullsDistinct); v != nil && !*v {
		r.write(" NULLS NOT DISTINCT")
	}
	r.options(x.Options, " WITH (")
	if predicate := sc.DefinitionFact(r.w, "index predicate", x.Predicate); predicate != nil {
		r.write(" WHERE ")
		r.expr("index predicate", predicate)
	}
	r.write(";\n")
	r.indexState(x)
}
func (r pgDefinition) options(c sc.Collection[sc.Option], prefix string) {
	items := sc.DefinitionItems(r.w, "storage options", c)
	if len(items) == 0 || r.w.Full() {
		return
	}
	// Sort indexes, not escaped scalar values. Output streams and stops at its
	// budget instead of materializing all options or table entries first.
	if len(items) > 4096 {
		r.w.Note("Storage option count exceeds the SQL preview limit.")
		items = items[:4096]
	}
	order := make([]int, len(items))
	for i := range order {
		order[i] = i
	}
	sort.SliceStable(order, func(i, j int) bool {
		a, b := items[order[i]].Name, items[order[j]].Name
		if len(a) > 256 {
			a = a[:256]
		}
		if len(b) > 256 {
			b = b[:256]
		}
		return a < b
	})
	r.write(prefix)
	for i, n := range order {
		if r.w.Full() {
			break
		}
		if i > 0 {
			r.write(", ")
		}
		v := items[n]
		parts := strings.Split(r.scalar(v.Name), ".")
		for j, part := range parts {
			if j > 0 {
				r.write(".")
			}
			r.write(r.name(part))
		}
		r.write(" = ", r.literal(v.Value))
	}
	r.write(")")
}
func (r pgDefinition) table(t sc.Table) {
	kind := pgDefinitionRequired(r.w, "table kind", t.Kind)
	if kind != nil && *kind != "r" {
		r.w.Note("Unsupported table kind.")
	}
	r.write("CREATE ")
	temporary := false
	if storage := pgDefinitionRequired(r.w, "table persistence", t.Storage); storage != nil {
		switch *storage {
		case "u":
			r.write("UNLOGGED ")
		case "t":
			r.write("TEMPORARY ")
			temporary = true
		case "p":
		default:
			r.w.Note("Unsupported table persistence.")
		}
	}
	name := r.ref(t.Ref)
	if temporary {
		name = r.name(t.Ref.Name)
	}
	r.write("TABLE ", name, " (\n")
	namedNulls := map[sc.Ref]bool{}
	for _, c := range t.Constraints.Items {
		if c.Kind.Value != nil && *c.Kind.Value == "n" {
			for _, col := range c.Columns.Items {
				namedNulls[col] = true
			}
		}
	}
	count := 0
	for _, c := range sc.DefinitionItems(r.w, "table columns", t.Columns) {
		if namedNulls[c.Ref] {
			c.Nullable = sc.Known(true)
		}
		if r.w.Full() {
			break
		}
		if count > 0 {
			r.write(",\n")
		}
		r.write("    ")
		r.column(c, false)
		count++
	}
	if r.w.Full() {
		return
	}
	backings := make(map[sc.Ref]*sc.Index)
	for i := range t.Indexes.Items {
		x := &t.Indexes.Items[i]
		if x.Constraint.State == "known" && x.Constraint.Value != nil {
			backings[*x.Constraint.Value] = x
		}
	}
	constraints := sc.DefinitionItems(r.w, "table constraints", t.Constraints)
	for _, c := range constraints {
		if r.w.Full() {
			break
		}
		if valid := pgDefinitionRequired(r.w, "constraint validation", c.Validated); valid != nil && !*valid {
			continue
		}
		if count > 0 {
			r.write(",\n")
		}
		r.write("    ")
		r.constraint(c, backings[c.Ref], false)
		count++
	}
	r.write("\n)")
	r.options(t.Options, " WITH (")
	r.write(";\n")
	for _, c := range constraints {
		if r.w.Full() {
			break
		}
		if c.Validated.State != "known" || c.Validated.Value == nil || *c.Validated.Value {
			continue
		}
		if c.Kind.Value == nil || (*c.Kind.Value != "c" && *c.Kind.Value != "f" && *c.Kind.Value != "n") {
			r.w.Note("Unsupported unvalidated constraint.")
			continue
		}
		r.write("ALTER TABLE ", name, " ADD ")
		r.constraint(c, backings[c.Ref], false)
		r.write(" NOT VALID;\n")
	}
	for _, x := range sc.DefinitionItems(r.w, "table indexes", t.Indexes) {
		if r.w.Full() {
			break
		}
		r.index(x, t.Ref)
	}
	for _, c := range t.Columns.Items {
		if r.w.Full() {
			break
		}
		if comment := sc.DefinitionFact(r.w, "column comment", c.Comment); comment != nil && *comment != "" {
			r.write("COMMENT ON COLUMN ", name, ".", r.name(c.Ref.Name), " IS ", r.literal(*comment), ";\n")
		}
	}
}
func (r pgDefinition) typeDefinition(t sc.TypeDefinition) {
	kind := pgDefinitionRequired(r.w, "type kind", t.Kind)
	if kind == nil {
		r.write("-- Type definition unavailable.\n")
		return
	}
	if t.Extension != nil {
		r.write("-- Extension ", r.name(t.Extension.Name), " version ", r.literal(t.Extension.Version), " owns this type.\n")
		r.w.Note("Extension-managed types must be recreated through their extension.")
	}
	switch *kind {
	case "e":
		r.write("CREATE TYPE ", r.ref(t.Ref), " AS ENUM (")
		for i, v := range sc.DefinitionItems(r.w, "enum labels", t.Labels) {
			if r.w.Full() {
				break
			}
			if i > 0 {
				r.write(", ")
			}
			r.write(r.literal(v))
		}
		r.write(");\n")
	case "d":
		r.write("CREATE DOMAIN ", r.ref(t.Ref), " AS ")
		if base := pgDefinitionRequired(r.w, "domain base type", t.Base); base != nil {
			r.typ(*base)
		} else {
			r.w.Note("Unavailable domain base type.")
			r.write("/* base type unavailable */")
		}
		if t.Collation != nil {
			r.write(" COLLATE ", r.ref(*t.Collation))
		}
		if d := pgDefinitionRequired(r.w, "domain default", t.Default); d != nil {
			r.defaultSQL(*d)
		}
		if nullable := pgDefinitionRequired(r.w, "domain nullability", t.Nullable); nullable != nil && !*nullable {
			r.write(" NOT NULL")
		}
		checks := sc.DefinitionItems(r.w, "domain checks", t.Checks)
		for _, c := range checks {
			if r.w.Full() {
				break
			}
			if v := sc.DefinitionFact(r.w, "domain check validation", c.Validated); v != nil && !*v {
				continue
			}
			r.write("\n    ")
			r.constraint(c, nil, true)
		}
		r.write(";\n")
		for _, c := range checks {
			if r.w.Full() {
				break
			}
			if c.Validated.State == "known" && c.Validated.Value != nil && !*c.Validated.Value {
				r.write("ALTER DOMAIN ", r.ref(t.Ref), " ADD ")
				r.constraint(c, nil, true)
				r.write(" NOT VALID;\n")
			}
		}
	case "c":
		r.write("CREATE TYPE ", r.ref(t.Ref), " AS (\n")
		for i, c := range sc.DefinitionItems(r.w, "composite attributes", t.Attributes) {
			if r.w.Full() {
				break
			}
			if i > 0 {
				r.write(",\n")
			}
			r.write("    ")
			r.column(c, true)
		}
		r.write("\n);\n")
	case "r":
		r.rangeDefinition(t)
	case "m":
		if t.Base.Value == nil {
			r.w.Note("Unavailable multirange owner type.")
			return
		}
		if owner, ok := r.types[t.Base.Value.Ref]; ok && owner.Range != nil {
			r.write("-- Multirange is created with its owning range type.\n")
			r.rangeDefinition(owner)
		} else {
			r.w.Note("Unavailable multirange owner definition.")
		}
	case "b":
		r.baseDefinition(t)
	default:
		r.w.Note("Unsupported type kind.")
	}
	if t.Comment != nil && *t.Comment != "" {
		keyword := "TYPE"
		if *kind == "d" {
			keyword = "DOMAIN"
		}
		r.write("COMMENT ON ", keyword, " ", r.ref(t.Ref), " IS ", r.literal(*t.Comment), ";\n")
	}
}
func (r pgDefinition) rangeDefinition(t sc.TypeDefinition) {
	if t.Range == nil {
		r.w.Note("Unavailable range metadata.")
		return
	}
	v := t.Range
	r.write("CREATE TYPE ", r.ref(t.Ref), " AS RANGE (\n    SUBTYPE = ")
	r.typ(v.Subtype)
	r.write(",\n    SUBTYPE_OPCLASS = ", r.ref(v.OperatorClass))
	if v.Collation != nil {
		r.write(",\n    COLLATION = ", r.ref(*v.Collation))
	}
	if v.Canonical != nil {
		r.write(",\n    CANONICAL = ", r.ref(v.Canonical.Ref))
	}
	if v.Difference != nil {
		r.write(",\n    SUBTYPE_DIFF = ", r.ref(v.Difference.Ref))
	}
	r.write(",\n    MULTIRANGE_TYPE_NAME = ", r.ref(v.Multirange), "\n);\n")
}
func (r pgDefinition) baseDefinition(t sc.TypeDefinition) {
	if t.BaseType == nil {
		r.w.Note("Unavailable base type metadata.")
		return
	}
	b := t.BaseType
	r.write("CREATE TYPE ", r.ref(t.Ref), ";\nCREATE TYPE ", r.ref(t.Ref), " (\n")
	parts := 0
	option := func(name, value string) {
		if parts > 0 {
			r.write(",\n")
		}
		r.write("    ", name)
		if value != "" {
			r.write(" = ", value)
		}
		parts++
	}
	for _, f := range b.Functions {
		switch f.Role {
		case "input", "output", "receive", "send", "typmod_in", "typmod_out", "analyze", "subscript":
			option(strings.ToUpper(f.Role), r.ref(f.Ref))
		}
	}
	for _, o := range sc.DefinitionItems(r.w, "base type options", b.Options) {
		switch o.Name {
		case "internalLength":
			value := o.Value
			if value == "-1" {
				value = "VARIABLE"
			}
			option("INTERNALLENGTH", value)
		case "passedByValue":
			if o.Value == "true" {
				option("PASSEDBYVALUE", "")
			}
		case "alignment":
			if v, ok := map[string]string{"c": "char", "s": "int2", "i": "int4", "d": "double"}[o.Value]; ok {
				option("ALIGNMENT", v)
			} else {
				r.w.Note("Unavailable base type alignment.")
			}
		case "storage":
			if v, ok := map[string]string{"p": "plain", "e": "external", "x": "extended", "m": "main"}[o.Value]; ok {
				option("STORAGE", v)
			} else {
				r.w.Note("Unavailable base type storage.")
			}
		case "category":
			option("CATEGORY", r.literal(o.Value))
		case "preferred":
			option("PREFERRED", strings.ToUpper(o.Value))
		case "collatable":
			option("COLLATABLE", strings.ToUpper(o.Value))
		case "delimiter":
			option("DELIMITER", r.literal(o.Value))
		case "default":
			if o.Value != "" {
				option("DEFAULT", r.literal(o.Value))
			}
		}
	}
	if b.Element != nil {
		if parts > 0 {
			r.write(",\n")
		}
		r.write("    ELEMENT = ")
		r.typ(*b.Element)
	}
	r.write("\n);\n")
}
func (r pgDefinition) sequence(s sc.Sequence) {
	r.write("CREATE SEQUENCE ", r.ref(s.Ref))
	if typ := pgDefinitionRequired(r.w, "sequence type", s.Type); typ != nil {
		r.write(" AS ")
		r.typ(*typ)
	}
	for _, option := range []struct {
		name  string
		value sc.Fact[string]
	}{{"START WITH", s.Start}, {"INCREMENT BY", s.Increment}, {"MINVALUE", s.Min}, {"MAXVALUE", s.Max}, {"CACHE", s.Cache}} {
		if value := pgDefinitionRequired(r.w, "sequence "+option.name, option.value); value != nil {
			if _, e := strconv.ParseInt(*value, 10, 64); e == nil {
				r.write("\n    ", option.name, " ", *value)
			} else {
				r.w.Note("Unavailable sequence " + option.name + ".")
			}
		}
	}
	if cycle := pgDefinitionRequired(r.w, "sequence cycle", s.Cycle); cycle != nil {
		if *cycle {
			r.write("\n    CYCLE")
		} else {
			r.write("\n    NO CYCLE")
		}
	}
	if owner := sc.DefinitionFact(r.w, "sequence owner", s.Owner); owner != nil {
		r.write("\n    OWNED BY ", r.ref(sc.Ref{Schema: owner.Schema, Name: owner.Table}), ".", r.name(owner.Name))
	} else if s.Owner.State == "known" {
		r.write("\n    OWNED BY NONE")
	}
	r.write(";\n")
}
