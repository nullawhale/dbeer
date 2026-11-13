package sqlite

import (
	"context"
	"errors"
	"strings"

	"dbeer/helper/internal/tableedit"
)

// preparePreservedRebuild changes only explicitly selected column clauses. The
// original definitions remain the authority for every untouched schema feature.
func (s *Session) preparePreservedRebuild(ctx context.Context, b tableedit.Baseline, d tableedit.Draft, p tableedit.Prepared) (tableedit.Prepared, error) {
	raw, _ := b.Attributes["sqlite"]["sql"].(string)
	parsed, err := parseDDLTable(raw)
	if err != nil {
		return p, err
	}
	views, _, err := s.query(ctx, `SELECT name FROM main.sqlite_schema WHERE type='view'`)
	if err != nil {
		return p, err
	}
	if len(views) > 0 {
		return p, errors.New("Views prevent proving reconstruction dependencies; use manual SQL.")
	}
	observed := map[string]tableedit.ObservedColumn{}
	for _, c := range b.Columns {
		observed[c.Name] = c
	}
	changes := map[string]tableedit.ColumnChange{}
	for _, c := range d.Changes {
		old, ok := observed[c.Name]
		if !ok || !old.CanModify {
			return p, tableedit.ErrUnsupported
		}
		for _, k := range b.Keys {
			if k.Kind == "primary" {
				for _, n := range k.Columns {
					if n == c.Name && (c.Type != nil || c.Nullable != nil) {
						return p, tableedit.ErrUnsupported
					}
				}
			}
		}
		changes[c.Name] = c
	}
	parts := []string{}
	partNames := []string{}
	constraints := []string{}
	seen := map[string]bool{}
	for _, term := range parsed.terms {
		if term.name == "" {
			constraints = append(constraints, term.raw)
			continue
		}
		c, ok := observed[term.name]
		if !ok || seen[term.name] {
			return p, tableedit.ErrUnsupported
		}
		seen[term.name] = true
		text := term.raw
		if change, ok := changes[term.name]; ok {
			text, err = patchDDLColumn(term, c, change)
			if err != nil {
				return p, err
			}
			if parsed.strict && change.Type != nil && change.Type.Kind == "sqliteNumeric" {
				return p, tableedit.ErrUnsupported
			}
		}
		parts = append(parts, text)
		partNames = append(partNames, term.name)
	}
	if len(seen) != len(observed) {
		return p, tableedit.ErrUnsupported
	}
	for _, c := range d.Columns {
		if parsed.strict && c.Type.Kind == "sqliteNumeric" {
			return p, tableedit.ErrUnsupported
		}
		if seen[c.Name] {
			return p, tableedit.ErrInvalid
		}
		text, e := structureColumn(c)
		if e != nil {
			return p, e
		}
		parts = append(parts, text)
		partNames = append(partNames, c.Name)
		seen[c.Name] = true
	}
	if len(d.ColumnOrder) > 0 {
		byName := map[string]string{}
		for i, n := range partNames {
			byName[n] = parts[i]
		}
		parts = nil
		for _, n := range d.ColumnOrder {
			text, ok := byName[n]
			if !ok {
				return p, tableedit.ErrInvalid
			}
			parts = append(parts, text)
		}
	}
	parts = append(parts, constraints...)
	// Generated values must be recomputed by SQLite, never explicitly inserted.
	info, err := s.tableInfo(ctx, "main", b.Target.Table)
	if err != nil {
		return p, err
	}
	copyNames := []string{}
	for _, c := range info {
		if c.Hidden == 0 {
			copyNames = append(copyNames, quote(c.Name))
		}
	}
	if len(copyNames) == 0 {
		return p, tableedit.ErrUnsupported
	}
	rowID := ""
	if !parsed.without {
		pk := []columnInfo{}
		used := map[string]bool{}
		for _, c := range info {
			used[ddlFold(c.Name)] = true
			if c.PrimaryKey > 0 {
				pk = append(pk, c)
			}
		}
		for _, c := range d.Columns {
			used[ddlFold(c.Name)] = true
		}
		alias := false
		if len(pk) == 1 && strings.EqualFold(pk[0].NativeType, "INTEGER") {
			rows, _, e := s.query(ctx, "SELECT count(*) FROM pragma_index_list(?,?) WHERE origin='pk'", b.Target.Table, "main")
			if e != nil {
				return p, e
			}
			alias = len(rows) == 1 && cellInt(rows[0][0]) == 0
		}
		if !alias {
			name := ""
			for _, n := range []string{"rowid", "_rowid_", "oid"} {
				if !used[ddlFold(n)] {
					name = n
					break
				}
			}
			if name == "" {
				return p, tableedit.ErrUnsupported
			}
			copyNames = append([]string{name}, copyNames...)
			rowID = name
		}
	}
	selectNames := append([]string(nil), copyNames...)
	for _, backfill := range d.Backfills {
		expression, e := tableedit.ExpressionSlot("sqlite", backfill.Expression)
		if e != nil {
			return p, e
		}
		copyNames = append(copyNames, quote(backfill.Column))
		selectNames = append(selectNames, expression)
	}
	temp := "__dbeer_rebuild_" + b.Fingerprint[:12]
	target := "main." + quote(b.Target.Table)
	p.SQL = []string{"CREATE TABLE main." + quote(temp) + " (\n" + strings.Join(parts, "\n,\n") + "\n) " + parsed.suffix + ";", "INSERT INTO main." + quote(temp) + " (" + strings.Join(copyNames, ",") + ") SELECT " + strings.Join(selectNames, ",") + " FROM " + target + ";", "DROP TABLE " + target + ";", "ALTER TABLE main." + quote(temp) + " RENAME TO " + quote(b.Target.Table) + ";"}
	if d.NeedsAuthoringV5() {
		order, e := tableedit.ReconstructionOrder(b, d)
		if e != nil {
			return p, e
		}
		p.Reconstruction = &tableedit.Reconstruction{Method: "sqlite-copy", ColumnOrder: order, ExpectedDefinition: p.SQL[0], RowID: rowID}
	}
	if parsed.autoincrement {
		oldLiteral := "'" + strings.ReplaceAll(b.Target.Table, "'", "''") + "'"
		tempLiteral := "'" + temp + "'"
		steps := []string{"INSERT INTO main.sqlite_sequence(name,seq) SELECT " + tempLiteral + ",COALESCE((SELECT seq FROM main.sqlite_sequence WHERE name=" + oldLiteral + "),0) WHERE NOT EXISTS(SELECT 1 FROM main.sqlite_sequence WHERE name=" + tempLiteral + ");", "UPDATE main.sqlite_sequence SET seq=max(seq,COALESCE((SELECT seq FROM main.sqlite_sequence WHERE name=" + oldLiteral + "),0)) WHERE name=" + tempLiteral + ";"}
		p.SQL = append(append(append([]string{}, p.SQL[:2]...), steps...), p.SQL[2:]...)
	}
	retained, _, err := s.query(ctx, `SELECT type,name,sql FROM main.sqlite_schema WHERE tbl_name=? AND type IN ('index','trigger') AND sql IS NOT NULL ORDER BY type,name`, b.Target.Table)
	if err != nil {
		return p, err
	}
	for _, row := range retained {
		skip := false
		for _, x := range d.Indexes {
			if cellText(row[0]) == "index" && cellText(row[1]) == x.Name && x.Action != "add" {
				supported := false
				for _, old := range b.Indexes {
					if old.Name == x.Name && old.Supported {
						supported = true
					}
				}
				if !supported {
					return p, tableedit.ErrUnsupported
				}
				skip = true
			}
		}
		if !skip {
			p.SQL = append(p.SQL, cellText(row[2])+";")
		}
	}
	for _, x := range d.Indexes {
		if x.Action == "drop" {
			continue
		}
		names := []string{}
		for _, n := range x.Columns {
			if !seen[n] {
				return p, tableedit.ErrInvalid
			}
			names = append(names, quote(n))
		}
		unique := ""
		if x.Unique {
			unique = "UNIQUE "
		}
		p.SQL = append(p.SQL, "CREATE "+unique+"INDEX main."+quote(x.Name)+" ON "+quote(b.Target.Table)+" ("+strings.Join(names, ",")+");")
	}
	return p, nil
}
