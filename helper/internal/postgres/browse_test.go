package postgres

import (
	"reflect"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestPostgresBrowseReadSQLPreservesExecutedPlan(t *testing.T) {
	label := "quote' \\ κόσμος 🌍'); DROP TABLE records; --"
	empty, literalNull, binary, exact := "", "NULL", "AP+A", "+9007199254740993.000000000000000001"
	request := protocol.CatalogRequest{Kind: "browse", Schema: `odd"schema`, Object: `table'$1;--`, Page: 3,
		Sort: []protocol.CatalogSort{{Column: `label"$1`, Direction: "desc"}, {Column: "id", Direction: "desc"}},
		Filters: []protocol.CatalogFilter{
			{Column: `label"$1`, Operator: "contains", Value: &label},
			{Column: "payload", Operator: "contains", Value: &binary},
			{Column: "nullable", Operator: "isNull"},
			{Column: `label"$1`, Operator: "isNotNull"},
			{Column: `label"$1`, Operator: "ne", Value: &empty},
			{Column: `label"$1`, Operator: "ne", Value: &literalNull},
			{Column: "exact", Operator: "gte", Value: &exact},
			{Column: "payload", Operator: "eq", Value: &empty},
		}}
	plan, err := buildBrowsePlan(request, []browseColumn{
		{name: "part", primary: 2, numeric: true}, {name: "id", primary: 1, numeric: true},
		{name: `label"$1`}, {name: "payload", binary: true}, {name: "nullable"}, {name: "exact", numeric: true},
	})
	if err != nil {
		t.Fatal("valid browse plan was rejected")
	}
	prefix := `SELECT * FROM "odd""schema"."table'$1;--" WHERE `
	suffix := ` ORDER BY "label""$1" DESC,"id" DESC,"part" ASC LIMIT 200 OFFSET 600`
	wantStatement := prefix + `strpos("label""$1"::text,$1::text)>0 AND position($2::bytea IN "payload")>0 AND "nullable" IS NULL AND "label""$1" IS NOT NULL AND "label""$1" <> $3 AND "label""$1" <> $4 AND "exact" >= $5::numeric AND "payload" = $6` + suffix
	wantSource := prefix + `strpos("label""$1"::text,E'quote'' \\ κόσμος 🌍''); DROP TABLE records; --'::text)>0 AND position(pg_catalog.decode('00ff80', 'hex')::bytea IN "payload")>0 AND "nullable" IS NULL AND "label""$1" IS NOT NULL AND "label""$1" <> E'' AND "label""$1" <> E'NULL' AND "exact" >= E'+9007199254740993.000000000000000001'::numeric AND "payload" = pg_catalog.decode('', 'hex')` + suffix
	if plan.statement != wantStatement || plan.sourceSQL != wantSource || plan.notice != "" {
		t.Fatal("browse source changed identifiers, filter operands, numeric casts, sort, or page bounds")
	}
	wantValues := [][]byte{[]byte(label), []byte(`\x00ff80`), {}, []byte(literalNull), []byte(exact), []byte(`\x`)}
	if !reflect.DeepEqual(plan.values, wantValues) {
		t.Fatal("source generation changed bound parameters or empty binary semantics")
	}
}

func TestPostgresBrowseReadSQLKeepsNoKeyNotice(t *testing.T) {
	plan, err := buildBrowsePlan(protocol.CatalogRequest{Schema: "public", Object: "view"}, []browseColumn{{name: "value"}})
	if err != nil || plan.statement != `SELECT * FROM "public"."view" LIMIT 200 OFFSET 0` || plan.sourceSQL != plan.statement || plan.notice == "" {
		t.Fatal("unfiltered view source or unstable order notice was lost")
	}
}
