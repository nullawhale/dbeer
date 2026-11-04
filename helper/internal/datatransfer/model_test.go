package datatransfer

import (
	"encoding/base64"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

func text(value string) protocol.CellValue { return protocol.CellValue{Kind: "text", Value: &value} }
func TestTransferInferenceChecksEveryValueAndKeepsEmptyNullAndLeadingText(t *testing.T) {
	rows := [][]protocol.CellValue{{text("1"), text("1.25"), text(""), {Kind: "null"}}, {text("9007199254740993"), text("0.001"), text("NULL"), text("true")}}
	columns, _ := Infer([]string{"value", "value", "", "enabled"}, rows, "postgresql")
	if len(columns) != 4 || columns[0].Type != "integer" || columns[1].Type != "decimal" || columns[1].Precision != 4 || columns[1].Scale != 3 || columns[0].Name == columns[1].Name || columns[2].Name == "" || columns[2].Type != "text" || !columns[3].Nullable || columns[3].Type != "boolean" {
		t.Fatal("inference merged columns or lost null/text/exact numeric distinctions")
	}
	rows = append(rows, []protocol.CellValue{text("trailing text"), text("1"), text(""), text("false")})
	columns, _ = Infer([]string{"a", "b", "c", "d"}, rows, "mysql")
	if columns[0].Type != "text" {
		t.Fatal("a later input row was excluded from inference")
	}
}
func TestTransferExactDecimalNormalizationAndBounds(t *testing.T) {
	for _, test := range []struct {
		input, canonical string
		precision, scale int
	}{{"1.2500", "1.25", 3, 2}, {"1e3", "1000", 4, 0}, {".001", "0.001", 3, 3}, {"-0.00", "0", 1, 0}, {"9007199254740993.01", "9007199254740993.01", 18, 2}} {
		value, p, s, err := Decimal(test.input)
		if err != nil || value != test.canonical || p != test.precision || s != test.scale {
			t.Fatal("decimal normalization changed exact value or precision")
		}
	}
	for _, invalid := range []string{"NaN", "Infinity", "1e1001", "0x20", "1,2"} {
		if _, _, _, err := Decimal(invalid); err == nil {
			t.Fatal("invalid decimal accepted")
		}
	}
	c := protocol.TransferColumn{SourceIndex: 0, Name: "amount", Type: "decimal", Precision: 5, Scale: 2}
	for _, invalid := range []string{"1000", "1.001"} {
		if _, err := Normalize(text(invalid), c, "mysql"); err == nil {
			t.Fatal("lossy decimal precision or scale conversion accepted")
		}
	}
}

func TestTransferInferenceKeepsIdentifierAndSignedZeroSpellingsTextual(t *testing.T) {
	for _, value := range []string{"001", "-0", "-0.000", "null", "1e999"} {
		columns, _ := Infer([]string{"value"}, [][]protocol.CellValue{{text(value)}}, "mysql")
		if columns[0].Type != "text" {
			t.Fatal("identifier, signed zero or unrepresentable numeric spelling was implicitly converted")
		}
	}
}
func TestTransferNullBinaryTemporalAndIdentifierChecks(t *testing.T) {
	column := protocol.TransferColumn{SourceIndex: 0, Name: "value", Type: "text"}
	if _, err := Normalize(protocol.CellValue{Kind: "null"}, column, "postgresql"); err == nil {
		t.Fatal("nullability violation accepted")
	}
	column.Nullable = true
	if value, err := Normalize(text("NULL"), column, "postgresql"); err != nil || *value.Value != "NULL" {
		t.Fatal("text NULL changed storage kind")
	}
	column.Type = "binary"
	raw := base64.StdEncoding.EncodeToString([]byte{0, 0xff, 1})
	if value, err := Normalize(protocol.CellValue{Kind: "binary", Value: &raw}, column, "mysql"); err != nil || value.Kind != "binary" {
		t.Fatal("exact binary payload rejected")
	}
	if _, err := Normalize(text(raw), column, "mysql"); err == nil {
		t.Fatal("text was implicitly decoded as binary")
	}
	column.Type = "date"
	if _, err := Normalize(text("2026-02-30"), column, "postgresql"); err == nil {
		t.Fatal("invalid calendar date accepted")
	}
	column.Type = "timestampTZ"
	if _, err := Normalize(text("2026-01-01T00:00:00.000000001Z"), column, "mysql"); err == nil {
		t.Fatal("sub-microsecond temporal truncation accepted")
	}
	if ValidateTarget("postgresql", "public", strings.Repeat("x", 64)) == nil {
		t.Fatal("PostgreSQL silently truncated target name allowed")
	}
}
