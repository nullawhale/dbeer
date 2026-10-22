package postgres

import (
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestOfflineInsertPostgresPreservesQuotedColumnCase(t *testing.T) {
	request := protocol.InsertFormatRequest{Engine: "postgresql", Table: "target",
		Columns: []protocol.InsertFormatColumn{{Name: "Value"}, {Name: "value"}},
		Rows:    [][]protocol.CellValue{{{Kind: "null"}, {Kind: "default"}}}}
	sql, err := FormatInserts(request)
	if err != nil || !strings.Contains(sql, `("Value", "value") VALUES (NULL, DEFAULT)`) {
		t.Fatal("distinct quoted PostgreSQL column names were rejected or changed")
	}
}
