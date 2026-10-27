package mysql

import (
	"fmt"
	"reflect"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestOfflineInsertMySQLRoundTripsTypedValuesAcrossSQLModes(t *testing.T) {
	service := integrationSession(t)
	name := fmt.Sprintf("dbeer_copy_%x_`\\target", service.connectionID)
	quoted := QuoteIdentifier(name)
	textColumn := "text`\\value"
	run(t, service, "CREATE TEMPORARY TABLE "+quoted+" (id INT, "+QuoteIdentifier(textColumn)+` TEXT, nullable TEXT, empty_text TEXT,
 default_text VARCHAR(80) DEFAULT 'server-default', bytes VARBINARY(8), empty_bytes VARBINARY(8), amount DECIMAL(40,20)) DEFAULT CHARACTER SET utf8mb4`)
	precise := "12345678901234567890.12345678901234567890"
	literal := "quote' \\ backslash\t\r\nzero\x00κόσμος 🌍'); DROP TABLE anything; --"
	request := protocol.InsertFormatRequest{Engine: "mysql", Schema: integrationSettings(t).Database, Table: name,
		Columns: []protocol.InsertFormatColumn{{Name: "id"}, {Name: textColumn}, {Name: "nullable"}, {Name: "empty_text"}, {Name: "default_text"}, {Name: "bytes"}, {Name: "empty_bytes"}, {Name: "amount"}},
		Rows: [][]protocol.CellValue{
			{typedText("1"), typedText(literal), {Kind: "null"}, typedText(""), {Kind: "default"}, typedBinary("AP+A"), typedBinary(""), typedText(precise)},
			{typedText("2"), typedText("NULL"), typedText("NULL"), typedText("DEFAULT"), typedText("DEFAULT"), {Kind: "null"}, typedBinary(""), typedText(precise)},
		}}
	expected := [][]protocol.CellValue{
		{typedText("1"), typedText(literal), {Kind: "null"}, typedText(""), typedText("server-default"), typedBinary("AP+A"), typedBinary(""), typedText(precise)},
		request.Rows[1],
	}
	for _, mode := range []string{"DEFAULT", "'NO_BACKSLASH_ESCAPES'", "'ANSI_QUOTES'", "'NO_BACKSLASH_ESCAPES,ANSI_QUOTES'"} {
		t.Run(mode, func(t *testing.T) {
			run(t, service, "TRUNCATE "+quoted)
			run(t, service, "SET SESSION sql_mode="+mode)
			sql, err := FormatInserts(request)
			if err != nil {
				t.Fatal("valid offline MySQL formatting failed")
			}
			if *run(t, service, "SELECT COUNT(*) FROM "+quoted).Rows[0][0] != "0" {
				t.Fatal("formatting executed SQL")
			}
			// The MySQL connection deliberately disables CLIENT_MULTI_STATEMENTS.
			// Native Run Script submits each statement separately. Construct
			// those statements from the same rows and require their concatenation
			// to match the entire copied script before executing any of them.
			var statements []string
			for _, row := range request.Rows {
				single := request
				single.Rows = [][]protocol.CellValue{row}
				statement, err := FormatInserts(single)
				if err != nil {
					t.Fatal("valid offline MySQL single-row formatting failed")
				}
				statements = append(statements, statement)
			}
			if strings.Join(statements, "\n") != sql {
				t.Fatal("single-statement execution would change the generated script")
			}
			for _, statement := range statements {
				run(t, service, statement)
			}
			for index, predicate := range []string{"id=1", "id=2"} {
				if !reflect.DeepEqual(originalRow(t, service, name, predicate), expected[index]) {
					t.Fatal("generated MySQL INSERT changed an exact, typed or escaped value")
				}
			}
		})
	}
}
