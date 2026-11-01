package tableimport

import (
	"dbeer/helper/internal/protocol"
	"strings"
	"testing"
)

func TestImportMappingOmitsDefaultsAndRequiresNoPrimaryKey(t *testing.T) {
	columns := []Column{{TableImportColumn: protocol.TableImportColumn{Name: "id", HasDefault: true}, Writable: true, Supported: true}, {TableImportColumn: protocol.TableImportColumn{Name: "label"}, Writable: true, Supported: true}, {TableImportColumn: protocol.TableImportColumn{Name: "computed", Generated: true}, Supported: true}}
	fingerprint := strings.Repeat("a", 64)
	value := "exact"
	request := protocol.TableImportRequest{Schema: "s", Table: "t", Fingerprint: fingerprint, Columns: []string{"label"}, Rows: [][]protocol.CellValue{{{Kind: "text", Value: &value}}}}
	mapped, err := Validate(columns, fingerprint, request)
	if err != nil || len(mapped) != 1 || mapped[0].Name != "label" {
		t.Fatal("default-omitting keyless import rejected")
	}
	for _, field := range []string{"fingerprint", "required", "generated", "permission", "unsupported", "binary", "null"} {
		t.Run(field, func(t *testing.T) {
			copy := append([]Column(nil), columns...)
			r := request
			r.Rows = [][]protocol.CellValue{{{Kind: "text", Value: &value}}}
			switch field {
			case "fingerprint":
				r.Fingerprint = strings.Repeat("b", 64)
			case "required":
				copy[0].HasDefault = false
			case "generated":
				copy[1].Generated = true
			case "permission":
				copy[1].Writable = false
			case "unsupported":
				copy[1].Supported = false
			case "binary":
				copy[1].Binary = true
			case "null":
				r.Rows[0][0] = protocol.CellValue{Kind: "null"}
			}
			if _, err := Validate(copy, fingerprint, r); err == nil {
				t.Fatal("incompatible mapping accepted")
			}
		})
	}
}

func TestImportFingerprintIncludesNullDefaultAndColumnOrder(t *testing.T) {
	left := Fingerprint([]any{"column", nil, "", false})
	right := Fingerprint([]any{"column", "", "", false})
	if left == right || len(left) != 64 {
		t.Fatal("default NULL identity lost")
	}
	if Fingerprint([]string{"a", "b"}) == Fingerprint([]string{"b", "a"}) {
		t.Fatal("column order omitted")
	}
}

func TestImportDescriptionCannotExceedWireMetadataContract(t *testing.T) {
	columns := []Column{{TableImportColumn: protocol.TableImportColumn{Name: "label", NativeType: "text"}}}
	if !DescriptionValid(columns) {
		t.Fatal("valid metadata rejected")
	}
	columns[0].NativeType = strings.Repeat("x", 65537)
	if DescriptionValid(columns) {
		t.Fatal("oversized type description accepted")
	}
}
