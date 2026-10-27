package postgres

import (
	"context"
	"reflect"

	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/syncplan"
)

// RenderSynchronizationSchema reuses typed grammar, never displayed SQL. A
// definition that omitted a fact is a manual step, not an executable migration.
func RenderSynchronizationSchema(ctx context.Context, op syncplan.SchemaOperation) (string, string, error) {
	r := pgDefinition{w: &sc.DefinitionWriter{Context: ctx}, types: map[sc.Ref]sc.TypeDefinition{}}
	for _, t := range op.Source.Types {
		r.types[t.Ref] = t
	}
	manual := func(reason string) (string, string, error) { return "", reason, nil }
	finish := func() (string, string, error) {
		d, e := r.w.Finish()
		if e != nil {
			return "", "", e
		}
		if d.Limited {
			return manual("The PostgreSQL generator cannot preserve all captured properties.")
		}
		return d.SQL, "", nil
	}
	if op.Action == "drop" {
		return manual("Removal requires review of dependencies outside the captured scope.")
	}
	if op.Action == "create" && op.Ref.Kind == "schema" {
		r.write("CREATE SCHEMA ", r.name(op.Ref.Name), ";\n")
		return finish()
	}
	if op.Action == "create" && op.Ref.Kind == "type" {
		for _, typ := range op.Source.Types {
			if typ.Ref == op.Ref {
				if typ.Kind.Value == nil || *typ.Kind.Value != "e" || typ.Extension != nil {
					return manual("Only independent enum type creation is supported automatically.")
				}
				if reason := syncplan.SchemaFactsReason(typ); reason != "" {
					return manual(reason)
				}
				r.typeDefinition(typ)
				if typ.Comment != nil && *typ.Comment != "" {
					r.write("COMMENT ON TYPE ", r.ref(typ.Ref), " IS ", r.literal(*typ.Comment), ";\n")
				}
				return finish()
			}
		}
	}
	table, ok := syncplan.SchemaTable(op.Source, op.Ref)
	if !ok {
		return manual("This object transformation requires manual PostgreSQL SQL.")
	}
	if op.Action == "create" && op.Ref.Kind == "table" {
		if table.Storage.Value == nil || *table.Storage.Value == "t" {
			return manual("Temporary or unknown table persistence requires manual SQL.")
		}
		table.Constraints = sc.Complete[sc.Constraint](nil)
		table.Indexes = sc.Complete[sc.Index](nil)
		if reason := syncplan.SchemaFactsReason(table); reason != "" {
			return manual(reason)
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
		if op.Action == "create" {
			// ADD appends a column; an earlier ordinal would silently change the
			// desired structure and is therefore outside this automatic slice.
			if target, exists := syncplan.SchemaTable(op.Target, op.Ref); exists {
				if column.Ordinal.Value == nil || *column.Ordinal.Value < len(target.Columns.Items) || *column.Ordinal.Value >= len(table.Columns.Items) || len(table.Columns.Items) < len(target.Columns.Items) {
					return manual("Adding a column at this ordinal requires manual table reconstruction.")
				}
				for i, original := range target.Columns.Items {
					desired := table.Columns.Items[i]
					if desired.Ref != original.Ref || desired.Ordinal.State != "known" || original.Ordinal.State != "known" || desired.Ordinal.Value == nil || original.Ordinal.Value == nil || *desired.Ordinal.Value != i || *original.Ordinal.Value != i {
						return manual("Automatic PostgreSQL additions require the existing target columns to retain their mapped names and ordinal prefix.")
					}
				}
			}
			r.write("ALTER TABLE ", r.ref(table.Ref), " ADD COLUMN ")
			r.column(column, false)
			r.write(";\n")
			if column.Comment.Value != nil && *column.Comment.Value != "" {
				r.write("COMMENT ON COLUMN ", r.ref(table.Ref), ".", r.name(column.Ref.Name), " IS ", r.literal(*column.Comment.Value), ";\n")
			}
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
			prefix := "ALTER TABLE " + r.ref(table.Ref) + " ALTER COLUMN " + r.name(column.Ref.Name)
			if !reflect.DeepEqual(column.Nullable, old.Nullable) {
				if column.Nullable.Value == nil {
					return manual("Column nullability is unknown.")
				}
				if *column.Nullable.Value {
					r.write(prefix, " DROP NOT NULL;\n")
				} else {
					r.write(prefix, " SET NOT NULL;\n")
				}
			}
			if !reflect.DeepEqual(column.Default, old.Default) {
				if column.Default.Value == nil {
					return manual("Column default is unknown.")
				}
				if column.Default.Value.Kind == "none" {
					r.write(prefix, " DROP DEFAULT;\n")
				} else {
					r.write(prefix, " SET")
					r.defaultSQL(*column.Default.Value)
					r.write(";\n")
				}
			}
			if !reflect.DeepEqual(column.Comment, old.Comment) {
				r.write("COMMENT ON COLUMN ", r.ref(table.Ref), ".", r.name(column.Ref.Name), " IS ")
				if column.Comment.Value == nil {
					r.write("NULL")
				} else {
					r.write(r.literal(*column.Comment.Value))
				}
				r.write(";\n")
			}
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
			var backing *sc.Index
			for i := range table.Indexes.Items {
				index := &table.Indexes.Items[i]
				if index.Constraint.Value != nil && *index.Constraint.Value == constraint.Ref {
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
				if !synchronizationConstraintBacking(constraint, *backing, table) {
					return manual("Noncanonical constraint backing-index keys require manual SQL to preserve ordering, collation and operator classes.")
				}
			}
			if constraint.Enforced.Value == nil || !*constraint.Enforced.Value {
				return manual("Constraint enforcement requires a target-version-specific manual migration.")
			}
			r.write("ALTER TABLE ", r.ref(table.Ref), " ADD ")
			r.constraint(constraint, backing, false)
			if constraint.Validated.Value != nil && !*constraint.Validated.Value {
				if *constraint.Kind.Value != "f" {
					return manual("Unvalidated primary/unique constraints require manual SQL.")
				}
				r.write(" NOT VALID")
			}
			r.write(";\n")
			return finish()
		}
	}
	if op.Action == "create" && op.Ref.Kind == "index" {
		for _, index := range table.Indexes.Items {
			if index.Ref == op.Ref {
				if reason := syncplan.SchemaFactsReason(index); reason != "" {
					return manual(reason)
				}
				if index.Constraint.Value != nil {
					return manual("Constraint-backed indexes are generated with their owning constraint.")
				}
				r.index(index, table.Ref)
				return finish()
			}
		}
	}
	return manual("This PostgreSQL transformation requires manual SQL; existing objects are not automatically replaced.")
}

func synchronizationConstraintBacking(constraint sc.Constraint, index sc.Index, table sc.Table) bool {
	if index.Method.Value == nil || *index.Method.Value != "btree" || index.Unique.Value == nil || !*index.Unique.Value || index.Predicate.Value != nil || len(index.Keys.Items) != len(constraint.Columns.Items) {
		return false
	}
	for i, key := range index.Keys.Items {
		if key.Column.Value == nil || *key.Column.Value != constraint.Columns.Items[i] || key.Expression.Value != nil || key.Descending.Value == nil || *key.Descending.Value || key.NullsFirst.Value == nil || *key.NullsFirst.Value || key.PrefixLength.Value != nil || len(key.Options.Items) != 0 {
			return false
		}
		var column *sc.Column
		for j := range table.Columns.Items {
			if table.Columns.Items[j].Ref == *key.Column.Value {
				column = &table.Columns.Items[j]
			}
		}
		if column == nil || column.Type.Value == nil || !reflect.DeepEqual(column.Collation, key.Collation) {
			return false
		}
		u := *column.Type.Value
		expected := ""
		if u.Kind == "array" {
			expected = "array_ops"
		} else if u.Kind == "e" {
			expected = "enum_ops"
		} else if u.Ref.Schema == "pg_catalog" {
			expected = map[string]string{"int2": "int2_ops", "int4": "int4_ops", "int8": "int8_ops", "text": "text_ops", "varchar": "text_ops", "bpchar": "bpchar_ops", "numeric": "numeric_ops", "bool": "bool_ops", "float4": "float4_ops", "float8": "float8_ops", "bytea": "bytea_ops", "date": "date_ops", "timestamp": "timestamp_ops", "timestamptz": "timestamptz_ops", "time": "time_ops", "timetz": "timetz_ops", "interval": "interval_ops", "uuid": "uuid_ops", "oid": "oid_ops", "inet": "inet_ops", "cidr": "inet_ops", "jsonb": "jsonb_ops", "name": "name_ops"}[u.Ref.Name]
		}
		if expected == "" || key.Opclass.Value == nil || key.Opclass.Value.Schema != "pg_catalog" || key.Opclass.Value.Name != expected {
			return false
		}
	}
	return true
}
