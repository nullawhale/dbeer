package mysql

import (
	"context"
	"errors"
	"strings"

	sc "dbeer/helper/internal/schemacompare"
	"dbeer/helper/internal/syncplan"
	"dbeer/helper/internal/tableedit"
)

func mysqlAuthoredDraft(b tableedit.Baseline, d tableedit.Draft) (tableedit.Draft, []tableedit.Operation, error) {
	if !d.Valid() {
		return d, nil, tableedit.ErrInvalid
	}
	if b.Facts != nil && b.Facts.ServerVersion/10000 == 8 {
		noBackslash := false
		for _, option := range b.Facts.EngineContext {
			if option.Name == "sqlMode" {
				for _, mode := range strings.Split(option.Value, ",") {
					noBackslash = noBackslash || mode == "NO_BACKSLASH_ESCAPES"
				}
			}
		}
		if noBackslash {
			expressions := []string{}
			for _, c := range d.Columns {
				if c.Default.Kind == "expression" {
					expressions = append(expressions, *c.Default.Value)
				}
				if c.Generated != nil {
					expressions = append(expressions, c.Generated.Expression)
				}
			}
			for _, c := range d.Changes {
				if c.Default != nil && c.Default.Kind == "expression" {
					expressions = append(expressions, *c.Default.Value)
				}
				if c.Generated != nil {
					expressions = append(expressions, c.Generated.Expression)
				}
			}
			for _, expression := range expressions {
				if doubledApostrophe(expression) {
					return d, nil, errors.New("MySQL 8 rejects doubled apostrophes in stored expressions under NO_BACKSLASH_ESCAPES (server parser issue111892). Review SQL mode or author an explicit CHAR(39) expression; no rewrite or mode change is generated.")
				}
			}
		}
	}
	d.Columns = append([]tableedit.Column(nil), d.Columns...)
	d.Changes = append([]tableedit.ColumnChange(nil), d.Changes...)
	enable := []tableedit.Operation{}
	ai := map[string]bool{}
	if b.Facts != nil {
		for _, c := range b.Facts.Table.Columns.Items {
			if c.Identity.Value != nil && c.Identity.Value.Kind == "autoIncrement" {
				ai[c.Ref.Name] = true
			}
		}
	}
	for i := range d.Columns {
		c := &d.Columns[i]
		if c.Type.Reference != nil {
			return d, nil, errors.New("MySQL column types are server built-ins; PostgreSQL qualified custom type references are unavailable.")
		}
		if c.Identity == nil || c.Identity.Kind == "none" {
			continue
		}
		if c.Identity.Kind != "autoIncrement" {
			return d, nil, tableedit.ErrUnsupported
		}
		ai[c.Name] = true
		x := *c.Identity
		c.Identity = nil
		enable = append(enable, tableedit.Operation{Kind: "changeColumn", Change: &tableedit.ColumnChange{Name: c.Name, Identity: &x}})
	}
	changes := []tableedit.ColumnChange{}
	for _, c := range d.Changes {
		if c.Identity != nil {
			if c.Identity.Kind != "none" && c.Identity.Kind != "autoIncrement" {
				return d, nil, tableedit.ErrUnsupported
			}
			old, ok := tableedit.FindColumn(b, c.Name)
			if !ok || old.Type.Value == nil || old.Nullable.Value == nil || *old.Nullable.Value || old.Default.Value == nil || old.Default.Value.Kind != "none" {
				return d, nil, errors.New("AUTO_INCREMENT requires an existing NOT NULL integer column without a default; review prerequisite edits separately.")
			}
			typ, ok := tableedit.ColumnType(old)
			if !ok || (typ.Kind != "integer" && typ.Kind != "bigint") {
				return d, nil, tableedit.ErrUnsupported
			}
			if c.Identity.Kind == "none" {
				delete(ai, c.Name)
				changes = append(changes, c)
			} else {
				ai[c.Name] = true
				changes = append(changes, c)
			}
			continue
		}
		changes = append(changes, c)
	}
	d.Changes = changes
	if len(ai) > 1 {
		return d, nil, errors.New("MySQL permits only one AUTO_INCREMENT column per table.")
	}
	for name := range ai {
		leading := false
		originalIdentity := false
		if b.Facts != nil {
			for _, c := range b.Facts.Table.Columns.Items {
				originalIdentity = originalIdentity || c.Ref.Name == name && c.Identity.Value != nil && c.Identity.Value.Kind == "autoIncrement"
			}
		}
		survivingLeading := false
		for _, x := range b.Indexes {
			removed := false
			for _, e := range d.Keys {
				removed = removed || e.Action != "add" && x.Owner == e.Name
			}
			for _, e := range d.Indexes {
				removed = removed || e.Action != "add" && x.Name == e.Name
			}
			leading = leading || !removed && x.Supported && len(x.Columns) > 0 && x.Columns[0] == name
			survivingLeading = survivingLeading || !removed && x.Supported && len(x.Columns) > 0 && x.Columns[0] == name
		}
		for _, k := range d.Keys {
			leading = leading || k.Action != "drop" && (k.Kind == "primary" || k.Kind == "unique") && len(k.Columns) > 0 && k.Columns[0] == name
		}
		for _, x := range d.Indexes {
			leading = leading || x.Action != "drop" && len(x.Columns) > 0 && x.Columns[0] == name
		}
		if originalIdentity && !survivingLeading {
			return d, nil, errors.New("MySQL cannot drop the only leading AUTO_INCREMENT key before its replacement. Add an explicit alternative leading index in a separate reviewed plan first; identity and its counter are not toggled implicitly.")
		}
		if !leading {
			return d, nil, errors.New("Select an explicit key or index led by the AUTO_INCREMENT column; Preview never invents its supporting key.")
		}
	}
	return d, enable, nil
}

func insertMySQLIdentityOperations(ops, enable []tableedit.Operation) []tableedit.Operation {
	before, normal, renames := []tableedit.Operation{}, []tableedit.Operation{}, []tableedit.Operation{}
	for _, op := range ops {
		if op.Kind == "renameColumn" || op.Kind == "renameTable" {
			renames = append(renames, op)
		} else if op.Kind == "changeColumn" && op.Change.Identity != nil && op.Change.Identity.Kind == "none" {
			before = append(before, op)
		} else if op.Kind == "changeColumn" && op.Change.Identity != nil && op.Change.Identity.Kind == "autoIncrement" {
			enable = append(enable, op)
		} else {
			normal = append(normal, op)
		}
	}
	return append(append(append(before, normal...), enable...), renames...)
}

func mysqlAuthoredChange(ctx context.Context, b tableedit.Baseline, c sc.Column, change tableedit.ColumnChange, target string) ([]string, error) {
	if change.Default != nil || change.Type != nil || change.Nullable != nil || change.Generated != nil && change.Identity != nil {
		return nil, errors.New("Review generated/identity changes separately from other column attributes.")
	}
	proof := c
	authored := map[*sc.Expression]bool{}
	if change.Generated != nil {
		if c.Identity.Value == nil || c.Identity.Value.Kind != "none" || c.Generated.Value == nil || c.Default.Value == nil {
			return nil, tableedit.ErrUnsupported
		}
		if change.Generated.Storage != "none" {
			if c.Default.Value.Kind != "none" && c.Default.Value.Kind != "sqlNull" {
				return nil, errors.New("Remove the existing default explicitly before adding generation.")
			}
			if c.Generated.Value.Kind != "none" && c.Generated.Value.Kind != change.Generated.Storage {
				return nil, errors.New("Changing generated storage kind requires a separately reviewed reconstruction.")
			}
			expr, err := tableedit.ExpressionSlot("mysql", change.Generated.Expression)
			if err != nil {
				return nil, err
			}
			x := &sc.Expression{Text: expr}
			authored[x] = true
			c.Generated = sc.Known(sc.Generated{Kind: change.Generated.Storage, Expression: x})
			c.Default = sc.Known(sc.Default{Kind: "none"})
		} else {
			c.Generated = sc.Known(sc.Generated{Kind: "none"})
		}
		proof.Generated = sc.Known(sc.Generated{Kind: "none"})
	}
	if change.Identity != nil {
		if c.Generated.Value == nil || c.Generated.Value.Kind != "none" {
			return nil, tableedit.ErrUnsupported
		}
		c.Identity = sc.Known(sc.Identity{Kind: change.Identity.Kind})
		proof.Identity = sc.Known(sc.Identity{Kind: "none"})
	}
	if reason := syncplan.SchemaFactsReason(proof); reason != "" {
		return nil, errors.New("MODIFY cannot preserve unchanged properties: " + reason)
	}
	renderer := myDefinition{w: &sc.DefinitionWriter{Context: ctx}, engine: sc.Known(b.Facts.EngineContext), authored: authored}
	renderer.column(c)
	definition, err := renderer.w.Finish()
	if err != nil || definition.Limited {
		return nil, tableedit.ErrUnsupported
	}
	return []string{"ALTER TABLE " + target + " MODIFY COLUMN " + strings.TrimSpace(definition.SQL) + ";"}, nil
}

func doubledApostrophe(raw string) bool {
	for i := 0; i < len(raw); i++ {
		quote := raw[i]
		if quote != '\'' && quote != '"' && quote != '`' {
			continue
		}
		for i++; i < len(raw); i++ {
			if raw[i] != quote {
				continue
			}
			if i+1 < len(raw) && raw[i+1] == quote {
				if quote == '\'' {
					return true
				}
				i++
				continue
			}
			break
		}
	}
	return false
}
