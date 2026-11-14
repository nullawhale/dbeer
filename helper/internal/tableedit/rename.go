package tableedit

import (
	"errors"
	"reflect"
	"sort"

	sc "dbeer/helper/internal/schemacompare"
)

func CheckRename(b Baseline, column string) error {
	if b.Target.Create || b.Facts == nil || !b.Facts.Proof || !b.Facts.Table.Columns.Complete || !b.Facts.Table.Constraints.Complete || !b.Facts.Table.Indexes.Complete || len(b.Facts.Dependents[""]) > 0 || column != "" && len(b.Facts.Dependents[column]) > 0 {
		return errors.New("Renaming requires complete dependency evidence. Views, routines and triggers needing explicit repairs must be handled in a reviewed migration.")
	}
	if column == "" {
		for _, d := range b.Facts.Dependents {
			if len(d) > 0 {
				return errors.New("Table rename requires explicit repair of its external expression dependencies.")
			}
		}
	}
	if column != "" {
		if _, ok := FindColumn(b, column); !ok {
			return ErrInvalid
		}

		depends := func(e *sc.Expression) bool {
			if e == nil {
				return false
			}
			if !e.Dependencies.Complete {
				if (b.Engine == "mysql" || b.Engine == "mariadb") && MySQLExpressionExcludesColumn(e.Text, column, b.Facts) {
					return false
				}
				return true
			}
			for _, r := range e.Dependencies.Items {
				if r.Kind == "column" && r.Schema == b.Target.Schema && r.Table == b.Target.Table && r.Name == column {
					return true
				}
			}
			return false
		}
		for _, c := range b.Facts.Table.Columns.Items {
			if c.Generated.Value != nil && depends(c.Generated.Value.Expression) || c.Default.Value != nil && depends(c.Default.Value.Expression) {
				return errors.New("Rename requires an explicit repair of dependent or unproven column expressions.")
			}
		}
		for _, x := range b.Facts.Table.Indexes.Items {
			for _, k := range x.Keys.Items {
				if k.Expression.Value != nil && depends(k.Expression.Value) {
					return errors.New("Rename with a dependent expression index requires an explicit dependency repair.")
				}
			}
		}
		for _, k := range b.Facts.Table.Constraints.Items {
			if k.Check.Value != nil && depends(k.Check.Value) {
				return errors.New("Rename with a dependent CHECK expression requires an explicit dependency repair.")
			}
		}

	}
	return nil
}

// Rewrite only typed catalog references. SQL expression strings are never rewritten.
func renameFacts(f *Facts, target Target, column, name string) {
	refType := reflect.TypeOf(sc.Ref{})
	var walk func(reflect.Value)
	walk = func(v reflect.Value) {
		if !v.IsValid() {
			return
		}
		if v.Kind() == reflect.Pointer {
			if !v.IsNil() {
				walk(v.Elem())
			}
			return
		}
		if v.Type() == refType && v.CanSet() {
			r := v.Interface().(sc.Ref)
			if r.Schema == target.Schema {
				if column != "" {
					if r.Kind == "column" && r.Table == target.Table && r.Name == column {
						r.Name = name
					}
				} else {
					if r.Table == target.Table {
						r.Table = name
					}
					if (r.Kind == "table" || r.Kind == "type" && r.RowType) && r.Name == target.Table {
						r.Name = name
					}
				}
			}
			v.Set(reflect.ValueOf(r))
			return
		}
		switch v.Kind() {
		case reflect.Struct:
			for i := 0; i < v.NumField(); i++ {
				walk(v.Field(i))
			}
		case reflect.Slice:
			for i := 0; i < v.Len(); i++ {
				walk(v.Index(i))
			}
		}
	}
	walk(reflect.ValueOf(f))
	for i := range f.Incoming {
		x := &f.Incoming[i]
		if column != "" && f.Table.Ref.Schema == target.Schema && f.Table.Ref.Name == target.Table {
			for j, n := range x.Columns {
				if n == column {
					x.Columns[j] = name
				}
			}
		} else if column == "" && x.Schema == target.Schema && x.Table == target.Table {
			x.Table = name
		}
	}
	if column != "" {
		if d, ok := f.Dependents[column]; ok {
			delete(f.Dependents, column)
			f.Dependents[name] = d
		}
	}
}

func verifyRename(before, after Baseline, c Condition) bool {
	if before.Facts == nil || after.Facts == nil || before.Identity != after.Identity || before.Scope != after.Scope || before.Guard != after.Guard {
		return false
	}
	a, b := cloneFacts(before.Facts), cloneFacts(after.Facts)
	attrs := copyAttrs(before.Attributes)
	switch c.Operation.Kind {
	case "renameTable":
		if c.Operation.Name == nil || after.Target.Table != *c.Operation.Name || after.Target.Schema != before.Target.Schema {
			return false
		}
		renameFacts(a, before.Target, "", *c.Operation.Name)
	case "renameColumn":
		x := c.Operation.Change
		if x == nil || x.RenameTo == nil || after.Target != before.Target {
			return false
		}
		if _, exists := FindColumn(after, x.Name); exists {
			return false
		}
		if _, exists := FindColumn(after, *x.RenameTo); !exists {
			return false
		}
		renameFacts(a, before.Target, x.Name, *x.RenameTo)
		if value, ok := attrs[x.Name]; ok {
			delete(attrs, x.Name)
			attrs[*x.RenameTo] = value
			if _, exists := value["attname"]; exists {
				value["attname"] = *x.RenameTo
			}
		}
	default:
		return false
	}
	sortRenameDependencies(a)
	sortRenameDependencies(b)
	return reflect.DeepEqual(a, b) && reflect.DeepEqual(attrs, after.Attributes)
}

func sortRenameDependencies(f *Facts) {
	sort.Slice(f.Table.Dependencies.Items, func(i, j int) bool {
		return Fingerprint(f.Table.Dependencies.Items[i]) < Fingerprint(f.Table.Dependencies.Items[j])
	})
}
