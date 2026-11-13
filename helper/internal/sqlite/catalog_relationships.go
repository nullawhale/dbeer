package sqlite

import (
	"context"

	"dbeer/helper/internal/protocol"
)

// SQLite folds only ASCII in identifiers. Preserve the catalog's exact spelling
// when a constraint used another case, including for explicit column mappings.
func sameIdentifier(left, right string) bool {
	if len(left) != len(right) {
		return false
	}
	for i := 0; i < len(left); i++ {
		a, b := left[i], right[i]
		if a >= 'A' && a <= 'Z' {
			a += 'a' - 'A'
		}
		if b >= 'A' && b <= 'Z' {
			b += 'a' - 'A'
		}
		if a != b {
			return false
		}
	}
	return true
}

func (s *Session) resolveForeignKeyNames(ctx context.Context, source string, rows [][]protocol.SQLiteValue) error {
	if len(rows) == 0 {
		return nil
	}
	sourceColumns, err := s.tableInfo(ctx, "main", source)
	if err != nil {
		return err
	}
	widths := map[string]int{}
	for _, row := range rows {
		widths[text(row[0])]++
	}
	// Keep only one adjacent parent observation, rather than a catalog-wide cache.
	var previousParent, canonicalParent string
	var parentColumns []columnInfo
	for _, row := range rows {
		for _, column := range sourceColumns {
			if sameIdentifier(column.Name, text(row[3])) {
				row[3] = stringValue(column.Name)
				break
			}
		}
		parent := text(row[2])
		if parent != previousParent {
			previousParent, canonicalParent, parentColumns = parent, parent, nil
			objects, _, err := s.query(ctx, "SELECT name FROM main.sqlite_schema WHERE type='table' AND name=? COLLATE NOCASE", parent)
			if err != nil {
				return err
			}
			if len(objects) == 1 {
				canonicalParent = text(objects[0][0])
				parentColumns, err = s.tableInfo(ctx, "main", canonicalParent)
				if err != nil {
					return err
				}
			}
		}
		row[2] = stringValue(canonicalParent)
		if row[4].Type != "null" {
			for _, column := range parentColumns {
				if sameIdentifier(column.Name, text(row[4])) {
					row[4] = stringValue(column.Name)
					break
				}
			}
			continue
		}
		primaryWidth := 0
		for _, column := range parentColumns {
			if column.PrimaryKey > 0 {
				primaryWidth++
			}
		}
		if primaryWidth != widths[text(row[0])] {
			continue
		}
		position := integer(row[5])
		for _, column := range parentColumns {
			if column.PrimaryKey == position {
				row[4] = stringValue(column.Name)
				break
			}
		}
	}
	return nil
}
