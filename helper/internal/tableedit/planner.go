package tableedit

import (
	sc "dbeer/helper/internal/schemacompare"
	"errors"
	"strings"
)

type Operation struct {
	Kind   string
	Column *Column
	Change *ColumnChange
	Index  *IndexEdit
	Key    *KeyEdit
}

func PlanOperations(b Baseline, d Draft, engine string, load func(Target) (Baseline, error)) ([]Operation, []Baseline, error) {
	if err := d.Validate(); err != nil {
		return nil, nil, err
	}
	if b.Target.Create && len(d.Columns) == 0 || b.Target.Create && len(d.Changes) > 0 || !b.Target.Create && len(d.Columns) > 1 {
		return nil, nil, ErrInvalid
	}
	if !b.Target.Create && (b.Facts == nil || (len(d.Changes)+len(d.Indexes)+len(d.Keys) > 0 && (!b.Facts.Table.Columns.Complete || !b.Facts.Table.Constraints.Complete || !b.Facts.Table.Indexes.Complete))) {
		return nil, nil, ErrUnsupported
	}
	if !b.Target.Create {
		for _, c := range d.Columns {
			if !c.Nullable {
				return nil, nil, ErrUnsupported
			}
			for _, old := range b.Columns {
				if old.Name == c.Name || engine == "mysql" && strings.EqualFold(old.Name, c.Name) {
					return nil, nil, ErrInvalid
				}
			}
		}
	}
	source := PlanningSource(b, d, engine)
	var ops []Operation
	var refs []Baseline
	for i := range d.Changes {
		c := &d.Changes[i]
		if err := CheckChange(b, *c); err != nil {
			return nil, nil, err
		}
	}
	dropKeys := map[string]bool{}
	for i := range d.Keys {
		k := &d.Keys[i]
		if k.Action != "add" {
			found := false
			for _, old := range b.Keys {
				if old.Name == k.Name && old.Kind == k.Kind {
					found = true
				}
			}
			if !found {
				return nil, nil, ErrInvalid
			}
			if err := CheckRemoval(b, d, k.Name, true); err != nil {
				return nil, nil, err
			}
			dropKeys[k.Name] = true
			if k.Kind == "foreign" {
				ops = append(ops, Operation{Kind: "dropKey", Key: k})
			}
		}
	}
	for i := range d.Indexes {
		x := &d.Indexes[i]
		if x.Action != "add" {
			if err := CheckRemoval(b, d, x.Name, false); err != nil {
				return nil, nil, err
			}
			if engine == "mysql" {
				for _, k := range b.Keys {
					if k.Kind != "foreign" || dropKeys[k.Name] {
						continue
					}
					for _, old := range b.Indexes {
						if old.Name == x.Name && prefix(old.Columns, k.Columns) {
							alternative := false
							for _, other := range b.Indexes {
								if other.Name != x.Name && prefix(other.Columns, k.Columns) {
									alternative = true
								}
							}
							if !alternative {
								return nil, nil, errors.New("Remove the dependent foreign key explicitly before replacing its only supporting index.")
							}
						}
					}
				}
			}
			ops = append(ops, Operation{Kind: "dropIndex", Index: x})
		}
	}
	for i := range d.Keys {
		k := &d.Keys[i]
		if k.Action != "add" && k.Kind != "foreign" {
			ops = append(ops, Operation{Kind: "dropKey", Key: k})
		}
	}
	if b.Target.Create {
		ops = append(ops, Operation{Kind: "create"})
	} else {
		for i := range d.Columns {
			ops = append(ops, Operation{Kind: "addColumn", Column: &d.Columns[i]})
		}
	}
	for i := range d.Changes {
		ops = append(ops, Operation{Kind: "changeColumn", Change: &d.Changes[i]})
	}
	keys := []Key{}
	for _, k := range source.Keys {
		if !dropKeys[k.Name] {
			keys = append(keys, k)
		}
	}
	source.Keys = keys
	activeIndexes := []Index{}
	for _, x := range source.Indexes {
		remove := dropKeys[x.Owner] && x.Owner != ""
		for _, edit := range d.Indexes {
			if edit.Name == x.Name && edit.Action != "add" {
				remove = true
			}
		}
		if !remove {
			activeIndexes = append(activeIndexes, x)
		}
	}
	source.Indexes = activeIndexes

	existsColumn := func(names []string) bool {
		for _, name := range names {
			if _, ok := FindColumn(source, name); !ok {
				return false
			}
		}
		return true
	}
	for i := range d.Keys {
		k := &d.Keys[i]
		if k.Action == "drop" {
			continue
		}
		if engine == "mysql" && k.Kind == "primary" && k.Name != "PRIMARY" {
			return nil, nil, errors.New("MySQL primary keys use the name PRIMARY.")
		}
		for _, old := range source.Keys {
			if old.Name == k.Name || old.Kind == "primary" && k.Kind == "primary" {
				return nil, nil, ErrInvalid
			}
		}
		if !existsColumn(k.Columns) {
			return nil, nil, ErrInvalid
		}
		source.Keys = append(source.Keys, Key{Kind: k.Kind, Name: k.Name, Columns: k.Columns, Reference: k.Reference, ReferenceColumns: k.ReferenceColumns, OnDelete: k.OnDelete, OnUpdate: k.OnUpdate, Supported: true})
		if k.Kind == "primary" {
			for _, name := range k.Columns {
				for j := range source.Facts.Table.Columns.Items {
					if source.Facts.Table.Columns.Items[j].Ref.Name == name {
						source.Facts.Table.Columns.Items[j].Nullable = sc.Known(false)
					}
				}
			}
		}
		if k.Kind != "foreign" {
			ops = append(ops, Operation{Kind: "addKey", Key: k})
			source.Indexes = append(source.Indexes, Index{Name: k.Name, Columns: k.Columns, Unique: true, Supported: true, Owner: k.Name})
		}
	}
	for i := range d.Indexes {
		x := &d.Indexes[i]
		if engine == "mysql" && x.Unique {
			return nil, nil, errors.New("Use a Unique Key operation for MySQL uniqueness so the constraint and backing index remain one unit.")
		}
		if x.Action == "drop" {
			continue
		}
		if !existsColumn(x.Columns) {
			return nil, nil, ErrInvalid
		}
		for _, old := range b.Indexes {
			if old.Name == x.Name && x.Action == "add" {
				return nil, nil, ErrInvalid
			}
		}
		for _, key := range source.Keys {
			if key.Name == x.Name {
				return nil, nil, ErrInvalid
			}
		}
		ops = append(ops, Operation{Kind: "addIndex", Index: x})
		source.Indexes = append(source.Indexes, Index{Name: x.Name, Columns: x.Columns, Unique: x.Unique, Supported: true})
	}
	for i := range d.Keys {
		k := &d.Keys[i]
		if k.Kind != "foreign" || k.Action == "drop" {
			continue
		}
		if engine == "mysql" && k.Reference.Schema != b.Target.Schema {
			return nil, nil, errors.New("Foreign-key authoring is limited to the selected MySQL database.")
		}
		target := source
		if k.Reference.Schema != b.Target.Schema || k.Reference.Table != b.Target.Table {
			var err error
			found := false
			for _, r := range refs {
				if r.Target.Schema == k.Reference.Schema && r.Target.Table == k.Reference.Table {
					target = r
					found = true
				}
			}
			if !found {
				if len(refs) >= 16 {
					return nil, nil, ErrInvalid
				}
				target, err = load(*k.Reference)
				if err != nil {
					return nil, nil, err
				}
				refs = append(refs, target)
			}
		}
		if err := ValidateForeign(source, *k, target); err != nil {
			return nil, nil, err
		}
		if engine == "mysql" {
			support := false
			for _, x := range source.Indexes {
				if x.Supported && prefix(x.Columns, k.Columns) {
					support = true
				}
			}
			if !support {
				name := "fk_" + Fingerprint([]any{k.Name, k.Columns})[:24]
				x := &IndexEdit{Action: "add", Name: name, Columns: k.Columns}
				ops = append(ops, Operation{Kind: "addIndex", Index: x})
				source.Indexes = append(source.Indexes, Index{Name: name, Columns: k.Columns, Supported: true})
			}
		}
		ops = append(ops, Operation{Kind: "addKey", Key: k})
	}
	return ops, refs, nil
}
func prefix(have, want []string) bool {
	if len(have) < len(want) {
		return false
	}
	for i, n := range want {
		if have[i] != n {
			return false
		}
	}
	return true
}
