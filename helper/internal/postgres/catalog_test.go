package postgres

import (
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestForeignKeyCatalogPairsColumnsByConstraintOrdinal(t *testing.T) {
	request := protocol.CatalogRequest{Kind: "foreignKeys", Schema: `private' OR 1=1`, Object: `child";--`, ObjectKind: "table"}
	query, values, notice := catalogSQL(request)
	if strings.Contains(query, request.Schema) || strings.Contains(query, request.Object) || len(values) != 2 || string(values[0]) != request.Schema || string(values[1]) != request.Object || notice != "" {
		t.Fatal("foreign key catalog names were not bound independently")
	}
	for _, fragment := range []string{`AS "targetSchema"`, `AS "targetTable"`, `AS "sourceColumn"`, `AS "targetColumn"`, "AS position", "unnest(k.conkey,k.confkey) WITH ORDINALITY", "ORDER BY k.conname,pair.ordinality"} {
		if !strings.Contains(query, fragment) {
			t.Fatal("foreign key catalog lost a structured field or composite pairing")
		}
	}
	if strings.Contains(query, "has_table_privilege(tc.") || strings.Contains(query, "has_schema_privilege(tn.") {
		t.Fatal("target read permissions must not hide an otherwise visible foreign key")
	}
}
