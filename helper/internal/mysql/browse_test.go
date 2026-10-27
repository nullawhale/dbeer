package mysql

import (
	"encoding/hex"
	"reflect"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestMySQLBrowseReadSQLPreservesExecutedPlan(t *testing.T) {
	label := "quote' \\ κόσμος 🌍'); DROP TABLE records; --"
	empty, literalNull, binary, exact := "", "NULL", "AP+A", "+9007199254740993.000000000000000001"
	request := protocol.CatalogRequest{Kind: "browse", Schema: "odd`schema", Object: "table'?;--", Page: 3,
		Sort: []protocol.CatalogSort{{Column: "label`?", Direction: "desc"}, {Column: "id", Direction: "desc"}},
		Filters: []protocol.CatalogFilter{
			{Column: "label`?", Operator: "contains", Value: &label},
			{Column: "payload", Operator: "contains", Value: &binary},
			{Column: "nullable", Operator: "isNull"},
			{Column: "label`?", Operator: "isNotNull"},
			{Column: "label`?", Operator: "ne", Value: &empty},
			{Column: "label`?", Operator: "ne", Value: &literalNull},
			{Column: "exact", Operator: "gte", Value: &exact},
			{Column: "payload", Operator: "eq", Value: &empty},
		}}
	plan, err := buildBrowsePlan(request, map[string]string{"id": "int", "part": "int", "label`?": "text", "payload": "varbinary", "nullable": "text", "exact": "decimal"}, []string{"id", "part"})
	if err != nil {
		t.Fatal("valid browse plan was rejected")
	}
	prefix := "SELECT * FROM `odd``schema`.`table'?;--` WHERE "
	suffix := " ORDER BY `label``?` DESC, `id` DESC, `part` LIMIT 200 OFFSET 600"
	wantStatement := prefix + "LOCATE(?, `label``?`) > 0 AND LOCATE(?, `payload`) > 0 AND `nullable` IS NULL AND `label``?` IS NOT NULL AND `label``?` <> ? AND `label``?` <> ? AND `exact` >= CAST(? AS DECIMAL(65,18)) AND `payload` = ?" + suffix
	wantSource := prefix + "LOCATE(CONVERT(X'" + hex.EncodeToString([]byte(label)) + "' USING utf8mb4), `label``?`) > 0 AND LOCATE(X'00ff80', `payload`) > 0 AND `nullable` IS NULL AND `label``?` IS NOT NULL AND `label``?` <> CONVERT(X'' USING utf8mb4) AND `label``?` <> CONVERT(X'4e554c4c' USING utf8mb4) AND `exact` >= CAST(CONVERT(X'" + hex.EncodeToString([]byte(exact[1:])) + "' USING utf8mb4) AS DECIMAL(65,18)) AND `payload` = X''" + suffix
	if plan.statement != wantStatement || plan.sourceSQL != wantSource {
		t.Fatal("browse source changed identifiers, filter operands, numeric casts, sort, or page bounds")
	}
	wantValues := []any{label, []byte{0, 255, 128}, empty, literalNull, exact[1:], []byte{}}
	if !reflect.DeepEqual(plan.args, wantValues) {
		t.Fatal("source generation changed bound parameters or empty binary semantics")
	}
}
