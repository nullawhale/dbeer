package tableedit

import (
	sc "dbeer/helper/internal/schemacompare"
	"errors"
	"strings"
)

type Operation struct {
	Kind   string
	Name   *string
	Column *Column
	Change *ColumnChange
	Index  *IndexEdit
	Key    *KeyEdit
}

func PlanOperations(b Baseline, d Draft, engine string, load func(Target) (Baseline, error)) ([]Operation, []Baseline, error) {
	return planOperations(b, d, engine, load, false)
}
func PlanMigrationOperations(b Baseline, d Draft, engine string, load func(Target) (Baseline, error)) ([]Operation, []Baseline, error) {
	return planOperations(b, d, engine, load, true)
}
func planOperations(b Baseline, d Draft, engine string, load func(Target) (Baseline, error), migration bool) ([]Operation, []Baseline, error) {
	if err := d.ValidateForEngine(engine); err != nil {
		return nil, nil, err
	}
	if d.NeedsAuthoringV4() && engine != "postgresql" && engine != "mysql" && engine != "mariadb" {
		return nil, nil, errors.New("Destructive authoring is supported for the guarded PostgreSQL, MySQL and MariaDB table subsets; SQLite DROP and type/encoding conversion require the separately reviewed reconstruction workflow.")
	}
	if d.DropTable {
		if b.Target.Create {
			return nil, nil, ErrInvalid
		}
		if err := CheckDropTable(b); err != nil {
			return nil, nil, err
		}
		return []Operation{{Kind: "dropTable"}}, nil, nil
	}
	if b.Target.Create && len(d.Columns) == 0 || b.Target.Create && len(d.Changes) > 0 || b.Target.Create && d.RenameTable != nil {
		return nil, nil, ErrInvalid
	}
	if !b.Target.Create && (b.Facts == nil || (len(d.Changes)+len(d.Indexes)+len(d.Keys) > 0 && (!b.Facts.Table.Columns.Complete || !b.Facts.Table.Constraints.Complete || !b.Facts.Table.Indexes.Complete))) {
		return nil, nil, ErrUnsupported
	}
	if !b.Target.Create {
		if len(b.Columns)+len(d.Columns) > MaxColumns {
			return nil, nil, ErrInvalid
		}
		for _, c := range d.Columns {
			if !c.Nullable {
				return nil, nil, ErrUnsupported
			}
			for _, old := range b.Columns {
				if old.Name == c.Name || (engine == "mysql" || engine == "mariadb") && strings.EqualFold(old.Name, c.Name) {
					return nil, nil, ErrInvalid
				}
			}
		}
	}
	source := PlanningSource(b, d, engine)
	var ops []Operation
	var refs []Baseline
	finalNames := map[string]bool{}
	for _, old := range b.Columns {
		name := old.Name
		for _, c := range d.Changes {
			if c.Name == old.Name && c.Drop {
				name = ""
			}
			if c.Name == old.Name && c.RenameTo != nil {
				name = *c.RenameTo
			}
		}
		if name == "" {
			continue
		}
		key := name
		if engine == "mysql" || engine == "mariadb" {
			key = strings.ToLower(key)
		}
		if finalNames[key] {
			return nil, nil, ErrInvalid
		}
		finalNames[key] = true
	}
	for _, c := range d.Columns {
		key := c.Name
		if engine == "mysql" || engine == "mariadb" {
			key = strings.ToLower(key)
		}
		if finalNames[key] {
			return nil, nil, ErrInvalid
		}
		finalNames[key] = true
	}
	if d.RenameTable != nil {
		if *d.RenameTable == b.Target.Table {
			return nil, nil, ErrInvalid
		}
		if err := CheckRename(b, ""); err != nil {
			return nil, nil, err
		}
		if _, err := load(Target{Schema: b.Target.Schema, Table: *d.RenameTable, Create: true}); err != nil {
			return nil, nil, errors.New("The rename destination must be a verified absent table in the current schema.")
		}
	}
	renaming := d.RenameTable != nil
	for _, c := range d.Changes {
		renaming = renaming || c.RenameTo != nil
	}
	if renaming && b.Facts != nil {
		for _, incoming := range b.Facts.Incoming {
			if incoming.Schema == b.Target.Schema && incoming.Table == b.Target.Table {
				continue
			}
			exists := false
			for _, r := range refs {
				if r.Target.Schema == incoming.Schema && r.Target.Table == incoming.Table {
					exists = true
				}
			}
			if exists {
				continue
			}
			if len(refs) >= 16 {
				return nil, nil, ErrUnsupported
			}
			r, err := load(Target{Schema: incoming.Schema, Table: incoming.Table})
			if err != nil {
				return nil, nil, err
			}
			refs = append(refs, r)
		}
	}

	for i := range d.Changes {
		c := &d.Changes[i]
		if c.Drop {
			if err := CheckDropColumn(b, d, c.Name); err != nil {
				return nil, nil, err
			}
			continue
		}
		if c.RenameTo != nil {
			for _, old := range b.Columns {
				if old.Name != c.Name && (old.Name == *c.RenameTo || (engine == "mysql" || engine == "mariadb") && strings.EqualFold(old.Name, *c.RenameTo)) {
					return nil, nil, errors.New("Rename destinations must be unoccupied; rename occupied columns in a separate reviewed operation.")
				}
			}
			if err := CheckRename(b, c.Name); err != nil {
				return nil, nil, err
			}
		}
		if c.Nullable == nil && c.Default == nil && c.Type == nil && c.Generated == nil && c.Identity == nil && c.Unsigned == nil && c.Charset == nil && c.Collation == nil {
			continue
		}
		if c.Type != nil && !CanWidenColumn(b, *c) && d.AuthoringVersion != 4 {
			return nil, nil, errors.New("Narrowing or conversion requires destructive authoring version 4.")
		}
		if d.AuthoringVersion == 4 && c.Conversion() {
			if err := CheckConversion(b, *c); err != nil {
				return nil, nil, err
			}
		}
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
			if engine == "mysql" || engine == "mariadb" {
				for _, k := range b.Keys {
					if k.Kind != "foreign" || dropKeys[k.Name] {
						continue
					}
					for _, old := range b.Indexes {
						if old.Name == x.Name && SupportingIndex(old, k.Columns) {
							alternative := false
							for _, other := range b.Indexes {
								if other.Name != x.Name && SupportingIndex(other, k.Columns) {
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
		c := d.Changes[i]
		if c.Drop {
			ops = append(ops, Operation{Kind: "dropColumn", Change: &c})
			continue
		}
		c.RenameTo = nil
		if c.Nullable != nil || c.Default != nil || c.Type != nil || c.Generated != nil || c.Identity != nil || c.Unsigned != nil || c.Charset != nil || c.Collation != nil {
			ops = append(ops, Operation{Kind: "changeColumn", Change: &c})
		}
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
			for _, c := range d.Changes {
				if c.Name == name && c.Drop {
					return false
				}
			}
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
		if (engine == "mysql" || engine == "mariadb") && k.Kind == "primary" && k.Name != "PRIMARY" {
			return nil, nil, errors.New("MySQL and MariaDB primary keys use the name PRIMARY.")
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
		if (engine == "mysql" || engine == "mariadb") && x.Unique {
			return nil, nil, errors.New("Use a Unique Key operation for native uniqueness so the constraint and backing index remain one unit.")
		}
		if x.Action == "drop" {
			continue
		}
		if x.Definition != nil {
			if engine != "postgresql" && engine != "mysql" && engine != "mariadb" {
				return nil, nil, errors.New("Advanced index definitions are not supported by this adapter.")
			}
			for _, term := range x.Definition.Terms {
				if term.Column != nil && !existsColumn([]string{*term.Column}) {
					return nil, nil, ErrInvalid
				}
			}
			if !existsColumn(x.Definition.Includes) {
				return nil, nil, ErrInvalid
			}
		} else if !existsColumn(x.Columns) {
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
		source.Indexes = append(source.Indexes, Index{Name: x.Name, Columns: x.Columns, Unique: x.Unique, Supported: true, Definition: x.Definition})
	}
	for i := range d.Keys {
		k := &d.Keys[i]
		if k.Kind != "foreign" || k.Action == "drop" {
			continue
		}
		if (engine == "mysql" || engine == "mariadb") && k.Reference.Schema != b.Target.Schema && !migration {
			return nil, nil, errors.New("Foreign-key authoring is limited to the selected database.")
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
		if engine == "mysql" || engine == "mariadb" {
			support := false
			for _, x := range source.Indexes {
				if SupportingIndex(x, k.Columns) {
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
	for i := range d.Changes {
		if d.Changes[i].RenameTo != nil {
			ops = append(ops, Operation{Kind: "renameColumn", Change: &d.Changes[i]})
		}
	}
	if d.RenameTable != nil {
		ops = append(ops, Operation{Kind: "renameTable", Name: d.RenameTable})
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
