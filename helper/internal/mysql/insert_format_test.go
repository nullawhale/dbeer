package mysql

import (
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestOfflineInsertMySQLRejectsCaseFoldedColumnMappings(t *testing.T) {
	for _, names := range [][2]string{{"value", "VALUE"}, {"Value", "value"}, {"Σ", "ς"}} {
		request := protocol.InsertFormatRequest{Engine: "mysql", Table: "target",
			Columns: []protocol.InsertFormatColumn{{Name: names[0]}, {Name: names[1]}},
			Rows:    [][]protocol.CellValue{{{Kind: "null"}, {Kind: "default"}}}}
		if !request.Valid() {
			t.Fatal("shared request validator should preserve exact target spelling")
		}
		sql, err := FormatInserts(request)
		if sql != "" || err != errInsertColumnCollision {
			t.Fatal("case-insensitive MySQL column collision produced SQL or an unsafe diagnostic")
		}
	}
}

func TestOfflineInsertMySQLPreservesCanonicalEncodingInTargetMappings(t *testing.T) {
	request := protocol.InsertFormatRequest{Engine: "mysql", Table: "target",
		Columns: []protocol.InsertFormatColumn{{Name: "é"}, {Name: "e\u0301"}},
		Rows:    [][]protocol.CellValue{{{Kind: "null"}, {Kind: "default"}}}}
	sql, err := FormatInserts(request)
	if err != nil || !strings.Contains(sql, "(`é`, `e\u0301`)") {
		t.Fatal("MySQL target names were normalized instead of preserving their original spelling")
	}
}
