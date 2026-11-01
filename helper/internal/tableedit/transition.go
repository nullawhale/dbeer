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
	checkNew := func(column Column) bool {
		actual, ok := FindColumn(after, column.Name)
		if !ok || actual.Nullable.Value == nil || *actual.Nullable.Value != column.Nullable {
			return false
		}
		typ, ok := ColumnType(actual)
		expected := PlanningSource(before, Draft{Columns: []Column{column}}, after.Engine)
		wanted, exists := FindColumn(expected, column.Name)
		if !exists || !ok || typ != column.Type || actual.Type.Value == nil || !reflect.DeepEqual(*actual.Type.Value, ExpectedNewType(after.Engine, column.Type)) || !defaultMatches(actual, column.Default) {
			return false
		}
		if actual.Generated.Value == nil || actual.Generated.Value.Kind != "none" || actual.Identity.Value == nil || actual.Identity.Value.Kind != "none" || actual.Visible.Value == nil || !*actual.Visible.Value || actual.Comment.Value == nil || *actual.Comment.Value != "" || actual.OnUpdate.Value != nil || !reflect.DeepEqual(actual.Charset, wanted.Charset) || !reflect.DeepEqual(actual.Collation, wanted.Collation) || !reflect.DeepEqual(actual.CollationProperties, wanted.CollationProperties) {
			return false
		}
		if after.Engine == "postgresql" {
			attrs := after.Attributes[column.Name]
			storage := ""
			if before.Facts != nil {
				storage = before.Facts.TypeStorage[column.Type.Kind]
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
					if change.Type != nil {
						col.Type = sc.Fact[sc.TypeUse]{}
					}
					if change.Nullable != nil {
						col.Nullable = sc.Fact[bool]{}
						if col.Default.Value != nil && (col.Default.Value.Kind == "none" || col.Default.Value.Kind == "sqlNull") {
							col.Default = sc.Known(sc.Default{Kind: "none"})
						}
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
					for _, k := range []string{"atttypid", "attlen", "atttypmod", "attbyval", "attalign"} {
						delete(attrs[name], k)
					}
				}
				if change.Nullable != nil {
					delete(attrs[name], "attnotnull")
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
		stripColumn(op.Column.Name, true, nil)
	case "changeColumn":
		change := op.Change
		actual, ok := FindColumn(after, change.Name)
		if !ok {
			return false
		}
		if change.Type != nil {
			typ, ok := ColumnType(actual)
			old, exists := FindColumn(before, change.Name)
			if !ok || typ != *change.Type || !exists || old.Type.Value == nil || actual.Type.Value == nil || actual.Type.State != old.Type.State || !reflect.DeepEqual(*actual.Type.Value, ExpectedWidenType(before.Engine, *old.Type.Value, *change.Type)) {
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
			if x.Name == op.Index.Name && x.Supported && x.Owner == "" && x.Unique == op.Index.Unique && reflect.DeepEqual(x.Columns, op.Index.Columns) {
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
