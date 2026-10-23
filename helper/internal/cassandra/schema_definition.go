package cassandra

import (
	"context"
	"sort"
	"strconv"
	"strings"

	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/textdiff"
)

// RenderSchemaDefinition reads only frozen facts. Server option values already
// contain escaped CQL literals; identifiers remain typed until this boundary.
func RenderSchemaDefinition(ctx context.Context, capture sc.Capture, ref sc.Ref) (sc.Definition, error) {
	r := cassandraDefinition{w: &sc.DefinitionWriter{Context: ctx}}
	switch ref.Kind {
	case "type":
		for _, d := range capture.Types {
			if d.Ref == ref {
				r.w.Write("CREATE TYPE " + qualified(d.Ref.Schema, d.Ref.Name) + " (\n")
				for i, field := range sc.DefinitionItems(r.w, "UDT fields", d.Attributes) {
					if i > 0 {
						r.w.Write(",\n")
					}
					r.w.Write("  " + quoteIdentifier(field.Ref.Name) + " ")
					if u := sc.DefinitionFact(r.w, "field type", field.Type); u != nil {
						r.typ(*u, 0)
					} else {
						r.w.Write("/* unavailable */")
					}
				}
				r.w.Write("\n);\n")
				return r.w.Finish()
			}
		}
	case "table":
		for _, table := range capture.Tables {
			if table.Ref == ref {
				r.table(table)
				return r.w.Finish()
			}
		}
	case "schema":
		r.w.Note("Keyspace replication and durable-write settings are captured in metadata; this preview does not generate keyspace changes.")
		return r.w.Finish()
	}
	r.w.Note("This property is not represented in CQL; see metadata details.")
	return r.w.Finish()
}

type cassandraDefinition struct{ w *sc.DefinitionWriter }

func (r cassandraDefinition) scalar(text string) string {
	if len(text) <= textdiff.MaxTextBytes {
		return text
	}
	r.w.Note("A catalog value exceeds the CQL preview limit.")
	return strings.ToValidUTF8(text[:textdiff.MaxTextBytes], "")
}
func (r cassandraDefinition) typ(u sc.TypeUse, depth int) {
	if depth >= 64 {
		r.w.Note("Type nesting exceeds the CQL preview limit.")
		r.w.Write("/* unavailable */")
		return
	}
	if u.Modifiers.State != "known" {
		r.w.Note("Type modifiers are unavailable.")
	}
	switch u.Kind {
	case "builtin":
		r.w.Write(r.scalar(u.Ref.Name))
	case "udt":
		r.w.Write(qualified(u.Ref.Schema, u.Ref.Name))
	case "custom":
		r.w.Write(quoteText(r.scalar(u.Ref.Name)))
		r.w.Note("Custom Java type implementation equivalence requires manual review.")
	case "frozen", "list", "set", "vector":
		r.w.Write(u.Kind + "<")
		if u.Element == nil {
			r.w.Note("Element type is unavailable.")
			r.w.Write("/* unavailable */")
		} else {
			r.typ(*u.Element, depth+1)
		}
		if u.Kind == "vector" {
			if u.Modifiers.Value == nil || u.Modifiers.Value.Length == nil {
				r.w.Note("Vector dimensions are unavailable.")
				r.w.Write(", /* unavailable */")
			} else {
				r.w.Write(", " + strconv.FormatInt(*u.Modifiers.Value.Length, 10))
			}
		}
		r.w.Write(">")
	case "map", "tuple":
		r.w.Write(u.Kind + "<")
		for i, argument := range u.Arguments {
			if i > 0 {
				r.w.Write(", ")
			}
			r.typ(argument, depth+1)
		}
		r.w.Write(">")
	default:
		r.w.Note("Unknown Cassandra type.")
		r.w.Write("/* unavailable */")
	}
}

func (r cassandraDefinition) table(t sc.Table) {
	static := map[sc.Ref]bool{}
	var primary, partition []sc.Ref
	var predicate *sc.Expression
	for _, constraint := range sc.DefinitionItems(r.w, "constraints", t.Constraints) {
		if kind := sc.DefinitionFact(r.w, "constraint kind", constraint.Kind); kind != nil {
			switch *kind {
			case "p":
				primary = sc.DefinitionItems(r.w, "primary key", constraint.Columns)
			case "partitionKey":
				partition = sc.DefinitionItems(r.w, "partition key", constraint.Columns)
			case "staticColumns":
				for _, column := range sc.DefinitionItems(r.w, "static columns", constraint.Columns) {
					static[column] = true
				}
			case "viewPredicate":
				predicate = sc.DefinitionFact(r.w, "view predicate", constraint.Check)
			}
		}
	}
	key := func() string {
		var parts []string
		for _, ref := range partition {
			parts = append(parts, quoteIdentifier(ref.Name))
		}
		partitionPart := strings.Join(parts, ", ")
		if len(partition) > 1 {
			partitionPart = "(" + partitionPart + ")"
		}
		parts = []string{partitionPart}
		for _, ref := range primary[len(partition):] {
			parts = append(parts, quoteIdentifier(ref.Name))
		}
		return "PRIMARY KEY (" + strings.Join(parts, ", ") + ")"
	}
	if len(partition) == 0 || len(primary) < len(partition) {
		r.w.Note("Primary key metadata is unavailable.")
		return
	}
	options := map[string]string{}
	for _, option := range sc.DefinitionItems(r.w, "table options", t.Options) {
		options[option.Name] = option.Value
	}
	kind := sc.DefinitionFact(r.w, "table kind", t.Kind)
	if kind != nil && *kind == "materializedView" {
		var base *sc.Ref
		for _, dependency := range t.Dependencies.Items {
			if dependency.Kind == "materializedView" {
				copy := dependency.To
				base = &copy
				break
			}
		}
		if base == nil {
			r.w.Note("Materialized-view base table is unavailable.")
			return
		}
		r.w.Write("CREATE MATERIALIZED VIEW " + qualified(t.Ref.Schema, t.Ref.Name) + " AS\n  SELECT ")
		if options["include_all_columns"] == "true" {
			r.w.Write("*")
		} else {
			for i, column := range sc.DefinitionItems(r.w, "columns", t.Columns) {
				if i > 0 {
					r.w.Write(", ")
				}
				r.w.Write(quoteIdentifier(column.Ref.Name))
			}
		}
		r.w.Write(" FROM " + qualified(base.Schema, base.Name) + "\n  WHERE ")
		if predicate == nil {
			r.w.Note("Materialized-view predicate is unavailable.")
			r.w.Write("/* unavailable */")
		} else {
			dependencies := sc.DefinitionItems(r.w, "view predicate dependencies", predicate.Dependencies)
			resolved := cassandraViewExpression(predicate.Text, t.Ref, t.Columns.Items)
			matched := resolved.Dependencies.Complete && len(resolved.Dependencies.Items) == len(dependencies)
			known := map[sc.Ref]bool{}
			for _, ref := range dependencies {
				known[ref] = true
			}
			for _, ref := range resolved.Dependencies.Items {
				if !known[ref] {
					matched = false
				}
			}
			if !matched {
				r.w.Note("Captured view-predicate identifiers cannot be rewritten by this mapping; review the original CQL expression.")
			}
			r.w.Write(r.scalar(predicate.Text))
		}
		r.w.Write("\n  " + key())
	} else {
		r.w.Write("CREATE TABLE " + qualified(t.Ref.Schema, t.Ref.Name) + " (\n")
		for _, column := range sc.DefinitionItems(r.w, "columns", t.Columns) {
			r.w.Write("  " + quoteIdentifier(column.Ref.Name) + " ")
			if u := sc.DefinitionFact(r.w, "column type", column.Type); u != nil {
				r.typ(*u, 0)
			} else {
				r.w.Write("/* unavailable */")
			}
			if static[column.Ref] {
				r.w.Write(" STATIC")
			}
			r.w.Write(",\n")
		}
		r.w.Write("  " + key() + "\n)")
	}
	clauses := []string{}
	for _, index := range sc.DefinitionItems(r.w, "indexes", t.Indexes) {
		if index.Method.Value == nil || *index.Method.Value != "clustering" {
			continue
		}
		var parts []string
		for _, k := range index.Keys.Items {
			if k.Column.Value != nil {
				direction := "ASC"
				if k.Descending.Value != nil && *k.Descending.Value {
					direction = "DESC"
				}
				parts = append(parts, quoteIdentifier(k.Column.Value.Name)+" "+direction)
			}
		}
		if len(parts) > 0 {
			clauses = append(clauses, "CLUSTERING ORDER BY ("+strings.Join(parts, ", ")+")")
		}
	}
	var names []string
	for name := range options {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		switch name {
		case "where_clause", "include_all_columns":
			continue
		case "extensions":
			if options[name] != "{}" {
				r.w.Note("Table extension metadata has no supported CQL recreation syntax; see metadata details.")
			}
			continue
		case "dclocal_read_repair_chance", "read_repair_chance":
			// These compatibility catalog columns remain on 4.1/5.0 even
			// though CQL replaced them with the read_repair option.
			if options[name] != "0" {
				r.w.Note("Legacy read-repair probability cannot be represented by the current CQL table options.")
			}
			continue
		case "flags":
			if strings.Contains(options[name], "dense") || strings.Contains(options[name], "super") {
				r.w.Note("Legacy compact-storage flags require manual review.")
			}
			continue
		}
		// Option names originate in system_schema column metadata, but still
		// validate their spelling before using them as CQL grammar.
		if !cassandraOptionName(name) {
			r.w.Note("An option name is unavailable in CQL.")
			continue
		}
		clauses = append(clauses, name+" = "+r.scalar(options[name]))
	}
	if len(clauses) > 0 {
		r.w.Write(" WITH " + strings.Join(clauses, "\n  AND "))
	}
	r.w.Write(";\n")
	for _, index := range t.Indexes.Items {
		if index.Method.Value == nil || *index.Method.Value == "clustering" {
			continue
		}
		if len(index.Keys.Items) != 1 || index.Keys.Items[0].Column.Value == nil {
			r.w.Note("Index target metadata is unavailable.")
			continue
		}
		custom := *index.Method.Value == "CUSTOM"
		r.w.Write("CREATE ")
		if custom {
			r.w.Write("CUSTOM ")
		}
		r.w.Write("INDEX " + quoteIdentifier(index.Ref.Name) + " ON " + qualified(t.Ref.Schema, t.Ref.Name) + " (")
		key := index.Keys.Items[0]
		var targetKind string
		for _, option := range key.Options.Items {
			if option.Name == "targetKind" {
				targetKind = option.Value
			}
		}
		if targetKind != "" {
			r.w.Write(targetKind + "(")
		}
		r.w.Write(quoteIdentifier(key.Column.Value.Name))
		if targetKind != "" {
			r.w.Write(")")
		}
		r.w.Write(")")
		var options []string
		for _, option := range index.Options.Items {
			if option.Name == "class_name" && custom {
				r.w.Write(" USING " + quoteText(r.scalar(option.Value)))
			} else {
				options = append(options, quoteText(option.Name)+": "+quoteText(r.scalar(option.Value)))
			}
		}
		if len(options) > 0 {
			r.w.Write(" WITH OPTIONS = {" + strings.Join(options, ", ") + "}")
		}
		r.w.Write(";\n")
	}
}

func cassandraOptionName(name string) bool {
	if name == "" {
		return false
	}
	for _, c := range name {
		if !(c >= 'a' && c <= 'z' || c == '_') {
			return false
		}
	}
	return true
}
