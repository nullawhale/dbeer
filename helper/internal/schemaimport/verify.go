package schemaimport

import (
	"bytes"
	sc "dbeer/helper/internal/schemacompare"
	"encoding/json"
	"reflect"
	"strings"
)

// SQL files and their hashes are user-controlled. The independent grammar is
// the authority for supported facts; metadata not established by that grammar
// remains manual even when the manifest and all hashes agree.
func validateColumnBaseline(old sc.Column, ast columnAST, engine string) (bool, error) {
	limited := !ast.supported
	typ, err := builtinType(ast.typ, engine)
	if err != nil {
		return true, nil
	}
	if old.Type.State != "known" || old.Type.Value == nil || old.Type.Value.Ref != typ.Ref || old.Type.Value.Kind != typ.Kind {
		return false, ErrInvalid
	}
	if !sameJSON(*old.Type.Value, typ) {
		limited = true
	}
	if !defaultMatchesSQL(old.Default, ast.attrs["default"], engine) {
		return false, ErrInvalid
	}
	if parsedDefault, err := pureDefault(ast.attrs["default"], engine); err != nil {
		limited = true
	} else if old.Default.Value != nil {
		d := old.Default.Value
		if d.Kind == "expression" && d.Expression != nil {
			expected := sc.Complete[sc.Ref](nil)
			if parsedDefault.Sequence != nil {
				expected = sc.Complete([]sc.Ref{*parsedDefault.Sequence})
			}
			if !sameJSON(d.Expression.Dependencies, expected) || len(d.Expression.Functions) > 0 || len(d.Expression.Operators) > 0 || len(d.Expression.Collations) > 0 {
				limited = true
			}
		} else if d.Expression != nil || d.Sequence != nil && parsedDefault.Sequence == nil || d.Type != nil && !sameJSON(*d.Type, typ) {
			limited = true
		}
	}
	nullable := len(ast.attrs["nullable"]) == 0 || !ast.attrs["nullable"][0].is("NOT")
	if old.Nullable.State != "known" || old.Nullable.Value == nil || *old.Nullable.Value != nullable {
		return false, ErrInvalid
	}
	expected := sc.Column{Ref: old.Ref, Ordinal: old.Ordinal, Type: old.Type, Nullable: old.Nullable, Default: old.Default,
		Generated: sc.Known(sc.Generated{Kind: "none"}), Identity: sc.Known(sc.Identity{Kind: "none"}),
		Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Visible: sc.Known(true), Comment: sc.Known(""), OnUpdate: sc.Absent[sc.Expression]()}
	if ts := ast.attrs["charset"]; len(ts) > 0 {
		name, ok := ts[0].identifier(engine)
		if !ok {
			return false, ErrUnsupported
		}
		expected.Charset = sc.Known(name)
	}
	if ts := ast.attrs["collation"]; len(ts) > 0 {
		p := cursor{ts: ts, engine: engine}
		schema, name, e := p.qualified("")
		if e != nil || p.i != len(ts) {
			return false, ErrUnsupported
		}
		expected.Collation = sc.Known(sc.Ref{Kind: "collation", Schema: schema, Name: name})
	}
	if ts := ast.attrs["comment"]; len(ts) > 0 {
		expected.Comment = sc.Known(ts[0].value)
	}
	if ts := ast.attrs["identity"]; len(ts) > 0 {
		if engine != "mysql" {
			limited = true
		} else {
			expected.Identity = sc.Known(sc.Identity{Kind: "autoIncrement"})
		}
	}
	if ts := ast.attrs["visible"]; len(ts) > 0 {
		expected.Visible = sc.Known(!ts[0].is("INVISIBLE"))
	}
	// PostgreSQL comments are separate owned statements, validated below.
	if engine == "postgresql" {
		expected.Comment = old.Comment
	}
	if !reflect.DeepEqual(expected, old) {
		limited = true
	}
	return limited, nil
}

func validateTableBaseline(old sc.Table, ast tableAST, engine string) (bool, error) {
	expected := sc.Table{Ref: old.Ref, Kind: sc.Known("r"), Storage: sc.Known("p"), Charset: sc.Absent[string](), Collation: sc.Absent[sc.Ref](), Options: sc.Complete[sc.Option](nil)}
	if ast.unlogged {
		expected.Storage = sc.Known("u")
	}
	if engine == "mysql" {
		expected.Kind = sc.Known("table")
		expected.Storage = sc.Unknown[string]("offlineDefaultEngine")
		expected.Charset = sc.Unknown[string]("offlineDefaultCharset")
		expected.Collation = sc.Unknown[sc.Ref]("offlineDefaultCollation")
	}
	if err := applyTableSuffix(&expected, ast.suffix, engine); err != nil {
		return true, nil
	}
	return !reflect.DeepEqual(old.Kind, expected.Kind) || !reflect.DeepEqual(old.Storage, expected.Storage) || !reflect.DeepEqual(old.Charset, expected.Charset) || !reflect.DeepEqual(old.Collation, expected.Collation) || !reflect.DeepEqual(old.Options, expected.Options), nil
}

func collatable(t sc.TypeUse, engine string) bool {
	if t.Kind == "array" && t.Element != nil {
		return collatable(*t.Element, engine)
	}
	if engine == "postgresql" {
		return t.Ref.Schema == "pg_catalog" && (t.Ref.Name == "text" || t.Ref.Name == "varchar" || t.Ref.Name == "bpchar")
	}
	switch strings.ToLower(t.Ref.Name) {
	case "char", "varchar", "tinytext", "text", "mediumtext", "longtext", "enum", "set":
		return true
	}
	return false
}
func inheritColumnProperties(c *sc.Column, t sc.Table, ast columnAST, engine string) {
	if c.Type.Value == nil {
		return
	}
	if !collatable(*c.Type.Value, engine) {
		return
	}
	if engine == "postgresql" {
		if len(ast.attrs["collation"]) == 0 {
			c.Collation = sc.Unknown[sc.Ref]("offlineDefaultCollation")
			c.CollationProperties = nil
		}
		return
	}
	if len(ast.attrs["charset"]) == 0 {
		c.Charset = t.Charset
	}
	if len(ast.attrs["collation"]) == 0 {
		if len(ast.attrs["charset"]) == 0 {
			c.Collation = t.Collation
		} else {
			c.Collation = sc.Unknown[sc.Ref]("offlineCharsetDefaultCollation")
		}
	}
}
func capturedOtherFactsMatch(actual, parsed sc.Table) bool {
	for _, k := range parsed.Constraints.Items {
		found := false
		for _, old := range actual.Constraints.Items {
			if old.Ref == k.Ref {
				found = true
				a, b := old, k
				a.BackingIndex = sc.Absent[sc.Ref]()
				b.BackingIndex = sc.Absent[sc.Ref]()
				if !reflect.DeepEqual(a, b) {
					return false
				}
			}
		}
		if !found {
			return false
		}
	}
	for _, x := range parsed.Indexes.Items {
		found := false
		for _, old := range actual.Indexes.Items {
			if old.Ref == x.Ref {
				found = true
				if !reflect.DeepEqual(old, x) {
					return false
				}
			}
		}
		if !found {
			return false
		}
	}
	for _, column := range parsed.Columns.Items {
		for _, old := range actual.Columns.Items {
			if old.Ref == column.Ref && !reflect.DeepEqual(old.Comment, column.Comment) {
				return false
			}
		}
	}
	return true
}

func sameJSON(a, b any) bool {
	aa, e := json.Marshal(a)
	if e != nil {
		return false
	}
	bb, e := json.Marshal(b)
	return e == nil && bytes.Equal(aa, bb)
}

func completeIndexDefaults(table *sc.Table, engine string) {
	for i := range table.Indexes.Items {
		for j := range table.Indexes.Items[i].Keys.Items {
			key := &table.Indexes.Items[i].Keys.Items[j]
			if engine != "postgresql" || key.Opclass.Code != "offlineDefaultOpclass" || key.Column.Value == nil {
				continue
			}
			for _, column := range table.Columns.Items {
				if column.Ref != *key.Column.Value || column.Type.Value == nil {
					continue
				}
				typ := *column.Type.Value
				opclass := ""
				if typ.Kind == "array" {
					opclass = "array_ops"
				} else if typ.Kind == "builtin" && typ.Ref.Schema == "pg_catalog" {
					switch typ.Ref.Name {
					case "int2", "int4", "int8", "float4", "float8", "bool", "numeric", "text", "bpchar", "bytea", "uuid", "date", "timestamp", "timestamptz", "time", "timetz", "bit", "varbit", "money", "oid", "inet", "macaddr", "macaddr8", "jsonb":
						opclass = typ.Ref.Name + "_ops"
					case "varchar":
						opclass = "text_ops"
					case "cidr":
						opclass = "inet_ops"
					}
				}
				if opclass != "" {
					key.Opclass = sc.Known(sc.Ref{Kind: "opclass", Schema: "pg_catalog", Name: opclass})
				}
				key.Collation = column.Collation
			}
		}
	}
}

func resolveNamedTypes(c *sc.Capture) error {
	definitions := map[sc.Ref]sc.TypeDefinition{}
	for _, typ := range c.Types {
		definitions[typ.Ref] = typ
	}
	for i := range c.Tables {
		for j := range c.Tables[i].Columns.Items {
			column := &c.Tables[i].Columns.Items[j]
			if column.Type.Value == nil || column.Type.Value.Kind != "offlineNamed" {
				continue
			}
			use := *column.Type.Value
			definition, ok := definitions[use.Ref]
			if !ok || definition.Kind.Value == nil || *definition.Kind.Value != "e" || !definition.Labels.Complete || definition.Labels.State != "known" {
				return ErrUnsupported
			}
			use.Kind = "e"
			column.Type = sc.Known(use)
		}
	}
	return nil
}
