package mariadb

import (
	"context"
	"errors"
	"strings"

	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/tableedit"
)

func mariaDBIdentityDraft(b tableedit.Baseline, d tableedit.Draft) (tableedit.Draft, []tableedit.Operation, error) {
	d.Columns = append([]tableedit.Column(nil), d.Columns...)
	enable := []tableedit.Operation{}
	identities := map[string]bool{}
	if b.Facts != nil {
		for _, c := range b.Facts.Table.Columns.Items {
			if c.Identity.Value != nil && c.Identity.Value.Kind == "autoIncrement" {
				identities[c.Ref.Name] = true
			}
		}
	}
	for i := range d.Columns {
		c := &d.Columns[i]
		if c.Generated != nil && c.Generated.Storage != "none" && !c.Nullable {
			return d, nil, errors.New("MariaDB computed columns have intrinsic nullable semantics; explicit NOT NULL is not supported by native generated-column syntax.")
		}
		if c.Identity == nil || c.Identity.Kind == "none" {
			continue
		}
		if c.Identity.Kind != "autoIncrement" || c.Nullable || c.Type.Kind != "integer" && c.Type.Kind != "bigint" {
			return d, nil, tableedit.ErrUnsupported
		}
		id := *c.Identity
		if !mariaDBIdentityOptionsEmpty(id) {
			return d, nil, tableedit.ErrUnsupported
		}
		identities[c.Name] = true
		c.Identity = nil
		enable = append(enable, tableedit.Operation{Kind: "changeColumn", Change: &tableedit.ColumnChange{Name: c.Name, Identity: &id}})
	}
	for _, ch := range d.Changes {
		if ch.Identity == nil {
			continue
		}
		if !mariaDBIdentityOptionsEmpty(*ch.Identity) {
			return d, nil, tableedit.ErrUnsupported
		}
		old, ok := tableedit.FindColumn(b, ch.Name)
		if !ok || old.Nullable.Value == nil || *old.Nullable.Value || old.Default.Value == nil || old.Default.Value.Kind != "none" || old.Type.Value == nil || old.Type.Value.Ref.Name != "int" && old.Type.Value.Ref.Name != "bigint" {
			return d, nil, errors.New("AUTO_INCREMENT needs an ordinary NOT NULL integer without DEFAULT; review prerequisites separately.")
		}
		if ch.Identity.Kind == "none" {
			delete(identities, ch.Name)
		} else if ch.Identity.Kind == "autoIncrement" {
			identities[ch.Name] = true
		} else {
			return d, nil, tableedit.ErrUnsupported
		}
	}
	if len(identities) > 1 {
		return d, nil, errors.New("MariaDB supports one AUTO_INCREMENT column per table.")
	}
	for name := range identities {
		leading, surviving, original := false, false, false
		if old, ok := tableedit.FindColumn(b, name); ok && old.Identity.Value != nil {
			original = old.Identity.Value.Kind == "autoIncrement"
		}
		for _, idx := range b.Indexes {
			removed := false
			for _, edit := range d.Indexes {
				removed = removed || edit.Action != "add" && edit.Name == idx.Name
			}
			for _, edit := range d.Keys {
				removed = removed || edit.Action != "add" && edit.Name == idx.Owner
			}
			if !removed && tableedit.SupportingIndex(idx, []string{name}) {
				leading, surviving = true, true
			}
		}
		for _, key := range d.Keys {
			leading = leading || key.Action != "drop" && (key.Kind == "primary" || key.Kind == "unique") && len(key.Columns) > 0 && key.Columns[0] == name
		}
		for _, idx := range d.Indexes {
			leading = leading || tableedit.IndexEditSupports(idx, []string{name})
		}
		if original && !surviving {
			return d, nil, errors.New("Add an explicit alternative leading AUTO_INCREMENT index in a separate reviewed plan before replacing its current key; identity is never toggled implicitly.")
		}
		if !leading {
			return d, nil, errors.New("Select an explicit surviving key or index led by AUTO_INCREMENT; no supporting index is invented.")
		}
	}
	return d, enable, nil
}
func mariaDBIdentityOptionsEmpty(id tableedit.Identity) bool {
	return id.Start == nil && id.Increment == nil && id.Minimum == nil && id.Maximum == nil && id.Cache == nil && id.Cycle == nil
}
func mariaDBIdentityOperations(ops, enable []tableedit.Operation) []tableedit.Operation {
	disable, normal, renames := []tableedit.Operation{}, []tableedit.Operation{}, []tableedit.Operation{}
	for _, op := range ops {
		if op.Kind == "renameColumn" || op.Kind == "renameTable" {
			renames = append(renames, op)
		} else if op.Kind == "changeColumn" && op.Change.Identity != nil {
			if op.Change.Identity.Kind == "none" {
				disable = append(disable, op)
			} else {
				enable = append(enable, op)
			}
		} else {
			normal = append(normal, op)
		}
	}
	return append(append(append(disable, normal...), enable...), renames...)
}
func mariaDBGenerationColumn(ctx context.Context, b tableedit.Baseline, change tableedit.ColumnChange) (string, error) {
	old, ok := tableedit.FindColumn(b, change.Name)
	if !ok || b.Facts == nil || old.Generated.Value == nil || old.Identity.Value == nil || old.Default.Value == nil {
		return "", tableedit.ErrUnsupported
	}
	if change.Type != nil || change.Nullable != nil || change.Default != nil || change.Unsigned != nil || change.Charset != nil || change.Collation != nil || change.Generated != nil && change.Identity != nil {
		return "", errors.New("Review generation and AUTO_INCREMENT separately from other column attributes.")
	}
	column := old
	if change.Generated != nil {
		if old.Identity.Value.Kind != "none" || old.Nullable.Value == nil || !*old.Nullable.Value {
			return "", tableedit.ErrUnsupported
		}
		if change.Generated.Storage != "none" {
			if old.Default.Value.Kind != "none" && old.Default.Value.Kind != "sqlNull" {
				return "", errors.New("Remove the existing DEFAULT before generation.")
			}
			if old.Generated.Value.Kind != "none" && old.Generated.Value.Kind != change.Generated.Storage {
				return "", errors.New("Changing STORED/VIRTUAL storage requires a separately reviewed native migration.")
			}
			expr, e := tableedit.ExpressionSlot("mariadb", change.Generated.Expression)
			if e != nil {
				return "", e
			}
			column.Generated = sc.Known(sc.Generated{Kind: change.Generated.Storage, Expression: &sc.Expression{Text: expr}})
			column.Default = sc.Known(sc.Default{Kind: "none"})
		} else {
			column.Generated = sc.Known(sc.Generated{Kind: "none"})
		}
	}
	if change.Identity != nil {
		if old.Generated.Value.Kind != "none" || !mariaDBIdentityOptionsEmpty(*change.Identity) {
			return "", tableedit.ErrUnsupported
		}
		if change.Identity.Kind == "autoIncrement" && !b.Target.Create && !mariaDBStructureModeHas(b, "NO_AUTO_VALUE_ON_ZERO") {
			return "", errors.New("Enabling AUTO_INCREMENT requires already active NO_AUTO_VALUE_ON_ZERO to preserve stored zero IDs; no mode is changed implicitly.")
		}
		column.Identity = sc.Known(sc.Identity{Kind: change.Identity.Kind})
	}
	definition, manual, e := RenderStructureColumnWithOptions(ctx, column, sc.Known(b.Facts.EngineContext), b.Facts.Table.Options)
	if e != nil {
		return "", e
	}
	if manual != "" {
		return "", errors.New(manual)
	}
	return "ALTER TABLE " + QuoteIdentifier(b.Target.Schema) + "." + QuoteIdentifier(b.Target.Table) + " MODIFY COLUMN " + strings.TrimSpace(definition) + ";", nil
}

func mariaDBStructureModeHas(b tableedit.Baseline, mode string) bool {
	for _, m := range strings.Split(mariaDBStructureMode(b), ",") {
		if m == mode {
			return true
		}
	}
	return false
}
