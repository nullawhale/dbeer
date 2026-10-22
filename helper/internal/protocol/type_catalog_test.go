package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

func typeCatalogFrame(catalog string) []byte {
	return []byte(`{"type":"catalog","requestId":"type-request","sessionId":"type-session","queryId":"type-query","catalog":` + catalog + `}`)
}

func TestPostgresTypeCatalogStrictVariantsAndEmptyLabels(t *testing.T) {
	base := `"schema":"odd schema","object":"enum 猫","objectKind":"enum","identity":"4294967295"`
	for _, change := range []string{
		`{"operation":"renameType","newName":" "}`,
		`{"operation":"addEnumValue","value":""}`,
		`{"operation":"addEnumValue","value":"�"}`,
		`{"operation":"renameEnumValue","oldValue":"","value":"NULL"}`,
		`{"operation":"renameEnumValue","oldValue":"quote'\\猫","value":"` + strings.Repeat("猫", 21) + `"}`,
	} {
		command, err := ParseCommand(typeCatalogFrame(`{"kind":"typeDDL",` + base + `,"typeChange":` + change + `}`))
		if err != nil || command.Catalog == nil || command.Catalog.TypeChange == nil || !command.Catalog.Valid() {
			t.Fatal("valid presence-aware type preview was rejected")
		}
		encoded, _ := json.Marshal(command)
		decoded, err := ParseCommand(encoded)
		if err != nil || decoded.Catalog.TypeChange.Value == nil != (command.Catalog.TypeChange.Value == nil) {
			t.Fatal("type preview lost field presence on the wire")
		}
		if strings.Contains(change, `"value":""`) && *decoded.Catalog.TypeChange.Value != "" {
			t.Fatal("empty enum label changed during round trip")
		}
	}
	for _, kind := range []string{"typeDetails", "enumValues", "typeDependencies", "definition", "name"} {
		if _, err := ParseCommand(typeCatalogFrame(`{"kind":"` + kind + `",` + base + `}`)); err != nil {
			t.Fatal("valid connection-local type request was rejected")
		}
	}
	for _, kind := range []string{"enum", "type"} {
		if _, err := ParseCommand(typeCatalogFrame(`{"kind":"objects","schema":"public","objectKind":"` + kind + `"}`)); err != nil {
			t.Fatal("type catalog group was rejected")
		}
	}
	// Cassandra UDT definition/name inspection still has no PostgreSQL OID.
	for _, kind := range []string{"definition", "name"} {
		if _, err := ParseCommand(typeCatalogFrame(`{"kind":"` + kind + `","schema":"demo","object":"address","objectKind":"type"}`)); err != nil {
			t.Fatal("existing Cassandra UDT request was rejected")
		}
	}
}

func TestPostgresTypeCatalogRejectsUnsafeOrIgnoredFields(t *testing.T) {
	base := `"schema":"public","object":"status","objectKind":"enum","identity":"1234"`
	var invalid []string
	for _, change := range []string{
		`null`, `[]`, `{}`, `{"operation":"unknown","value":"secret-input"}`,
		`{"operation":"renameType"}`, `{"operation":"renameType","newName":""}`,
		`{"operation":"renameType","newName":null}`, `{"operation":"renameType","newName":"x","value":""}`,
		`{"operation":"addEnumValue"}`, `{"operation":"addEnumValue","value":null}`,
		`{"operation":"addEnumValue","value":"x","newName":""}`, `{"operation":"addEnumValue","value":"x","oldValue":""}`,
		`{"operation":"addEnumValue","value":"x","ifNotExists":false}`,
		`{"operation":"addEnumValue","value":"x","before":""}`,
		`{"operation":"renameEnumValue","value":"x"}`, `{"operation":"renameEnumValue","oldValue":null,"value":"x"}`,
		`{"operation":"renameEnumValue","oldValue":"","value":"x","newName":""}`,
		`{"operation":"addEnumValue","value":"\u0000"}`,
		`{"operation":"renameType","newName":"` + strings.Repeat("猫", 22) + `"}`,
		`{"operation":"addEnumValue","value":"` + strings.Repeat("a", 64) + `"}`,
		`{"operation":"renameEnumValue","oldValue":"` + strings.Repeat("a", 64) + `","value":"x"}`,
	} {
		invalid = append(invalid, `{"kind":"typeDDL",`+base+`,"typeChange":`+change+`}`)
	}
	for _, field := range []string{`"page":0`, `"sort":[]`, `"filters":[]`, `"search":""`, `"cursor":""`, `"sql":"secret-input"`} {
		for _, kind := range []string{"typeDetails", "enumValues", "typeDependencies"} {
			invalid = append(invalid, `{"kind":"`+kind+`",`+base+`,`+field+`}`)
		}
		invalid = append(invalid, `{"kind":"typeDDL",`+base+`,"typeChange":{"operation":"addEnumValue","value":""},`+field+`}`)
	}
	for _, oid := range []string{"", "0", "01", "+1", "-1", "4294967296", "1.0", "0x10", " 1"} {
		invalid = append(invalid, `{"kind":"typeDetails","schema":"public","object":"status","objectKind":"enum","identity":"`+oid+`"}`)
	}
	invalid = append(invalid,
		`{"kind":"typeDetails","schema":"public","object":"status","objectKind":"enum"}`,
		`{"kind":"typeDetails",`+base+`,"typeChange":{"operation":"addEnumValue","value":""}}`,
		`{"kind":"typeDDL",`+base+`}`,
		`{"kind":"typeDetails","schema":"`+strings.Repeat("a", 64)+`","object":"status","objectKind":"enum","identity":"1"}`,
		`{"kind":"typeDetails","schema":"public","object":"`+strings.Repeat("猫", 22)+`","objectKind":"enum","identity":"1"}`,
		`{"kind":"typeDetails","schema":"public","object":"status","objectKind":"table","identity":"1"}`,
		`{"kind":"typeDetails",`+base+`,"identity":"2"}`)
	for index, raw := range invalid {
		_, err := ParseCommand(typeCatalogFrame(raw))
		if err == nil || strings.Contains(err.Error(), "secret-input") {
			t.Fatalf("unsafe type request %d was accepted or disclosed input", index)
		}
	}
	frame := typeCatalogFrame(`{"kind":"typeDDL",` + base + `,"typeChange":{"operation":"addEnumValue","value":"x"}}`)
	frame[len(frame)-5] = 0xff
	if _, err := ParseCommand(frame); err == nil {
		t.Fatal("invalid UTF-8 type request was accepted")
	}
}
