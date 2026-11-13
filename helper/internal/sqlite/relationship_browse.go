package sqlite

import (
	"context"
	"dbeer/helper/internal/protocol"
	"errors"
	"strings"
)

func (s *Session) validateRelationshipScope(ctx context.Context, scope protocol.SQLiteRelationshipScope) error {
	if !scope.Valid() {
		return errors.New("Invalid incoming relationship scope.")
	}
	for _, table := range []protocol.CatalogRelationTarget{scope.Child, scope.Parent} {
		rows, _, err := s.query(ctx, "SELECT name FROM main.sqlite_schema WHERE type='table' AND name=? COLLATE NOCASE", table.Name)
		if err != nil {
			return err
		}
		if len(rows) != 1 || text(rows[0][0]) != table.Name {
			return errors.New("The relationship table changed. Discover incoming relations again.")
		}
	}
	rows, _, err := s.query(ctx, `SELECT 'fk_'||id AS name,'main' AS targetSchema,"table" AS targetTable,"from" AS sourceColumn,"to" AS targetColumn,seq+1 AS position FROM pragma_foreign_key_list(?) ORDER BY id,seq`, scope.Child.Name)
	if err != nil {
		return err
	}
	if err = s.resolveForeignKeyNames(ctx, scope.Child.Name, rows); err != nil {
		return err
	}
	var selected [][]protocol.SQLiteValue
	for _, row := range rows {
		if text(row[0]) == scope.Name {
			selected = append(selected, row)
		}
	}
	if len(selected) != len(scope.Columns) {
		return errors.New("The declared relationship changed. Discover incoming relations again.")
	}
	for i, row := range selected {
		p := scope.Columns[i]
		if text(row[1]) != scope.Parent.Schema || text(row[2]) != scope.Parent.Name || text(row[3]) != p.Source || text(row[4]) != p.Target || integer(row[5]) != p.Position {
			return errors.New("The declared relationship mapping changed. Discover incoming relations again.")
		}
	}
	return nil
}

// SQLite compares an FK using the parent's affinity and collation. Unary +
// removes the child's affinity without changing its storage value or bytes.
func relationshipPredicate(scope protocol.SQLiteRelationshipScope) (string, []any) {
	parts := []string{}
	args := []any{}
	for _, p := range scope.Columns {
		parent := quote("__dbeer_parent") + "." + quote(p.Target)
		child := quote("__dbeer_child") + "." + quote(p.Source)
		parts = append(parts, parent+"=?", parent+"=+"+child)
		args = append(args, p.Value)
	}
	return "EXISTS (SELECT 1 FROM main." + quote(scope.Parent.Name) + " AS " + quote("__dbeer_parent") + " WHERE " + strings.Join(parts, " AND ") + ")", args
}
