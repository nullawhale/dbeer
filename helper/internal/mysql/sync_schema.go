package mysql

import (
	"context"
	"reflect"
	"strconv"
	"strings"

	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/syncplan"
)

// RenderSynchronizationSchema only formats typed captured facts; it does not
// acquire a session or reinterpret a displayed definition as a migration.
func RenderSynchronizationSchema(ctx context.Context, op syncplan.SchemaOperation) (string, string, error) {
	r := myDefinition{w: &sc.DefinitionWriter{Context: ctx}, engine: op.Target.Context.EngineContext}
	manual := func(reason string) (string, string, error) { return "", reason, nil }
	finish := func() (string, string, error) {
		d, e := r.w.Finish()
		if e != nil {
			return "", "", e
		}
		if d.Limited {
			return manual("The MySQL generator cannot preserve all captured properties or target literal modes.")
		}
		return d.SQL, "", nil
	}
	if op.Action == "drop" {
		return manual("Removal requires review of dependencies outside the captured scope.")
	}
	if op.Ref.Kind == "schema" {
		return manual("Database charset, collation and ownership are not fully captured; create it manually.")
	}
	table, ok := syncplan.SchemaTable(op.Source, op.Ref)
	if !ok {
		return manual("This object transformation requires manual MySQL SQL.")
	}
	if op.Action == "create" && op.Ref.Kind == "table" {
		table.Constraints = sc.Complete[sc.Constraint](nil)
		table.Indexes = sc.Complete[sc.Index](nil)
		if reason := syncplan.SchemaFactsReason(table); reason != "" {
			return manual(reason)
		}
		if !synchronizationLiteralsPortable(table) {
			return manual("Backslashes or control characters in DDL literals require manual SQL because a later editor session may use a different SQL mode.")
		}
		if len(table.Columns.Items) == 0 {
			return manual("A table with no captured columns requires manual SQL.")
		}
		r.table(table)
		return finish()
	}
	if op.Ref.Kind == "column" {
		column, found := syncplan.SchemaColumn(op.Source, op.Ref)
		if !found {
			return manual("Column metadata is unavailable.")
		}
		if reason := syncplan.SchemaFactsReason(column); reason != "" {
			return manual(reason)
		}
		if !synchronizationLiteralsPortable(column) {
			return manual("Backslashes or control characters in DDL literals require manual SQL because a later editor session may use a different SQL mode.")
		}
		if op.Action == "create" {
			r.w.Write("ALTER TABLE ")
			r.ref(table.Ref)
			r.w.Write(" ADD COLUMN ")
			r.column(column)
			if column.Ordinal.Value == nil {
				return manual("Column ordinal is unavailable.")
			}
			if *column.Ordinal.Value == 0 {
				r.w.Write(" FIRST")
			} else {
				var preceding *sc.Column
				for i := range table.Columns.Items {
					c := &table.Columns.Items[i]
					if c.Ordinal.Value != nil && *c.Ordinal.Value == *column.Ordinal.Value-1 {
						preceding = c
					}
				}
				if preceding == nil {
					return manual("The preceding column is unavailable for ordinal " + strconv.Itoa(*column.Ordinal.Value) + ".")
				}
				// A second new column is a separate prerequisite in the core.
				r.w.Write(" AFTER ")
				r.identifier(preceding.Ref.Name)
			}
			r.w.Write(";\n")
			return finish()
		}
		if op.Action == "alter" {
			old, exists := syncplan.SchemaColumn(op.Target, op.Ref)
			if !exists {
				return manual("Target column originals are unavailable.")
			}
			if reason := syncplan.SchemaFactsReason(old); reason != "" {
				return manual(reason)
			}
			unchanged := column
			unchanged.Nullable, unchanged.Default, unchanged.Comment = old.Nullable, old.Default, old.Comment
			if !reflect.DeepEqual(unchanged, old) {
				return manual("Type, ordinal, identity, generation and other column transformations require manual SQL.")
			}
			r.w.Write("ALTER TABLE ")
			r.ref(table.Ref)
			r.w.Write(" MODIFY COLUMN ")
			r.column(column)
			r.w.Write(";\n")
			return finish()
		}
	}
	if op.Action == "create" && op.Ref.Kind == "constraint" {
		for _, constraint := range table.Constraints.Items {
			if constraint.Ref != op.Ref {
				continue
			}
			if reason := syncplan.SchemaFactsReason(constraint); reason != "" {
				return manual(reason)
			}
			if constraint.Kind.Value == nil || (*constraint.Kind.Value != "p" && *constraint.Kind.Value != "u" && *constraint.Kind.Value != "f") {
				return manual("Only primary, unique and foreign-key constraint creation is supported automatically.")
			}
			if *constraint.Kind.Value == "p" && constraint.Ref.Name != "PRIMARY" {
				return manual("MySQL primary-key constraints retain the reserved PRIMARY name; this mapping requires manual review.")
			}
			var backing *sc.Index
			for i := range table.Indexes.Items {
				index := &table.Indexes.Items[i]
				if constraint.BackingIndex.Value != nil && index.Ref == *constraint.BackingIndex.Value {
					backing = index
				}
			}
			if constraint.BackingIndex.Value != nil && backing == nil {
				return manual("The constraint backing index is unavailable.")
			}
			if backing != nil {
				if backing.Ref.Name != constraint.Ref.Name {
					return manual("The mapped constraint and backing-index names must remain one ownership unit.")
				}
				if reason := syncplan.SchemaFactsReason(*backing); reason != "" {
					return manual(reason)
				}
				if !synchronizationLiteralsPortable(*backing) {
					return manual("Mode-dependent backing-index literals require manual SQL.")
				}
			}
			r.w.Write("ALTER TABLE ")
			r.ref(table.Ref)
			r.w.Write(" ADD ")
			r.constraint(constraint, backing)
			r.w.Write(";\n")
			return finish()
		}
	}
	if op.Action == "create" && op.Ref.Kind == "index" {
		for _, index := range table.Indexes.Items {
			if index.Ref == op.Ref {
				if reason := syncplan.SchemaFactsReason(index); reason != "" {
					return manual(reason)
				}
				if !synchronizationLiteralsPortable(index) {
					return manual("Mode-dependent index literals require manual SQL.")
				}
				if index.Constraint.Value != nil {
					return manual("Constraint-backed indexes are generated with their owning constraint.")
				}
				r.w.Write("ALTER TABLE ")
				r.ref(table.Ref)
				r.w.Write(" ADD ")
				r.index(index)
				r.w.Write(";\n")
				return finish()
			}
		}
	}
	return manual("This MySQL transformation requires manual SQL; existing objects are not automatically replaced.")
}

// A saved SQL file or new editor connection need not retain the capture's
// NO_BACKSLASH_ESCAPES mode. Plain and quote-doubled literals are portable;
// binary defaults/labels already use hex. Other mode-dependent literals stay
// manual rather than silently changing bytes in a later session.
func synchronizationLiteralsPortable(value any) bool {
	safe := func(s string) bool {
		for _, r := range s {
			if r == '\\' || r < 0x20 || r == 0x7f {
				return false
			}
		}
		return true
	}
	var inspect func(reflect.Value) bool
	inspect = func(v reflect.Value) bool {
		if !v.IsValid() {
			return true
		}
		if v.Type() == reflect.TypeOf(sc.Default{}) {
			d := v.Interface().(sc.Default)
			if d.Kind == "literal" && d.Encoding != "base64" && d.Value != nil && !safe(*d.Value) {
				return false
			}
		}
		if v.Type() == reflect.TypeOf(sc.TypeUse{}) {
			u := v.Interface().(sc.TypeUse)
			if u.LabelEncoding != "base64" {
				for _, label := range u.Labels.Items {
					if !safe(label) {
						return false
					}
				}
			}
		}
		if v.Type() == reflect.TypeOf(sc.Column{}) {
			c := v.Interface().(sc.Column)
			if c.Comment.Value != nil && !safe(*c.Comment.Value) {
				return false
			}
		}
		if v.Type() == reflect.TypeOf(sc.Option{}) {
			o := v.Interface().(sc.Option)
			if strings.EqualFold(o.Name, "comment") && !safe(o.Value) {
				return false
			}
		}
		switch v.Kind() {
		case reflect.Pointer:
			if !v.IsNil() {
				return inspect(v.Elem())
			}
		case reflect.Struct:
			for i := 0; i < v.NumField(); i++ {
				if !inspect(v.Field(i)) {
					return false
				}
			}
		case reflect.Slice:
			for i := 0; i < v.Len(); i++ {
				if !inspect(v.Index(i)) {
					return false
				}
			}
		}
		return true
	}
	return inspect(reflect.ValueOf(value))
}
