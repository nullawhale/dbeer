package postgres

import (
	"reflect"
	"testing"

	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
)

func TestOfflineInsertPostgresRoundTripsTypedValuesAcrossStringModes(t *testing.T) {
	fixture := newChangeFixture(t)
	name := "copy\"; -- target"
	textColumn := "text\"; -- value"
	table := fixture.table(name)
	fixture.exec("CREATE TABLE " + table + " (id integer, " + pgx.Identifier{textColumn}.Sanitize() + ` text, nullable text, empty_text text,
 default_text text DEFAULT 'server-default', bytes bytea, empty_bytes bytea, amount numeric(40,20))`)
	precise := "12345678901234567890.12345678901234567890"
	literal := "quote' \\ backslash\t\r\nκόσμος 🌍\u2028'); DROP TABLE anything; --"
	request := protocol.InsertFormatRequest{Engine: "postgresql", Schema: fixture.schema, Table: name,
		Columns: []protocol.InsertFormatColumn{{Name: "id"}, {Name: textColumn}, {Name: "nullable"}, {Name: "empty_text"}, {Name: "default_text"}, {Name: "bytes"}, {Name: "empty_bytes"}, {Name: "amount"}},
		Rows: [][]protocol.CellValue{
			{changeText("1"), changeText(literal), {Kind: "null"}, changeText(""), {Kind: "default"}, changeBinary("AP+A"), changeBinary(""), changeText(precise)},
			{changeText("2"), changeText("NULL"), changeText("NULL"), changeText("DEFAULT"), changeText("DEFAULT"), {Kind: "null"}, changeBinary(""), changeText(precise)},
		}}
	expected := [][]protocol.CellValue{
		{changeText("1"), changeText(literal), {Kind: "null"}, changeText(""), changeText("server-default"), changeBinary("AP+A"), changeBinary(""), changeText(precise)},
		request.Rows[1],
	}
	for _, mode := range []string{"on", "off"} {
		fixture.exec("TRUNCATE " + table)
		fixture.exec("SET standard_conforming_strings=" + mode)
		sql, err := FormatInserts(request)
		if err != nil {
			t.Fatal("valid offline PostgreSQL formatting failed")
		}
		if fixture.scalar("SELECT count(*)::text FROM "+table) != "0" {
			t.Fatal("formatting executed SQL")
		}
		// Only this explicit test step executes the generated statements.
		fixture.exec(sql)
		for index, predicate := range []string{"id=1", "id=2"} {
			if !reflect.DeepEqual(fixture.snapshot(name, predicate), expected[index]) {
				t.Fatal("generated PostgreSQL INSERT changed an exact, typed or escaped value")
			}
		}
	}
}
