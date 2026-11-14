package mariadb

import (
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestMariaDBRowsPlanBindsNativeEngineDefaultAndStorageEvidence(t *testing.T) {
	metadata := editMetadata{qualified: "`db`.`odd``table`", columns: []editColumn{{name: "id", dataType: "int", nativeType: "int(11)", primary: 1, read: true, insert: true, update: true}, {name: "payload", dataType: "longtext", nativeType: "longtext", nullable: true, read: true, insert: true, update: true}, {name: "f", dataType: "float", nativeType: "float", nullable: true, read: true, insert: true, update: true}}, primary: []int{0}}
	request := protocol.ChangesRequest{Schema: "db", Table: "odd`table", Columns: []protocol.SnapshotColumn{{Name: "id", Engine: "mariadb", NativeType: "int(11)"}, {Name: "payload", Engine: "mariadb", NativeType: "longtext"}, {Name: "f", Engine: "mariadb", NativeType: "float"}}, Changes: []protocol.RowChange{{Kind: "update", Original: []protocol.CellValue{rowCell("1"), rowCell("old"), rowCell("1.25")}, Values: []protocol.ColumnAssignment{{Column: "payload", Value: rowCell("private'value")}}}}}
	scope := mariaDBWriteScope{strictMode: "STRICT_ALL_TABLES,NO_AUTO_VALUE_ON_ZERO"}
	if _, err := planChanges(metadata, request, scope); err == nil {
		t.Fatal("native hidden storage state was admitted without an opaque witness")
	}
	request.Changes[0].StorageToken = "mariadb.storage.v1:" + strings.Repeat("a", 64)
	plans, err := planChanges(metadata, request, scope)
	if err != nil || len(plans) != 1 || !strings.Contains(plans[0].lockSQL, "`__dbeer_storage_0`") || strings.Contains(plans[0].sql, "private") || len(plans[0].parameters) != 2 {
		t.Fatal("native row plan lost exact storage lock or bound assignment parameters")
	}
	request.Changes[0].StorageToken = "mysql.storage.v1:" + strings.Repeat("a", 64)
	if _, err := planChanges(metadata, request, scope); err == nil {
		t.Fatal("another engine's opaque row witness authorized a MariaDB write")
	}
	request.Changes[0].StorageToken = "mariadb.storage.v1:" + strings.Repeat("a", 64)
	request.Changes[0].Values[0].Value = protocol.CellValue{Kind: "default"}
	plans, err = planChanges(metadata, request, scope)
	if err != nil || !strings.Contains(plans[0].sql, "`payload` = DEFAULT") || len(plans[0].parameters) != 1 {
		t.Fatal("DEFAULT was confused with a bound NULL or text value")
	}
	request.Changes[0].Values[0].Column = "unavailable"
	if _, err := planChanges(metadata, request, scope); err == nil {
		t.Fatal("an unavailable assignment silently selected a different column")
	}
}
