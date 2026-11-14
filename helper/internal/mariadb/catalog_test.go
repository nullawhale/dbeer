package mariadb

import (
	"reflect"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestMariaDBCatalogBindsExactNativeNames(t *testing.T) {
	for _, kind := range []string{"columns", "foreignKeys", "referencingTables", "keys", "indexes", "constraints", "triggers"} {
		r := protocol.CatalogRequest{Kind: kind, Schema: "schema'quoted", Object: "table`quoted"}
		query, args, err := catalogQuery(r)
		if err != nil || !reflect.DeepEqual(args, []any{r.Schema, r.Object}) || strings.Contains(query, r.Schema) || strings.Contains(query, r.Object) {
			t.Fatal("native catalog identity entered SQL text or changed its bound ordering")
		}
	}
	quoted := QuoteIdentifier("name`quoted")
	if quoted != "`name``quoted`" {
		t.Fatal("native identifier quoting did not escape the delimiter")
	}
}

func TestMariaDBCatalogKeepsNativeIndexAndCompositeOrdering(t *testing.T) {
	indexes, _, err := catalogQuery(protocol.CatalogRequest{Kind: "indexes"})
	if err != nil || !strings.Contains(indexes, "IGNORED") || strings.Contains(indexes, "IS_VISIBLE") || strings.Contains(indexes, "EXPRESSION") {
		t.Fatal("MariaDB index metadata inherited Oracle-only properties")
	}
	foreign, _, err := catalogQuery(protocol.CatalogRequest{Kind: "foreignKeys"})
	if err != nil || !strings.Contains(foreign, "ORDINAL_POSITION AS position") || strings.Contains(foreign, "GROUP_CONCAT") {
		t.Fatal("native composite foreign keys lost ordered individual members")
	}
	if query, _, err := catalogQuery(protocol.CatalogRequest{Kind: "unknownFutureOperation"}); err == nil || query != "" {
		t.Fatal("unimplemented catalog action became a successful empty observation")
	}
	query, args, err := catalogObjectLookup(protocol.CatalogRequest{Kind: "name", ObjectKind: "sequence", Schema: "fixture", Object: "native_sequence"})
	if err != nil || !strings.Contains(query, "TABLE_TYPE=?") || len(args) != 3 || args[2] != "SEQUENCE" {
		t.Fatal("native sequence identity was treated as an ordinary table")
	}
}
