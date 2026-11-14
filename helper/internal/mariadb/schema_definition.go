package mariadb

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/textdiff"
)

// RenderSchemaDefinition renders only frozen catalog facts. Its SQL is a
// comparison preview, never a migration or a reason to query the server.
func RenderSchemaDefinition(ctx context.Context, capture sc.Capture, ref sc.Ref) (sc.Definition, error) {
	r := mariaDefinition{w: &sc.DefinitionWriter{Context: ctx}, engine: capture.Context.EngineContext}
	if capture.Context.Engine != "mariadb" {
		r.w.Note("The definition requires native MariaDB engine facts.")
	}
	for _, issue := range capture.Issues {
		if issue.BlocksEquality && issue.Ref != nil {
			issueRef := *issue.Ref
			if issueRef == ref || (ref.Kind == "table" && issueRef.Schema == ref.Schema && issueRef.Table == ref.Name) {
				r.w.Note("Incomplete native property: " + issue.Code + ".")
			}
		}
	}
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
	case "sequence":
		for _, sequence := range capture.Sequences {
			if sequence.Ref == ref {
				r.sequence(sequence)
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
		r.w.Note("Unsupported MariaDB object kind " + ref.Kind + ".")
	}
	if r.w.Text.Len() == 0 && !r.w.Limited {
		r.w.Note("SQL definition unavailable for the selected object.")
	}
	return r.w.Finish()
}

type mariaDefinition struct {
	authored                            map[*sc.Expression]bool
	w                                   *sc.DefinitionWriter
	engine                              sc.Fact[[]sc.Option]
	modeChecked, modeKnown, noBackslash bool
	nativeColumnOptions                 sc.Collection[sc.Option]
	alterConstraint                     bool
}

func mariaRequiredDefinitionFact[T any](r *mariaDefinition, label string, fact sc.Fact[T]) *T {
	value := sc.DefinitionFact(r.w, label, fact)
	if value == nil && fact.State == "known" {
		r.w.Note("Unavailable " + label + ".")
	}
	return value
}

func (r *mariaDefinition) identifier(name string) {
	if !sc.ValidName(name) {
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
func (r *mariaDefinition) ref(ref sc.Ref) {
	if ref.Schema != "" {
		r.identifier(ref.Schema)
		r.w.Write(".")
	}
	r.identifier(ref.Name)
}
func (r *mariaDefinition) mode() bool {
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
func (r *mariaDefinition) literal(value string) {
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
			if strings.ContainsAny(part, "\x00\x1a") {
				r.w.Note("Control literals under NO_BACKSLASH_ESCAPES require manual SQL.")
				return
			}
			part = strings.ReplaceAll(part, "'", "''")
		} else {
			part = strings.NewReplacer("\\", "\\\\", "'", "''", "\x00", "\\0", "\n", "\\n", "\r", "\\r", "\x1a", "\\Z").Replace(part)
		}
		r.w.Write(part)
		value = value[n:]
	}
	r.w.Write("'")
}
func (r *mariaDefinition) expression(label string, expression *sc.Expression) {
	if expression == nil || expression.Text == "" {
		r.w.Note("Unavailable " + label + " expression.")
		r.w.Write("/* expression unavailable */")
		return
	}
	if !mariaDefinitionExpression(expression.Text, r.engine) {
		r.w.Note("Unrecognized native expression boundary.")
		r.w.Write("/* expression unavailable */")
		return
	}
	if !r.authored[expression] {
		sc.DefinitionItems(r.w, label+" dependencies", expression.Dependencies)
	}
	r.w.Write(expression.Text)
}
func (r *mariaDefinition) typ(u sc.TypeUse) {
	name := strings.ToLower(u.Ref.Name)
	if len(u.Arguments) > 0 || (u.Kind != "builtin" && u.Kind != "enum" && u.Kind != "set") {
		r.w.Note("Unsupported native type identity or arguments.")
	}
	known := false
	for _, candidate := range []string{"tinyint", "smallint", "mediumint", "int", "integer", "bigint", "decimal", "numeric", "float", "double", "real", "bit", "bool", "boolean", "char", "varchar", "binary", "varbinary", "tinytext", "text", "mediumtext", "longtext", "tinyblob", "blob", "mediumblob", "longblob", "date", "datetime", "timestamp", "time", "year", "json", "enum", "set", "geometry", "point", "linestring", "polygon", "multipoint", "multilinestring", "multipolygon", "geometrycollection", "geomcollection", "uuid", "inet4", "inet6"} {
		if name == candidate {
			known = true
			break
		}
	}
	if !known || u.Ref.Schema != "" {
		r.w.Note("Unsupported MariaDB type " + u.Ref.Name + ".")
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
				if u.LabelEncoding == "base64" {
					decoded, err := base64.StdEncoding.DecodeString(label)
					if err != nil {
						r.w.Note("Invalid binary type label.")
						r.w.Write("/* label unavailable */")
					} else {
						r.w.Write("X'" + hex.EncodeToString(decoded) + "'")
					}
				} else if u.LabelEncoding == "" || u.LabelEncoding == "text" {
					r.literal(label)
				} else {
					r.w.Note("Unsupported type label encoding.")
					r.w.Write("/* label unavailable */")
				}
			}
			r.w.Write(")")
		}
	}
	m := mariaRequiredDefinitionFact(r, "type modifiers", u.Modifiers)
	if m == nil {
		r.w.Write(" /* modifiers unavailable */")
		return
	}
	if !mariaDefinitionTypeBounds(name, *m) {
		r.w.Note("Native type modifiers exceed the reviewed MariaDB bounds.")
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
	case "decimal", "numeric", "float", "double", "real":
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
	case "tinyint", "smallint", "mediumint", "int", "integer", "bigint", "year":
		parameter(m.Length)
	}
	if m.Unsigned {
		r.w.Write(" UNSIGNED")
	}
	if m.Zerofill {
		r.w.Write(" ZEROFILL")
	}
	if m.SpatialReferenceID != nil {
		r.w.Note("Native column-level SRID properties are not supported by this MariaDB renderer.")
	}
	if m.ArrayDimensions != 0 || m.Interval != nil || m.SQL != nil || m.Raw != nil || u.Element != nil {
		r.w.Note("Unsupported MariaDB type modifiers.")
	}
}

var mariaDefinitionNumber = regexp.MustCompile(`^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$`)
var mariaDefinitionBits = regexp.MustCompile(`^b'[01]{1,64}'$`)

func (r *mariaDefinition) defaultValue(d sc.Default) {
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
		case "bit":
			if number, e := strconv.ParseUint(*d.Value, 10, 64); e == nil {
				width := int64(64)
				if d.Type.Modifiers.Value != nil && d.Type.Modifiers.Value.Length != nil {
					width = *d.Type.Modifiers.Value.Length
				}
				if width < 1 || width > 64 || (width < 64 && number >= (uint64(1)<<uint(width))) {
					r.w.Note("Invalid native bit default width.")
					return
				}
				r.w.Write(" DEFAULT b'" + strconv.FormatUint(number, 2) + "'")
				return
			}
			if mariaDefinitionBits.MatchString(*d.Value) {
				r.w.Write(" DEFAULT " + *d.Value)
			} else {
				r.w.Note("Invalid captured bit default.")
				r.w.Write(" /* default unavailable */")
			}
		case "tinyint", "smallint", "mediumint", "int", "integer", "bigint", "decimal", "numeric", "float", "double", "real", "bool", "boolean":
			if !mariaDefinitionNumber.MatchString(*d.Value) {
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
func (r *mariaDefinition) column(c sc.Column) {
	r.identifier(c.Ref.Name)
	if c.CollationProperties != nil {
		if len(c.CollationProperties.Items) > 0 || !c.CollationProperties.Complete {
			r.w.Note("Unmodeled native column collation properties.")
		}
	}
	r.w.Write(" ")
	if typ := mariaRequiredDefinitionFact(r, "column type", c.Type); typ != nil {
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
	generated := mariaRequiredDefinitionFact(r, "generated column", c.Generated)
	if generated != nil && generated.Kind != "none" {
		switch generated.Kind {
		case "systemRowStart":
			r.w.Write(" GENERATED ALWAYS AS ROW START")
		case "systemRowEnd":
			r.w.Write(" GENERATED ALWAYS AS ROW END")
		case "stored", "virtual":
			r.w.Write(" GENERATED ALWAYS AS (")
			r.expression("generated column", generated.Expression)
			r.w.Write(") " + strings.ToUpper(generated.Kind))
		default:
			r.w.Note("Unsupported generated column kind.")
			r.w.Write(" /* generation unavailable */")
		}
	}
	if nullable := mariaRequiredDefinitionFact(r, "column nullability", c.Nullable); nullable != nil {
		switch {
		case generated != nil && (generated.Kind == "stored" || generated.Kind == "virtual"):
			if !*nullable {
				r.w.Note("MariaDB computed-column declarations cannot express an explicit NOT NULL property.")
			}
		case generated != nil && (generated.Kind == "systemRowStart" || generated.Kind == "systemRowEnd"):
			if *nullable {
				r.w.Note("Native system-period fields require their intrinsic NOT NULL property.")
			}
		default:
			if *nullable {
				r.w.Write(" NULL")
			} else {
				r.w.Write(" NOT NULL")
			}
		}
	}
	if d := mariaRequiredDefinitionFact(r, "column default", c.Default); d != nil {
		r.defaultValue(*d)
	} else {
		r.w.Write(" /* default unavailable */")
	}
	if identity := mariaRequiredDefinitionFact(r, "column identity", c.Identity); identity != nil {
		switch identity.Kind {
		case "none":
		case "autoIncrement":
			r.w.Write(" AUTO_INCREMENT")
		default:
			r.w.Note("Unsupported MariaDB identity kind.")
		}
	}
	if update := sc.DefinitionFact(r.w, "column on-update", c.OnUpdate); update != nil {
		if !mariaDefinitionUpdate.MatchString(update.Text) {
			r.w.Note("Unsupported native ON UPDATE property.")
		} else {
			r.w.Write(" ON UPDATE ")
			r.w.Write(update.Text)
		}
	}
	if visible := mariaRequiredDefinitionFact(r, "column visibility", c.Visible); visible != nil && !*visible {
		r.w.Write(" INVISIBLE")
	}
	if comment := sc.DefinitionFact(r.w, "column comment", c.Comment); comment != nil && *comment != "" {
		r.w.Write(" COMMENT ")
		r.literal(*comment)
	}
	for _, option := range r.nativeColumnOptions.Items {
		if option.Name == "columnSystemVersioning:"+c.Ref.Name {
			if option.Value != "without" {
				r.w.Note("Unknown native column versioning policy.")
			} else {
				r.w.Write(" WITHOUT SYSTEM VERSIONING")
			}
		}
		if option.Name == "columnExtra:"+c.Ref.Name {
			r.w.Note("Unmodeled native column properties require manual SQL.")
		}
	}
	mariaRequiredDefinitionFact(r, "column ordinal", c.Ordinal)
}
func (r *mariaDefinition) columns(c sc.Collection[sc.Ref], label string) {
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
func (r *mariaDefinition) indexKeys(x sc.Index) {
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
		if desc := mariaRequiredDefinitionFact(r, "index order", key.Descending); desc != nil {
			unordered := x.Method.Value != nil && (strings.EqualFold(*x.Method.Value, "RTREE") || strings.EqualFold(*x.Method.Value, "SPATIAL") || strings.EqualFold(*x.Method.Value, "FULLTEXT"))
			if unordered {
				if *desc {
					r.w.Note("Unsupported descending order on a spatial or full-text index.")
				}
			} else if *desc {
				r.w.Write(" DESC")
			} else {
				r.w.Write(" ASC")
			}
		}
		if v := sc.DefinitionFact(r.w, "index operator class", key.Opclass); v != nil {
			r.w.Note("Unsupported MariaDB index operator class.")
		}
		if v := sc.DefinitionFact(r.w, "index collation", key.Collation); v != nil {
			r.w.Note("Unsupported MariaDB index collation.")
		}
		if len(sc.DefinitionItems(r.w, "index key options", key.Options)) > 0 {
			r.w.Note("Unsupported MariaDB index key options.")
		}
	}
	r.w.Write(")")
}
func (r *mariaDefinition) indexOptions(x sc.Index) {
	if method := mariaRequiredDefinitionFact(r, "index method", x.Method); method != nil {
		switch strings.ToUpper(*method) {
		case "BTREE", "HASH":
			r.w.Write(" USING " + strings.ToUpper(*method))
		case "FULLTEXT", "SPATIAL", "RTREE":
		default:
			r.w.Note("Unsupported index method " + *method + ".")
		}
	}
	if visible := mariaRequiredDefinitionFact(r, "index visibility", x.Visible); visible != nil && !*visible {
		r.w.Write(" IGNORED")
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
		r.w.Note("Unsupported MariaDB NULLS NOT DISTINCT index.")
	}
	if len(sc.DefinitionItems(r.w, "index included columns", x.Includes)) > 0 {
		r.w.Note("Unsupported MariaDB included index columns.")
	}
	if v := sc.DefinitionFact(r.w, "index predicate", x.Predicate); v != nil {
		r.w.Note("Unsupported MariaDB index predicate.")
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
func (r *mariaDefinition) constraint(c sc.Constraint, backing *sc.Index) {
	kind := mariaRequiredDefinitionFact(r, "constraint kind", c.Kind)
	if kind == nil {
		r.w.Write("/* constraint unavailable */")
		return
	}
	// ALTER rejects PRIMARY as an explicit index symbol (native error1280);
	// the primary key's native name is intrinsically PRIMARY.
	if !(r.alterConstraint && *kind == "p" && c.Ref.Name == "PRIMARY") {
		r.w.Write("CONSTRAINT ")
		r.identifier(c.Ref.Name)
		r.w.Write(" ")
	}
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
			r.w.Note("MariaDB native CHECK declarations cannot preserve NOT ENFORCED.")
		}
	case "f":
		r.w.Write("FOREIGN KEY (")
		r.columns(c.Columns, "foreign-key columns")
		r.w.Write(") REFERENCES ")
		if target := mariaRequiredDefinitionFact(r, "foreign-key target", c.Target); target != nil {
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
				case "RESTRICT", "CASCADE", "SET NULL", "NO ACTION":
					r.w.Write(" ON " + action.name + " " + strings.ToUpper(*value))
				default:
					r.w.Note("Unsupported foreign-key action " + *value + ".")
				}
			}
		}
		if match := sc.DefinitionFact(r.w, "foreign-key match", c.Match); match != nil && *match != "NONE" && *match != "" {
			r.w.Note("Unsupported MariaDB foreign-key MATCH " + *match + ".")
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
			r.w.Note("Unsupported MariaDB " + flag.label + ".")
		}
	}
}
func (r *mariaDefinition) index(x sc.Index) {
	if method := sc.DefinitionFact(r.w, "index method", x.Method); method != nil && (strings.EqualFold(*method, "FULLTEXT") || strings.EqualFold(*method, "SPATIAL") || strings.EqualFold(*method, "RTREE")) {
		kind := strings.ToUpper(*method)
		if kind == "RTREE" {
			kind = "SPATIAL"
		}
		r.w.Write(kind + " ")
	} else if unique := mariaRequiredDefinitionFact(r, "index uniqueness", x.Unique); unique != nil && *unique {
		r.w.Write("UNIQUE ")
	}
	r.w.Write("KEY ")
	r.identifier(x.Ref.Name)
	r.w.Write(" ")
	r.indexKeys(x)
	r.indexOptions(x)
}
func (r *mariaDefinition) table(t sc.Table) {
	if kind := mariaRequiredDefinitionFact(r, "table kind", t.Kind); kind != nil && *kind != "table" && *kind != "partitioned" && *kind != "systemVersioned" {
		r.w.Note("Unsupported MariaDB table kind " + *kind + ".")
	}
	r.nativeColumnOptions = t.Options
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
	if t.Kind.Value != nil && *t.Kind.Value == "systemVersioned" {
		periods := []MariaDBPeriodColumn{}
		for _, o := range t.Options.Items {
			if strings.HasPrefix(o.Name, "systemPeriod:") {
				var period MariaDBPeriodColumn
				if json.Unmarshal([]byte(o.Value), &period) == nil {
					periods = append(periods, period)
				}
			}
		}
		if mariaDefinitionPeriods(periods, t.Columns.Items) && !periods[0].Implicit {
			start()
			r.w.Write("PERIOD FOR SYSTEM_TIME (")
			r.identifier(periods[0].Name)
			r.w.Write(", ")
			r.identifier(periods[1].Name)
			r.w.Write(")")
		}
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
	systemPeriods := []MariaDBPeriodColumn{}
	for _, option := range sc.DefinitionItems(r.w, "table options", t.Options) {
		if r.w.Full() {
			break
		}
		if strings.HasPrefix(option.Name, "columnSystemVersioning:") {
			continue
		}
		if strings.HasPrefix(option.Name, "systemPeriod:") {
			var period MariaDBPeriodColumn
			if json.Unmarshal([]byte(option.Value), &period) != nil {
				r.w.Note("Invalid native period descriptor.")
			} else {
				systemPeriods = append(systemPeriods, period)
			}
			continue
		}
		switch strings.ToLower(option.Name) {
		case "nativepartitiondefinition", "nativeapplicationperiod":
			r.w.Note("Opaque native partition/application-period properties require reviewed native SQL.")
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
	if t.Kind.Value != nil && *t.Kind.Value == "systemVersioned" {
		if !mariaDefinitionPeriods(systemPeriods, t.Columns.Items) {
			r.w.Note("Native system-period completeness is unavailable.")
		} else {
			r.w.Write(" WITH SYSTEM VERSIONING")
		}
	}
	r.w.Write(";\n")
}

var mariaDefinitionUpdate = regexp.MustCompile(`(?i)^current_timestamp(?:\([0-6]?\))?$`)

func mariaDefinitionExpression(text string, engine sc.Fact[[]sc.Option]) bool {
	mode := ""
	if engine.State != "known" || engine.Value == nil {
		return false
	}
	found := false
	for _, o := range *engine.Value {
		if o.Name == "sqlMode" {
			if found && mode != o.Value {
				return false
			}
			found = true
			mode = o.Value
		}
	}
	if !found {
		return false
	}
	if len(text) == 0 || len(text) > 65536 || !utf8.ValidString(text) || strings.ContainsRune(text, 0) {
		return false
	}
	tokens, ok := mariaIndexMetadataTokens(text, mode, 0)
	if !ok || len(tokens) == 0 {
		return false
	}
	level := 0
	for _, t := range tokens {
		if t.kind == "punct" {
			switch t.value {
			case ";":
				return false
			case "(":
				level++
			case ")":
				level--
				if level < 0 {
					return false
				}
			}
		}
	}
	return level == 0
}
func mariaDefinitionPeriods(periods []MariaDBPeriodColumn, columns []sc.Column) bool {
	// Canonical bundles sort native options by key, placing ROW END first.
	if len(periods) == 2 && periods[0].Generated == "ROW END" && periods[1].Generated == "ROW START" {
		periods[0], periods[1] = periods[1], periods[0]
	}
	if len(periods) != 2 || periods[0].Generated != "ROW START" || periods[1].Generated != "ROW END" || periods[0].Implicit != periods[1].Implicit || periods[0].Name == periods[1].Name {
		return false
	}
	if periods[0].Implicit {
		return periods[0].Name == "ROW_START" && periods[1].Name == "ROW_END" && periods[0].NativeType == "timestamp(6)" && periods[1].NativeType == "timestamp(6)"
	}
	for i, p := range periods {
		found := false
		for _, c := range columns {
			role := "systemRowStart"
			if i == 1 {
				role = "systemRowEnd"
			}
			found = found || (c.Ref.Name == p.Name && c.Generated.Value != nil && c.Generated.Value.Kind == role)
		}
		if !found {
			return false
		}
	}
	return true
}

// RenderStructureColumn reproduces a known native column slot. Its SQL carries
// no operation authority; callers retain dependency, context and transition proof.
func RenderStructureColumn(ctx context.Context, column sc.Column, engineContext sc.Fact[[]sc.Option]) (string, string, error) {
	return RenderStructureColumnWithOptions(ctx, column, engineContext, sc.Complete[sc.Option](nil))
}
func RenderStructureColumnWithOptions(ctx context.Context, column sc.Column, engineContext sc.Fact[[]sc.Option], options sc.Collection[sc.Option]) (string, string, error) {
	if e := ctx.Err(); e != nil {
		return "", "", e
	}
	if options.State != "known" || !options.Complete {
		return "", "Native column versioning and extra-property visibility is incomplete; a complete option witness is required before reproducing the column.", nil
	}
	authored := map[*sc.Expression]bool{}
	if column.Default.Value != nil {
		authored[column.Default.Value.Expression] = true
	}
	if column.Generated.Value != nil {
		authored[column.Generated.Value.Expression] = true
	}
	authored[column.OnUpdate.Value] = true
	r := mariaDefinition{w: &sc.DefinitionWriter{Context: ctx}, engine: engineContext, authored: authored, nativeColumnOptions: options}
	r.column(column)
	definition, e := r.w.Finish()
	if e != nil {
		return "", "", e
	}
	if definition.Limited {
		return "", "The native column contains unavailable or unsupported properties; review its captured metadata.", nil
	}
	return definition.SQL, "", nil
}

func mariaDefinitionTypeBounds(name string, m sc.TypeModifiers) bool {
	within := func(value *int64, low, high int64) bool { return value == nil || (*value >= low && *value <= high) }
	if !within(m.DatetimePrecision, 0, 6) {
		return false
	}
	switch name {
	case "decimal", "numeric":
		if !within(m.Precision, 1, 65) || !within(m.Scale, 0, 38) {
			return false
		}
		if m.Precision != nil && m.Scale != nil && *m.Scale > *m.Precision {
			return false
		}
	case "float", "double", "real":
		if !within(m.Precision, 1, 255) || !within(m.Scale, 0, 30) {
			return false
		}
	case "bit":
		if !within(m.Length, 1, 64) {
			return false
		}
	case "char", "binary":
		if !within(m.Length, 0, 255) {
			return false
		}
	case "varchar", "varbinary":
		if !within(m.Length, 1, 65535) {
			return false
		}
	case "tinyint", "smallint", "mediumint", "int", "integer", "bigint", "year":
		if !within(m.Length, 0, 255) {
			return false
		}
	}
	return true
}

func (r *mariaDefinition) sequence(sequence sc.Sequence) {
	if sequence.Type.Value == nil || sequence.Type.State != "known" || sequence.Type.Value.Ref.Name != "bigint" || sequence.Type.Value.Kind != "builtin" {
		r.w.Note("Unsupported native sequence type.")
	}
	r.w.Write("CREATE SEQUENCE ")
	r.ref(sequence.Ref)
	for _, part := range []struct {
		label, sql string
		fact       sc.Fact[string]
		positive   bool
	}{{"start", " START WITH ", sequence.Start, false}, {"increment", " INCREMENT BY ", sequence.Increment, false}, {"minimum", " MINVALUE ", sequence.Min, false}, {"maximum", " MAXVALUE ", sequence.Max, false}, {"cache", " CACHE ", sequence.Cache, true}} {
		value := mariaRequiredDefinitionFact(r, "sequence "+part.label, part.fact)
		if value == nil {
			continue
		}
		number, e := strconv.ParseInt(*value, 10, 64)
		if e != nil || (part.positive && number < 0) || (part.label == "increment" && number == 0) {
			r.w.Note("Invalid native sequence " + part.label + ".")
			continue
		}
		if part.label == "cache" && number == 0 {
			r.w.Write(" NOCACHE")
		} else {
			r.w.Write(part.sql + *value)
		}
	}
	if cycle := mariaRequiredDefinitionFact(r, "sequence cycle", sequence.Cycle); cycle != nil {
		if *cycle {
			r.w.Write(" CYCLE")
		} else {
			r.w.Write(" NOCYCLE")
		}
	}
	if sc.DefinitionFact(r.w, "sequence owner", sequence.Owner) != nil {
		r.w.Note("Native sequence ownership requires separate reviewed SQL.")
	}
	r.w.Write(" ENGINE=InnoDB;\n")
}
