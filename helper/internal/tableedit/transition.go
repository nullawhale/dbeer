package tableedit

import (
	sc "dbeer/helper/internal/schemacompare"
	"encoding/json"
	"reflect"
)

type Condition struct {
	Operation Operation
	Columns   []Column
}

func cloneFacts(f *Facts) *Facts {
	if f == nil {
		return nil
	}
	raw, _ := json.Marshal(f)
	var out Facts
	_ = json.Unmarshal(raw, &out)
	return &out
}
func copyAttrs(in map[string]map[string]any) map[string]map[string]any {
	if in == nil {
		return nil
	}
	b, _ := json.Marshal(in)
	var out map[string]map[string]any
	_ = json.Unmarshal(b, &out)
	return out
}
func VerifyTransition(before, after Baseline, c Condition, defaultMatches func(sc.Column, Default) bool) bool {
	if after.Facts == nil || before.Scope != after.Scope {
		return false
	}
	op := c.Operation
	if op.Kind == "renameColumn" || op.Kind == "renameTable" {
		return verifyRename(before, after, c)
	}
	checkNew := func(column Column) bool {
		actual, ok := FindColumn(after, column.Name)
		if !ok || actual.Nullable.Value == nil || *actual.Nullable.Value != column.Nullable {
			return false
		}
		typ, ok := ColumnType(actual)
		expected := PlanningSource(before, Draft{Columns: []Column{column}}, after.Engine)
		wanted, exists := FindColumn(expected, column.Name)
		if !exists || column.Type.Kind != "reference" && (!ok || !SameDataType(typ, column.Type)) || actual.Type.Value == nil || !reflect.DeepEqual(*actual.Type.Value, ExpectedColumnType(after.Engine, column)) || !authoredDefaultMatches(after.Engine, actual, column, defaultMatches) {
			return false
		}
		if !generatedMatches(after.Engine, after.Facts, actual, column.Generated) || !identityMatches(after.Engine, after.Facts, actual, column.Identity, nil) || actual.Visible.Value == nil || !*actual.Visible.Value || actual.Comment.Value == nil || *actual.Comment.Value != "" || actual.OnUpdate.Value != nil || !reflect.DeepEqual(actual.Charset, wanted.Charset) || !reflect.DeepEqual(actual.Collation, wanted.Collation) || !reflect.DeepEqual(actual.CollationProperties, wanted.CollationProperties) {
			return false
		}
		if after.Engine == "postgresql" {
			attrs := after.Attributes[column.Name]
			storage := ""
			if before.Facts != nil {
				storage = before.Facts.TypeStorage[column.Type.Kind]
				if column.Resolved != nil {
					storage = column.Resolved.Storage
				}
			}
			if storage == "" {
				return false
			}
			if attrs["attstorage"] != storage || attrs["attcompression"] != "" || attrs["attacl"] != nil || attrs["attoptions"] != nil || attrs["attfdwoptions"] != nil || (attrs["attstattarget"] != nil && attrs["attstattarget"] != float64(-1)) || attrs["attndims"] != float64(0) || attrs["attinhcount"] != float64(0) || attrs["attislocal"] != true {
				return false
			}
		}
		return true
	}
	if op.Kind == "create" {
		if len(after.Facts.Table.Columns.Items) != len(c.Columns) {
			return false
		}
		for _, col := range c.Columns {
			if !checkNew(col) {
				return false
			}
		}
		return len(after.Indexes) == 0 && len(after.Keys) == 0
	}
	if before.Facts == nil || before.Identity != after.Identity || before.Guard != after.Guard || before.Facts.Proof != after.Facts.Proof || !reflect.DeepEqual(before.Facts.EngineContext, after.Facts.EngineContext) || !reflect.DeepEqual(before.Facts.Dependents, after.Facts.Dependents) {
		return false
	}
	a, b := cloneFacts(before.Facts), cloneFacts(after.Facts)
	attrsA, attrsB := copyAttrs(before.Attributes), copyAttrs(after.Attributes)
	stripColumn := func(name string, remove bool, change *ColumnChange) {
		for _, f := range []*Facts{a, b} {
			out := []sc.Column{}
			for _, col := range f.Table.Columns.Items {
				if col.Ref.Name != name {
					out = append(out, col)
					continue
				}
				if remove {
					continue
				}
				if change != nil {
					if change.Type != nil || change.Unsigned != nil {
						col.Type = sc.Fact[sc.TypeUse]{}
					}
					if change.Charset != nil || change.Type != nil && before.Engine == "mysql" && change.Type.Kind != "text" && change.Type.Kind != "varchar" {
						col.Charset = sc.Fact[string]{}
					}
					if change.Collation != nil || change.Type != nil && (before.Engine == "postgresql" || before.Engine == "mysql" && change.Type.Kind != "text" && change.Type.Kind != "varchar") {
						col.Collation = sc.Fact[sc.Ref]{}
						col.CollationProperties = nil
					}
					if change.Nullable != nil {
						col.Nullable = sc.Fact[bool]{}
						if col.Default.Value != nil && (col.Default.Value.Kind == "none" || col.Default.Value.Kind == "sqlNull") {
							col.Default = sc.Known(sc.Default{Kind: "none"})
						}
					}
					if change.Generated != nil {
						if before.Engine == "mysql" && col.Default.Value != nil && (col.Default.Value.Kind == "none" || col.Default.Value.Kind == "sqlNull") {
							col.Default = sc.Known(sc.Default{Kind: "none"})
						}
						col.Generated = sc.Fact[sc.Generated]{}
					}
					if change.Identity != nil {
						col.Identity = sc.Fact[sc.Identity]{}
					}
					if change.Default != nil {
						col.Default = sc.Fact[sc.Default]{}
					}
				}
				out = append(out, col)
			}
			f.Table.Columns.Items = out
		}
		if remove {
			delete(attrsA, name)
			delete(attrsB, name)
		} else if change != nil {
			for _, attrs := range []map[string]map[string]any{attrsA, attrsB} {
				if change.Type != nil {
					for _, k := range []string{"atttypid", "attlen", "atttypmod", "attbyval", "attalign", "attstorage", "attcompression"} {
						delete(attrs[name], k)
					}
				}
				if change.Collation != nil || change.Type != nil {
					delete(attrs[name], "attcollation")
				}
				if change.Nullable != nil {
					delete(attrs[name], "attnotnull")
				}
				if change.Generated != nil {
					delete(attrs[name], "attgenerated")
					delete(attrs[name], "atthasdef")
				}
				if change.Identity != nil {
					delete(attrs[name], "attidentity")
				}
				if change.Default != nil {
					delete(attrs[name], "atthasdef")
				}
			}
		}
	}
	stripIndex := func(name, owner string) {
		for _, f := range []*Facts{a, b} {
			out := []sc.Index{}
			for _, x := range f.Table.Indexes.Items {
				if x.Ref.Name == name || owner != "" && x.Constraint.Value != nil && x.Constraint.Value.Name == owner {
					delete(f.IndexDefaultOpclasses, x.Ref.Name)
					delete(f.IndexDefaultCollations, x.Ref.Name)
					delete(f.IndexAttributes, x.Ref.Name)
					if len(f.IndexAttributes) == 0 {
						f.IndexAttributes = nil
					}
					delete(f.IndexBuiltinFunctions, x.Ref.Name)
					if len(f.IndexBuiltinFunctions) == 0 {
						f.IndexBuiltinFunctions = nil
					}
					if len(f.IndexDefaultCollations) == 0 {
						f.IndexDefaultCollations = nil
					}
					delete(f.IndexCatalogGuards, x.Ref.Name)
					if len(f.IndexCatalogGuards) == 0 {
						f.IndexCatalogGuards = nil
					}
					if len(f.IndexDefaultOpclasses) == 0 {
						f.IndexDefaultOpclasses = nil
					}
					continue
				}
				out = append(out, x)
			}
			f.Table.Indexes.Items = out
		}
	}
	stripKey := func(name string) {
		for _, f := range []*Facts{a, b} {
			out := []sc.Constraint{}
			for _, k := range f.Table.Constraints.Items {
				if k.Ref.Name == name || k.Kind.Value != nil && *k.Kind.Value == "n" {
					continue
				}
				out = append(out, k)
			}
			f.Table.Constraints.Items = out
			incoming := []Incoming{}
			for _, x := range f.Incoming {
				if x.Schema == before.Target.Schema && x.Table == before.Target.Table && x.Name == name {
					continue
				}
				incoming = append(incoming, x)
			}
			f.Incoming = incoming
		}
	}
	switch op.Kind {
	case "addColumn":
		if !checkNew(*op.Column) || len(after.Facts.Table.Columns.Items) != len(before.Facts.Table.Columns.Items)+1 {
			return false
		}
		if !stripResolvedTypes(a, b, *op.Column) {
			return false
		}
		stripOwnedSequences(a, b, sc.Ref{Kind: "column", Schema: after.Target.Schema, Table: after.Target.Table, Name: op.Column.Name})
		stripColumn(op.Column.Name, true, nil)
	case "dropColumn":
		if op.Change == nil || !op.Change.Drop {
			return false
		}
		name := op.Change.Name
		if _, ok := FindColumn(after, name); ok || len(after.Columns) != len(before.Columns)-1 {
			return false
		}
		old, ok := FindColumn(before, name)
		if !ok {
			return false
		}
		stripOwnedSequences(a, b, old.Ref)
		if before.Engine == "postgresql" {
			number := attrsA[name]["attnum"]
			for key, attrs := range attrsB {
				if attrs["attisdropped"] == true && attrs["attnum"] == number {
					delete(attrsB, key)
				}
			}
		}
		stripColumn(name, true, nil)
		for _, f := range []*Facts{a, b} {
			for i := range f.Table.Columns.Items {
				f.Table.Columns.Items[i].Ordinal = sc.Known(i)
			}
		}
	case "changeColumn":
		change := op.Change
		actual, ok := FindColumn(after, change.Name)
		if !ok {
			return false
		}
		if change.Generated != nil && !generatedMatches(after.Engine, after.Facts, actual, change.Generated) {
			return false
		}
		if change.Identity != nil {
			owner := actual.Ref
			if !identityMatches(after.Engine, after.Facts, actual, change.Identity, sequenceFor(before.Facts, owner)) {
				return false
			}
			stripOwnedSequences(a, b, owner)
		}
		if change.Type != nil || change.Unsigned != nil {
			old, exists := FindColumn(before, change.Name)
			if !exists || old.Type.Value == nil || actual.Type.Value == nil || actual.Type.State != old.Type.State || !reflect.DeepEqual(*actual.Type.Value, ExpectedChangedType(before.Engine, *old.Type.Value, *change)) {
				return false
			}
			if (change.Type != nil || change.Collation != nil) && before.Engine == "postgresql" && len(after.Attributes[change.Name]) > 0 {
				want, _ := ColumnType(actual)
				if after.Attributes[change.Name]["attstorage"] != before.Facts.TypeStorage[want.Kind] || after.Attributes[change.Name]["attcompression"] != "" {
					return false
				}
			}
			if change.Type != nil {
				typ, ok := ColumnType(actual)
				if !ok || !SameDataType(typ, *change.Type) {
					return false
				}
			}
		}
		if before.Engine == "mysql" && change.Type != nil && change.Type.Kind != "text" && change.Type.Kind != "varchar" {
			if actual.Charset.Value != nil || actual.Charset.State != "known" || actual.Collation.Value != nil || actual.Collation.State != "known" || actual.CollationProperties != nil {
				return false
			}
		}
		if change.Charset != nil && (actual.Charset.Value == nil || *actual.Charset.Value != *change.Charset) {
			return false
		}
		if change.Collation != nil && (actual.Collation.Value == nil || actual.Collation.Value.Schema != change.Collation.Schema || actual.Collation.Value.Name != change.Collation.Name) {
			return false
		}
		if change.Type != nil && before.Engine == "postgresql" && change.Collation == nil {
			textual := change.Type.Kind == "varchar" || change.Type.Kind == "text"
			old, _ := FindColumn(before, change.Name)
			if textual {
				expected := sc.Ref{Kind: "collation", Schema: "pg_catalog", Name: "default"}
				if old.Collation.Value != nil {
					expected = *old.Collation.Value
				}
				if actual.Collation.Value == nil || *actual.Collation.Value != expected {
					return false
				}
				if old.Collation.Value != nil && !reflect.DeepEqual(old.CollationProperties, actual.CollationProperties) {
					return false
				}
			} else if actual.Collation.Value != nil || actual.CollationProperties != nil {
				return false
			}
		}

		if change.Nullable != nil && (actual.Nullable.Value == nil || *actual.Nullable.Value != *change.Nullable) {
			return false
		}
		if change.Default != nil && !defaultMatches(actual, *change.Default) {
			return false
		}
		stripColumn(change.Name, false, change)
	case "addIndex":
		found := false
		for _, x := range after.Indexes {
			if x.Name != op.Index.Name || !x.Supported || x.Owner != "" || x.Unique != op.Index.Unique {
				continue
			}
			if op.Index.Definition != nil {
				for _, fact := range after.Facts.Table.Indexes.Items {
					if fact.Ref.Name == x.Name && IndexDefinitionMatches(before, after, fact, *op.Index.Definition) {
						found = true
					}
				}
			} else if reflect.DeepEqual(x.Columns, op.Index.Columns) {
				found = true
			}
		}
		if !found {
			return false
		}
		stripIndex(op.Index.Name, "")
	case "dropIndex":
		for _, x := range after.Indexes {
			if x.Name == op.Index.Name {
				return false
			}
		}
		stripIndex(op.Index.Name, "")
	case "addKey":
		found := false
		for _, k := range after.Keys {
			if k.Name == op.Key.Name && k.Kind == op.Key.Kind && k.Supported && reflect.DeepEqual(k.Columns, op.Key.Columns) {
				if k.Kind == "foreign" && (k.Reference == nil || k.Reference.Schema != op.Key.Reference.Schema || k.Reference.Table != op.Key.Reference.Table || !reflect.DeepEqual(k.ReferenceColumns, op.Key.ReferenceColumns) || k.OnDelete != op.Key.OnDelete || k.OnUpdate != op.Key.OnUpdate) {
					continue
				}
				found = true
			}
		}
		if !found {
			return false
		}
		if op.Key.Kind == "primary" {
			for _, name := range op.Key.Columns {
				v := false
				stripColumn(name, false, &ColumnChange{Nullable: &v})
			}
		}
		stripKey(op.Key.Name)
		stripIndex("", op.Key.Name)
	case "dropKey":
		for _, k := range after.Keys {
			if k.Name == op.Key.Name {
				return false
			}
		}
		stripKey(op.Key.Name)
		stripIndex("", op.Key.Name)
	default:
		return false
	}
	// PostgreSQL 18 exposes implicit NOT NULL constraints; nullable-column facts
	// above retain their semantics without treating generated names as user edits.
	for _, f := range []*Facts{a, b} {
		out := []sc.Constraint{}
		for _, k := range f.Table.Constraints.Items {
			if k.Kind.Value != nil && *k.Kind.Value == "n" {
				continue
			}
			out = append(out, k)
		}
		f.Table.Constraints.Items = out
	}
	a.Table.Dependencies = sc.DerivedDependencies(a.Table)
	b.Table.Dependencies = sc.DerivedDependencies(b.Table)
	return reflect.DeepEqual(a, b) && reflect.DeepEqual(attrsA, attrsB)
}
func VerifyReference(before, after, source Baseline, c Condition) bool {
	if before.Facts == nil || after.Facts == nil || before.Identity != after.Identity || before.Scope != after.Scope || before.Guard != after.Guard || !reflect.DeepEqual(before.Attributes, after.Attributes) {
		return false
	}
	a, b := cloneFacts(before.Facts), cloneFacts(after.Facts)
	op := c.Operation
	if op.Kind == "renameTable" && op.Name != nil {
		renameFacts(a, source.Target, "", *op.Name)
	}
	if op.Kind == "renameColumn" && op.Change != nil && op.Change.RenameTo != nil {
		renameFacts(a, source.Target, op.Change.Name, *op.Change.RenameTo)
	}

	if op.Kind == "renameColumn" || op.Kind == "renameTable" {
		sortRenameDependencies(a)
		sortRenameDependencies(b)
	}
	if (op.Kind == "addKey" || op.Kind == "dropKey") && op.Key.Kind == "foreign" {
		for _, f := range []*Facts{a, b} {
			out := []Incoming{}
			for _, x := range f.Incoming {
				if x.Schema == source.Target.Schema && x.Table == source.Target.Table && x.Name == op.Key.Name {
					continue
				}
				out = append(out, x)
			}
			f.Incoming = out
		}
	}
	return reflect.DeepEqual(a, b)
}
