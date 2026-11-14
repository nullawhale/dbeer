package mariadb

import (
	"encoding/base64"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
	tc "dbeer/helper/internal/tablecapture"
)

func TestMariaDBFlowDecodePreservesExactWireScalars(t *testing.T) {
	payload := []byte{0xfb, 0, 4, 'N', 'U', 'L', 'L', 2, 0, 255, 16, '9', '0', '0', '7', '1', '9', '9', '2', '5', '4', '7', '4', '0', '9', '9', '3'}
	row, e := decodeFlowRow(payload, 5)
	if e != nil || row[0] != nil || *row[1] != "" || *row[2] != "NULL" || base64.StdEncoding.EncodeToString([]byte(*row[3])) != "AP8=" || *row[4] != "9007199254740993" {
		t.Fatal("exact NULL/empty/text NULL/binary/numeric wire distinction changed")
	}
	for _, b := range [][]byte{{}, payload[:len(payload)-1], append(payload, 0), {0xfc, 1}} {
		if _, e := decodeFlowRow(b, 5); e == nil {
			t.Fatal("malformed text row admitted")
		}
	}
}
func TestMariaDBFlowSQLBoundsAndNativeProjection(t *testing.T) {
	d := tc.Descriptor{Table: tc.Table{Schema: "s`?", Name: "t"}, Columns: []tc.Column{{Name: "id", TypeLabel: "bigint unsigned", Numeric: true}, {Name: "n", TypeLabel: "decimal(65,38)", Numeric: true}, {Name: "e", TypeLabel: "enum('','a')"}, {Name: "stamp", TypeLabel: "timestamp(6)"}}}
	exact := "9007199254740993.12345678901234567890123456789012345678"
	sql, e := mariaDBDataSQL(d, tc.Spec{Table: d.Table, Columns: []string{"id", "e", "stamp"}, Keys: []string{"id"}, ReadLimit: 2, Filters: []tc.Filter{{Column: "n", Operator: "eq", Value: &exact}}})
	if e != nil || !strings.Contains(sql, "`s``?`.`t`") || !strings.Contains(sql, "JSON_ARRAY(CAST(`e` AS UNSIGNED),HEX(`e`))") || !strings.Contains(sql, "UNIX_TIMESTAMP(`stamp`)") || !strings.Contains(sql, "DECIMAL(65,38)") || !strings.HasSuffix(sql, "LIMIT 3") {
		t.Fatal("native exact capture projection/filter/bound changed")
	}
	for _, v := range []string{strings.Repeat("9", 66), "0." + strings.Repeat("1", 39), "1;SELECT 1"} {
		if _, _, e := flowNumericParameter("decimal", v); e == nil {
			t.Fatal("outside native numeric bound admitted")
		}
	}
	if _, e := flowLiteral(protocol.CellValue{Kind: "default"}); e == nil {
		t.Fatal("authored DEFAULT gained literal authority")
	}
}
func TestMariaDBFlowTransferTypedBoundsAndOmission(t *testing.T) {
	columns := []protocol.TransferColumn{{Name: "n", Type: "decimal", Precision: 65, Scale: 38}, {SourceIndex: 1, Name: "j", Type: "json", Nullable: true}}
	sql, e := transferMariaDBDDL("s", "t", columns)
	if e != nil || !strings.Contains(sql, "DECIMAL(65,38)") || !strings.Contains(sql, "LONGTEXT CHARACTER SET utf8mb4 COLLATE utf8mb4_bin") {
		t.Fatal("native decimal or text-backed JSON contract changed")
	}
	columns[0].Scale = 39
	if _, e = transferMariaDBDDL("s", "t", columns); e == nil {
		t.Fatal("MariaDB scale39 admitted")
	}
	columns[0].Scale = 38
	columns[1].Name = "N"
	if _, e = transferMariaDBDDL("s", "t", columns); e == nil {
		t.Fatal("native case-insensitive duplicate target name admitted")
	}
}
