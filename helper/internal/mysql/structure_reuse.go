package mysql

import "dbeer/helper/internal/tableedit"

// ColumnDefinitionSQL renders only the shared bounded built-in column grammar.
// Native adapters retain type limits, table eligibility and transition proof.
func ColumnDefinitionSQL(column tableedit.Column) (string, error) {
	return sharedColumnDefinitionSQL(column)
}
