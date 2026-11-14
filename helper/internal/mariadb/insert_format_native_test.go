package mariadb

import (
	"encoding/base64"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestMariaDBOfflineInsertsPreserveTextJSONAndValueKinds(t *testing.T) {
	value := func(kind, text string) protocol.CellValue { return protocol.CellValue{Kind: kind, Value: &text} }
	request := protocol.InsertFormatRequest{Engine: "mariadb", Schema: "schema`quoted", Table: "table`quoted", Columns: []protocol.InsertFormatColumn{{Name: "payload"}}, Rows: [][]protocol.CellValue{{{Kind: "null"}}, {value("text", "")}, {value("text", "NULL")}, {value("text", "{\"a\":1, \"a\":2}")}, {value("binary", base64.StdEncoding.EncodeToString([]byte{0, 128, 255}))}, {{Kind: "default"}}}}
	sql, err := FormatInserts(request)
	if err != nil || !strings.Contains(sql, "`schema``quoted`.`table``quoted`") || !strings.Contains(sql, "(NULL)") || !strings.Contains(sql, "CONVERT(X'' USING utf8mb4)") || !strings.Contains(sql, "4e554c4c") || !strings.Contains(sql, "7b2261223a312c202261223a327d") || !strings.Contains(sql, "X'0080ff'") || !strings.Contains(sql, "(DEFAULT)") {
		t.Fatal("offline native formatting changed quoting, JSON spelling or value kinds")
	}
	request.Engine = "mysql"
	if _, err := FormatInserts(request); err == nil {
		t.Fatal("native formatter admitted another engine identity")
	}
}
