package mysql

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"regexp"
	"strconv"
	"strings"

	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/textdiff"
)

// RenderSchemaDefinition renders only frozen catalog facts. Its SQL is a
// comparison preview, never a migration or a reason to query the server.
func RenderSchemaDefinition(ctx context.Context, capture sc.Capture, ref sc.Ref) (sc.Definition, error) {
	r := myDefinition{w: &sc.DefinitionWriter{Context: ctx}, engine: capture.Context.EngineContext}
	switch ref.Kind {
	case "table":
		for _, table := range capture.Tables {
			if r.w.Full() {
				break
			}
			if table.Ref == ref {
				r.table(table)
				return r.w.Finish()
			}
		}
	case "schema":
		r.w.Write("CREATE DATABASE ")
		r.identifier(ref.Name)
		r.w.Write(";\n")
		r.w.Note("Database options are not captured; see metadata details.")
	case "capture":
		r.w.Note("Capture context is available in metadata details.")
	default:
		r.w.Note("Unsupported MySQL object kind " + ref.Kind + ".")
	}
	if r.w.Text.Len() == 0 && !r.w.Limited {
		r.w.Note("SQL definition unavailable for the selected object.")
	}
	return r.w.Finish()
}

type myDefinition struct {
	w                                   *sc.DefinitionWriter
	engine                              sc.Fact[[]sc.Option]
	modeChecked, modeKnown, noBackslash bool
}

func myRequiredDefinitionFact[T any](r *myDefinition, label string, fact sc.Fact[T]) *T {
	value := sc.DefinitionFact(r.w, label, fact)
	if value == nil && fact.State == "known" {
		r.w.Note("Unavailable " + label + ".")
	}
	return value
}

func (r *myDefinition) identifier(name string) {
	if name == "" {
		r.w.Note("Unavailable identifier.")
		r.w.Write("/* identifier unavailable */")
		return
	}
	if len(name) > textdiff.MaxTextBytes {
		r.w.Note("Identifier exceeds the definition limit.")
		r.w.Write("/* identifier unavailable */")
		return
	}
	r.w.Write(QuoteIdentifier(name))
}
func (r *myDefinition) ref(ref sc.Ref) {
	if ref.Schema != "" {
		r.identifier(ref.Schema)
		r.w.Write(".")
	}
	r.identifier(ref.Name)
}
func (r *myDefinition) mode() bool {
	if !r.modeChecked {
		r.modeChecked = true
		if options := sc.DefinitionFact(r.w, "sql_mode", r.engine); options != nil {
			for i, option := range *options {
				if i >= 1024 {
					r.w.Note("Engine option limit reached.")
					break
				}
				if strings.EqualFold(option.Name, "sqlMode") || strings.EqualFold(option.Name, "SQL_MODE") {
					r.modeKnown = true
					for _, mode := range strings.Split(option.Value, ",") {
						if strings.EqualFold(strings.TrimSpace(mode), "NO_BACKSLASH_ESCAPES") {
							r.noBackslash = true
						}
					}
					break
				}
			}
		}
	}
	if !r.modeKnown {
		r.w.Note("Unavailable sql_mode; string literal escaping is unknown.")
	}
	return r.modeKnown
}
func (r *myDefinition) literal(value string) {
	if !r.mode() {
		r.w.Write("/* literal unavailable */")
		return
	}
	r.w.Write("'")
	// Escape bounded chunks rather than allocating a second full captured scalar.
	for len(value) > 0 && !r.w.Full() {
		n := min(len(value), 1024)
		part := value[:n]
		if r.noBackslash {
			part = strings.ReplaceAll(part, "'", "''")
		} else {
			part = strings.NewReplacer("\\", "\\\\", "'", "''", "\x00", "\\0", "\n", "\\n", "\r", "\\r", "\x1a", "\\Z").Replace(part)
		}
		r.w.Write(part)
		value = value[n:]
	}
	r.w.Write("'")
}
func (r *myDefinition) expression(label string, expression *sc.Expression) {
	if expression == nil || expression.Text == "" {
		r.w.Note("Unavailable " + label + " expression.")
		r.w.Write("/* expression unavailable */")
		return
	}
	sc.DefinitionItems(r.w, label+" dependencies", expression.Dependencies)
	r.w.Write(expression.Text)
}
func (r *myDefinition) typ(u sc.TypeUse) {
	name := strings.ToLower(u.Ref.Name)
	known := false
	for _, candidate := range []string{"tinyint", "smallint", "mediumint", "int", "integer", "bigint", "decimal", "numeric", "float", "double", "real", "bit", "bool", "boolean", "char", "varchar", "binary", "varbinary", "tinytext", "text", "mediumtext", "longtext", "tinyblob", "blob", "mediumblob", "longblob", "date", "datetime", "timestamp", "time", "year", "json", "enum", "set", "geometry", "point", "linestring", "polygon", "multipoint", "multilinestring", "multipolygon", "geometrycollection"} {
		if name == candidate {
			known = true
			break
		}
	}
	if !known || u.Ref.Schema != "" {
		r.w.Note("Unsupported MySQL type " + u.Ref.Name + ".")
		r.w.Write("/* type unavailable */")
		return
	}
	r.w.Write(strings.ToUpper(name))
	if name == "enum" || name == "set" {
		labels := sc.DefinitionItems(r.w, name+" labels", u.Labels)
		if len(labels) == 0 {
			r.w.Note("Unavailable " + name + " labels.")
			r.w.Write("(/* labels unavailable */)")
		} else {
			r.w.Write("(")
			for i, label := range labels {
				if r.w.Full() {
					break
				}
				if i > 0 {
					r.w.Write(", ")
				}
				r.literal(label)
			}
			r.w.Write(")")
		}
	}
	m := myRequiredDefinitionFact(r, "type modifiers", u.Modifiers)
	if m == nil {
		r.w.Write(" /* modifiers unavailable */")
		return
	}
	parameter := func(value *int64) {
		if value != nil {
			r.w.Write("(" + strconv.FormatInt(*value, 10) + ")")
		}
	}
	switch name {
	case "char", "varchar", "binary", "varbinary", "bit":
		if m.Length == nil && (name == "varchar" || name == "varbinary") {
			r.w.Note("Unavailable " + name + " length.")
			r.w.Write("(/* length unavailable */)")
		} else {
			parameter(m.Length)
		}
	case "decimal", "numeric":
		if m.Precision != nil {
			r.w.Write("(" + strconv.FormatInt(*m.Precision, 10))
			if m.Scale != nil {
				r.w.Write(", " + strconv.FormatInt(*m.Scale, 10))
			}
			r.w.Write(")")
		} else if m.Scale != nil {
			r.w.Note("Unavailable numeric precision.")
			r.w.Write(" /* precision unavailable */")
		}
	case "datetime", "timestamp", "time":
		parameter(m.DatetimePrecision)
	case "tinyint", "smallint", "mediumint", "int", "integer", "bigint":
		if m.Zerofill {
			parameter(m.Length)
		}
	}
	if m.Unsigned {
		r.w.Write(" UNSIGNED")
	}
	if m.Zerofill {
		r.w.Write(" ZEROFILL")
	}
	if m.ArrayDimensions != 0 || m.Interval != nil || u.Element != nil {
		r.w.Note("Unsupported MySQL type modifiers.")
	}
}

var myDefinitionNumber = regexp.MustCompile(`^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$`)

func (r *myDefinition) defaultValue(d sc.Default) {
	switch d.Kind {
	case "none":
		return
	case "sqlNull":
		r.w.Write(" DEFAULT NULL")
	case "expression":
		r.w.Write(" DEFAULT (")
		r.expression("default", d.Expression)
		r.w.Write(")")
	case "literal":
		if d.Value == nil {
			r.w.Note("Unavailable default literal.")
			r.w.Write(" /* default unavailable */")
			return
		}
		if d.Encoding == "base64" {
			if len(*d.Value) > textdiff.MaxTextBytes {
				r.w.Note("Binary default exceeds the definition limit.")
				r.w.Write(" /* default unavailable */")
				return
			}
			value, err := base64.StdEncoding.DecodeString(*d.Value)
			if err != nil {
				r.w.Note("Invalid captured binary default.")
				r.w.Write(" /* default unavailable */")
				return
			}
			r.w.Write(" DEFAULT X'" + hex.EncodeToString(value) + "'")
			return
		}
		if d.Encoding != "text" {
			r.w.Note("Unsupported default encoding " + d.Encoding + ".")
			r.w.Write(" /* default unavailable */")
			return
		}
		if d.Type == nil {
			r.w.Note("Unavailable default literal type.")
			r.w.Write(" /* default unavailable */")
			return
		}
		switch strings.ToLower(d.Type.Ref.Name) {
		case "tinyint", "smallint", "mediumint", "int", "integer", "bigint", "decimal", "numeric", "float", "double", "real", "bit", "bool", "boolean":
			if !myDefinitionNumber.MatchString(*d.Value) {
				r.w.Note("Invalid captured numeric default.")
				r.w.Write(" /* default unavailable */")
				return
			}
			r.w.Write(" DEFAULT " + *d.Value)
		default:
			r.w.Write(" DEFAULT ")
			r.literal(*d.Value)
		}
	default:
		r.w.Note("Unsupported default kind " + d.Kind + ".")
		r.w.Write(" /* default unavailable */")
	}
}
func (r *myDefinition) column(c sc.Column) {
	r.identifier(c.Ref.Name)
	r.w.Write(" ")
	if typ := myRequiredDefinitionFact(r, "column type", c.Type); typ != nil {
		r.typ(*typ)
	} else {
		r.w.Write("/* type unavailable */")
	}
	if charset := sc.DefinitionFact(r.w, "column charset", c.Charset); charset != nil && *charset != "" {
		r.w.Write(" CHARACTER SET ")
		r.identifier(*charset)
	}
	if collation := sc.DefinitionFact(r.w, "column collation", c.Collation); collation != nil && collation.Name != "" {
		r.w.Write(" COLLATE ")
		r.identifier(collation.Name)
	}
	generated := myRequiredDefinitionFact(r, "generated column", c.Generated)
	if generated != nil && generated.Kind != "none" {
		switch generated.Kind {
		case "stored", "virtual":
			r.w.Write(" GENERATED ALWAYS AS (")
			r.expression("generated column", generated.Expression)
			r.w.Write(") " + strings.ToUpper(generated.Kind))
		default:
			r.w.Note("Unsupported generated column kind.")
			r.w.Write(" /* generation unavailable */")
		}
	}
	if nullable := myRequiredDefinitionFact(r, "column nullability", c.Nullable); nullable != nil {
		if *nullable {
			r.w.Write(" NULL")
		} else {
			r.w.Write(" NOT NULL")
		}
	}
	if d := myRequiredDefinitionFact(r, "column default", c.Default); d != nil {
		r.defaultValue(*d)
	} else {
		r.w.Write(" /* default unavailable */")
	}
	if identity := myRequiredDefinitionFact(r, "column identity", c.Identity); identity != nil {
		switch identity.Kind {
		case "none":
		case "autoIncrement":
			r.w.Write(" AUTO_INCREMENT")
		default:
			r.w.Note("Unsupported MySQL identity kind.")
		}
	}
	if update := sc.DefinitionFact(r.w, "column on-update", c.OnUpdate); update != nil {
		r.w.Write(" ON UPDATE ")
		r.expression("on-update", update)
	}
	if visible := myRequiredDefinitionFact(r, "column visibility", c.Visible); visible != nil && !*visible {
		r.w.Write(" INVISIBLE")
	}
	if comment := sc.DefinitionFact(r.w, "column comment", c.Comment); comment != nil && *comment != "" {
		r.w.Write(" COMMENT ")
		r.literal(*comment)
	}
	myRequiredDefinitionFact(r, "column ordinal", c.Ordinal)
}
func (r *myDefinition) columns(c sc.Collection[sc.Ref], label string) {
	columns := sc.DefinitionItems(r.w, label, c)
	if len(columns) == 0 {
		r.w.Note("Unavailable " + label + ".")
		r.w.Write("/* columns unavailable */")
	}
	for i, column := range columns {
		if r.w.Full() {
			break
		}
		if i > 0 {
			r.w.Write(", ")
		}
		r.identifier(column.Name)
	}
}
func (r *myDefinition) indexKeys(x sc.Index) {
	r.w.Write("(")
	keys := sc.DefinitionItems(r.w, "index keys", x.Keys)
	if len(keys) == 0 {
		r.w.Note("Unavailable index keys.")
		r.w.Write("/* keys unavailable */")
	}
	for i, key := range keys {
		if r.w.Full() {
			break
		}
		if i > 0 {
			r.w.Write(", ")
		}
		column := sc.DefinitionFact(r.w, "index column", key.Column)
		expression := sc.DefinitionFact(r.w, "index expression", key.Expression)
		if column != nil {
			r.identifier(column.Name)
		} else if expression != nil {
			r.w.Write("(")
			r.expression("index", expression)
			r.w.Write(")")
		} else {
			r.w.Note("Unavailable index key.")
			r.w.Write("/* key unavailable */")
		}
		if prefix := sc.DefinitionFact(r.w, "index prefix length", key.PrefixLength); prefix != nil {
			r.w.Write("(" + strconv.FormatInt(*prefix, 10) + ")")
		}
		if desc := myRequiredDefinitionFact(r, "index order", key.Descending); desc != nil {
			if *desc {
				r.w.Write(" DESC")
			} else {
				r.w.Write(" ASC")
			}
		}
		if v := sc.DefinitionFact(r.w, "index operator class", key.Opclass); v != nil {
			r.w.Note("Unsupported MySQL index operator class.")
		}
		if v := sc.DefinitionFact(r.w, "index collation", key.Collation); v != nil {
			r.w.Note("Unsupported MySQL index collation.")
		}
		if len(sc.DefinitionItems(r.w, "index key options", key.Options)) > 0 {
			r.w.Note("Unsupported MySQL index key options.")
		}
	}
	r.w.Write(")")
}
func (r *myDefinition) indexOptions(x sc.Index) {
	if method := myRequiredDefinitionFact(r, "index method", x.Method); method != nil {
		switch strings.ToUpper(*method) {
		case "BTREE", "HASH":
			r.w.Write(" USING " + strings.ToUpper(*method))
		case "FULLTEXT", "SPATIAL":
		default:
			r.w.Note("Unsupported index method " + *method + ".")
		}
	}
	if visible := myRequiredDefinitionFact(r, "index visibility", x.Visible); visible != nil && !*visible {
		r.w.Write(" INVISIBLE")
	}
	for _, option := range sc.DefinitionItems(r.w, "index options", x.Options) {
		if r.w.Full() {
			break
		}
		if option.Name == "comment" {
			r.w.Write(" COMMENT ")
			r.literal(option.Value)
		} else {
			r.w.Note("Unsupported index option " + option.Name + ".")
		}
	}
	if v := sc.DefinitionFact(r.w, "index null semantics", x.NullsDistinct); v != nil && !*v {
		r.w.Note("Unsupported MySQL NULLS NOT DISTINCT index.")
	}
	if len(sc.DefinitionItems(r.w, "index included columns", x.Includes)) > 0 {
		r.w.Note("Unsupported MySQL included index columns.")
	}
	if v := sc.DefinitionFact(r.w, "index predicate", x.Predicate); v != nil {
		r.w.Note("Unsupported MySQL index predicate.")
	}
	for _, state := range []struct {
		label string
		fact  sc.Fact[bool]
	}{{"index validity", x.Valid}, {"index readiness", x.Ready}} {
		if value := sc.DefinitionFact(r.w, state.label, state.fact); value != nil && !*value {
			r.w.Note("Unavailable " + state.label + ".")
		}
	}
}
func (r *myDefinition) constraint(c sc.Constraint, backing *sc.Index) {
	kind := myRequiredDefinitionFact(r, "constraint kind", c.Kind)
	if kind == nil {
		r.w.Write("/* constraint unavailable */")
		return
	}
	r.w.Write("CONSTRAINT ")
	r.identifier(c.Ref.Name)
	r.w.Write(" ")
	switch *kind {
	case "p", "u":
		if *kind == "p" {
			r.w.Write("PRIMARY KEY ")
		} else {
			r.w.Write("UNIQUE ")
		}
		if backing != nil {
			sc.DefinitionItems(r.w, "constraint columns", c.Columns)
			r.indexKeys(*backing)
			r.indexOptions(*backing)
		} else {
			r.w.Write("(")
			r.columns(c.Columns, "constraint columns")
			r.w.Write(")")
		}
	case "c":
		r.w.Write("CHECK (")
		r.expression("check", sc.DefinitionFact(r.w, "check constraint", c.Check))
		r.w.Write(")")
		if enforced := sc.DefinitionFact(r.w, "check enforcement", c.Enforced); enforced != nil && !*enforced {
			r.w.Write(" NOT ENFORCED")
		}
	case "f":
		r.w.Write("FOREIGN KEY (")
		r.columns(c.Columns, "foreign-key columns")
		r.w.Write(") REFERENCES ")
		if target := myRequiredDefinitionFact(r, "foreign-key target", c.Target); target != nil {
			r.ref(*target)
		} else {
			r.w.Write("/* target unavailable */")
		}
		r.w.Write(" (")
		pairs := sc.DefinitionItems(r.w, "foreign-key mapping", c.ForeignKeys)
		if len(pairs) == 0 {
			r.w.Note("Unavailable referenced columns.")
			r.w.Write("/* columns unavailable */")
		}
		for i, pair := range pairs {
			if r.w.Full() {
				break
			}
			if i > 0 {
				r.w.Write(", ")
			}
			r.identifier(pair.Target.Name)
		}
		r.w.Write(")")
		for _, action := range []struct {
			name string
			fact sc.Fact[string]
		}{{"UPDATE", c.Update}, {"DELETE", c.Delete}} {
			if value := sc.DefinitionFact(r.w, "foreign-key "+action.name, action.fact); value != nil {
				switch strings.ToUpper(*value) {
				case "RESTRICT", "CASCADE", "SET NULL", "NO ACTION", "SET DEFAULT":
					r.w.Write(" ON " + action.name + " " + strings.ToUpper(*value))
				default:
					r.w.Note("Unsupported foreign-key action " + *value + ".")
				}
			}
		}
		if match := sc.DefinitionFact(r.w, "foreign-key match", c.Match); match != nil && *match != "NONE" && *match != "" {
			r.w.Note("Unsupported MySQL foreign-key MATCH " + *match + ".")
		}
	default:
		r.w.Note("Unsupported constraint kind " + *kind + ".")
		r.w.Write("/* definition unavailable */")
	}
	for _, flag := range []struct {
		label       string
		fact        sc.Fact[bool]
		unsupported bool
	}{{"constraint deferrability", c.Deferrable, true}, {"constraint initial deferral", c.InitiallyDeferred, true}, {"constraint inheritance", c.Inherited, true}, {"constraint no-inherit", c.NoInherit, true}, {"constraint locality", c.Local, false}, {"constraint validation", c.Validated, false}} {
		if value := sc.DefinitionFact(r.w, flag.label, flag.fact); value != nil && *value == flag.unsupported {
			r.w.Note("Unsupported MySQL " + flag.label + ".")
		}
	}
}
func (r *myDefinition) index(x sc.Index) {
	if method := sc.DefinitionFact(r.w, "index method", x.Method); method != nil && (strings.EqualFold(*method, "FULLTEXT") || strings.EqualFold(*method, "SPATIAL")) {
		r.w.Write(strings.ToUpper(*method) + " ")
	} else if unique := myRequiredDefinitionFact(r, "index uniqueness", x.Unique); unique != nil && *unique {
		r.w.Write("UNIQUE ")
	}
	r.w.Write("KEY ")
	r.identifier(x.Ref.Name)
	r.w.Write(" ")
	r.indexKeys(x)
	r.indexOptions(x)
}
func (r *myDefinition) table(t sc.Table) {
	if kind := myRequiredDefinitionFact(r, "table kind", t.Kind); kind != nil && *kind != "table" {
		r.w.Note("Unsupported MySQL table kind " + *kind + ".")
	}
	r.w.Write("CREATE TABLE ")
	r.ref(t.Ref)
	r.w.Write(" (\n")
	entry := false
	start := func() {
		if entry {
			r.w.Write(",\n")
		}
		r.w.Write("    ")
		entry = true
	}
	for _, column := range sc.DefinitionItems(r.w, "table columns", t.Columns) {
		if r.w.Full() {
			break
		}
		start()
		r.column(column)
	}
	// A fixed-size lookup preserves backing-index details without building an
	// unbounded intermediate representation before the output budget is checked.
	backing := make(map[sc.Ref]*sc.Index)
	for i := range t.Indexes.Items {
		if r.w.Full() || i >= 1024 {
			break
		}
		x := &t.Indexes.Items[i]
		backing[x.Ref] = x
	}
	used := make(map[sc.Ref]bool)
	for _, constraint := range sc.DefinitionItems(r.w, "table constraints", t.Constraints) {
		if r.w.Full() {
			break
		}
		var index *sc.Index
		if ref := sc.DefinitionFact(r.w, "constraint backing index", constraint.BackingIndex); ref != nil {
			index = backing[*ref]
			if index != nil {
				used[*ref] = true
			}
		}
		start()
		r.constraint(constraint, index)
	}
	for _, index := range sc.DefinitionItems(r.w, "table indexes", t.Indexes) {
		if r.w.Full() {
			break
		}
		if used[index.Ref] {
			continue
		}
		start()
		r.index(index)
	}
	r.w.Write("\n)")
	if storage := sc.DefinitionFact(r.w, "table engine", t.Storage); storage != nil && *storage != "" {
		r.w.Write(" ENGINE = ")
		r.identifier(*storage)
	}
	if charset := sc.DefinitionFact(r.w, "table charset", t.Charset); charset != nil && *charset != "" {
		r.w.Write(" DEFAULT CHARACTER SET = ")
		r.identifier(*charset)
	}
	if collation := sc.DefinitionFact(r.w, "table collation", t.Collation); collation != nil && collation.Name != "" {
		r.w.Write(" COLLATE = ")
		r.identifier(collation.Name)
	}
	for _, option := range sc.DefinitionItems(r.w, "table options", t.Options) {
		if r.w.Full() {
			break
		}
		switch strings.ToLower(option.Name) {
		case "comment":
			r.w.Write(" COMMENT = ")
			r.literal(option.Value)
		case "row_format":
			value := strings.ToUpper(option.Value)
			switch value {
			case "DEFAULT", "DYNAMIC", "FIXED", "COMPRESSED", "REDUNDANT", "COMPACT":
				r.w.Write(" ROW_FORMAT = " + value)
			default:
				r.w.Note("Unsupported table row_format.")
			}
		case "createoptions":
			r.w.Note("Table create_options require metadata review: " + option.Value + ".")
		default:
			r.w.Note("Unsupported table option " + option.Name + ".")
		}
	}
	r.w.Write(";\n")
}
