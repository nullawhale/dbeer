package sqlite

import (
	"context"
	"dbeer/helper/internal/tableedit"
	"errors"
)

func (s *Session) prepareStructureRenames(ctx context.Context, b tableedit.Baseline, d tableedit.Draft, p tableedit.Prepared) (tableedit.Prepared, error) {
	if b.Target.Create || len(d.Columns)+len(d.Keys)+len(d.Indexes) > 0 {
		return p, errors.New("Review SQLite renames separately from column, key and index edits.")
	}
	legacy, _, e := s.query(ctx, "PRAGMA legacy_alter_table")
	if e != nil || len(legacy) != 1 || cellInt(legacy[0][0]) != 0 {
		return p, errors.New("SQLite renaming requires modern dependency rewriting (legacy_alter_table=OFF); settings are never changed implicitly.")
	}
	names := map[string]bool{}
	for _, c := range b.Columns {
		names[ddlFold(c.Name)] = true
	}
	target := "main." + quote(b.Target.Table)
	for _, c := range d.Changes {
		if c.RenameTo == nil || c.Nullable != nil || c.Type != nil || c.Default != nil || c.Generated != nil || c.Identity != nil {
			return p, errors.New("Review SQLite renames separately from attribute changes.")
		}
		found := false
		for _, old := range b.Columns {
			if old.Name == c.Name {
				found = true
			}
		}
		if !found || names[ddlFold(*c.RenameTo)] && ddlFold(c.Name) != ddlFold(*c.RenameTo) {
			return p, tableedit.ErrInvalid
		}
		p.SQL = append(p.SQL, "ALTER TABLE "+target+" RENAME COLUMN "+quote(c.Name)+" TO "+quote(*c.RenameTo)+";")
		delete(names, ddlFold(c.Name))
		names[ddlFold(*c.RenameTo)] = true
	}
	if d.RenameTable != nil {
		exists, _, e := s.query(ctx, "SELECT name FROM main.sqlite_schema WHERE name=? COLLATE NOCASE", *d.RenameTable)
		if e != nil || len(exists) != 0 {
			return p, errors.New("The rename destination must be absent.")
		}
		p.SQL = append(p.SQL, "ALTER TABLE "+target+" RENAME TO "+quote(*d.RenameTable)+";")
		p.ResultTarget = tableedit.ResultTarget(b.Target, d)
	}
	return p, nil
}
