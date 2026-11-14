package datatransfer

import (
	"dbeer/helper/internal/protocol"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestMariaDBTransferNativeBoundsAndExactText(t *testing.T) {
	ptr := func(s string) *string { return &s }
	decimal := protocol.TransferColumn{SourceIndex: 0, Name: "exact", Type: "decimal", Precision: 65, Scale: 38, Nullable: true}
	value := protocol.CellValue{Kind: "text", Value: ptr("123456789012345678901234567.12345678901234567890123456789012345678")}
	normalized, e := Normalize(value, decimal, "mariadb")
	if e != nil || normalized.Value == nil || *normalized.Value != *value.Value || ValidateColumns([]protocol.TransferColumn{decimal}, "mariadb") != nil {
		t.Fatal("native65,38 transfer changed exact digits")
	}
	if _, e := Normalize(value, decimal, "mysql"); e == nil || ValidateColumns([]protocol.TransferColumn{decimal}, "mysql") == nil {
		t.Fatal("native scale38 widened MySQL's existing bound")
	}
	for _, typ := range []string{"text", "json"} {
		col := protocol.TransferColumn{SourceIndex: 0, Name: "value", Type: typ, Nullable: true}
		text := "NULL"
		if typ == "json" {
			text = "{\"a\":1, \"a\":2}"
		}
		got, e := Normalize(protocol.CellValue{Kind: "text", Value: &text}, col, "mariadb")
		if e != nil || got.Value == nil || *got.Value != text {
			t.Fatal("native JSON/text spelling was normalized")
		}
	}
	name := strings.Repeat("界", 64)
	if ValidateTarget("mariadb", name, name) != nil || ValidateColumns([]protocol.TransferColumn{{SourceIndex: 0, Name: name, Type: "text"}}, "mariadb") != nil {
		t.Fatal("native64-character identifiers were treated as64bytes")
	}
	if ValidateTarget("mariadb", name+"x", name) == nil || ValidateColumns([]protocol.TransferColumn{{SourceIndex: 0, Name: "Mixed", Type: "text"}, {SourceIndex: 1, Name: "mixed", Type: "text"}}, "mariadb") == nil {
		t.Fatal("native length/case collision was admitted")
	}
	inferred, _ := Infer([]string{name, name}, [][]protocol.CellValue{{{Kind: "text", Value: ptr("literal")}, {Kind: "text", Value: ptr("literal")}}}, "mariadb")
	if len(inferred) != 2 || inferred[0].Name == inferred[1].Name || utf8.RuneCountInString(inferred[1].Name) > 64 || !utf8.ValidString(inferred[1].Name) {
		t.Fatal("native duplicate inference truncated inside a character")
	}
	for _, typ := range []string{"date", "timestamp"} {
		col := protocol.TransferColumn{SourceIndex: 0, Name: "temporal", Type: typ}
		raw := "0999-01-01"
		if typ == "timestamp" {
			raw += " 00:00:00"
		}
		if _, e := Normalize(protocol.CellValue{Kind: "text", Value: &raw}, col, "mariadb"); e == nil {
			t.Fatal("native temporal floor was not checked")
		}
	}
}
