package mariadb

import (
	"dbeer/helper/internal/protocol"
	"strings"
	"testing"
)

func TestMariaDBFilterCompilerRetainsTypedAndLiteralBoundaries(t *testing.T) {
	text := "' OR 1=1 -- \\ é"
	r := protocol.CatalogRequest{Filters: []protocol.CatalogFilter{{Column: "v", Operator: "eq", Value: &text}}}
	sql, e := mariaDBBrowsePredicate(r, map[string]string{"v": "varchar"})
	if e != nil || strings.Contains(sql, text) || !strings.Contains(sql, "CONVERT(X'") {
		t.Fatal("native text operand escaped its data-only slot")
	}
	numeric := "0.12345678901234567890123456789012345678"
	r.Filters = []protocol.CatalogFilter{{Column: "n", Operator: "eq", NativeValue: &protocol.NativeCellFilterValue{SourceEngine: "mariadb", SourceType: "decimal(65,38)", Cell: protocol.CellValue{Kind: "text", Value: &numeric}, SQLiteStorage: "preserve"}}}
	if sql, e = mariaDBBrowsePredicate(r, map[string]string{"n": "decimal"}); e != nil || !strings.Contains(sql, "DECIMAL(65,38)") {
		t.Fatal("native decimal operand was rounded or narrowed")
	}
	tooWide := numeric + "9"
	r.Filters[0].NativeValue.Cell.Value = &tooWide
	if _, e = mariaDBBrowsePredicate(r, map[string]string{"n": "decimal"}); e == nil {
		t.Fatal("unrepresentable native decimal scale was accepted")
	}
	zero := "0000-00-00 00:00:00"
	r.Filters = []protocol.CatalogFilter{{Column: "stamp", Operator: "eq", Value: &zero}}
	if _, e = mariaDBBrowsePredicate(r, map[string]string{"stamp": "timestamp"}); e == nil {
		t.Fatal("zero timestamp was invented as a UTC instant")
	}
	r.Filters = []protocol.CatalogFilter{{Column: "absent", Operator: "isNull"}}
	if _, e = mariaDBBrowsePredicate(r, map[string]string{"v": "varchar"}); e == nil {
		t.Fatal("unknown target column was accepted")
	}
}
