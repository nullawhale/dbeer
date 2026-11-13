package postgres

import (
	"encoding/json"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5/pgconn"
)

func TestNativePostgresWireValuesAreNotInferredFromDisplay(t *testing.T) {
	columns := []protocol.Column{{NativeType: "numeric", TypeOID: 1700}, {NativeType: "text", TypeOID: 25}, {NativeType: "bytea", TypeOID: 17, Encoding: "base64"}, {NativeType: "integer[]", TypeOID: 1007}, {NativeType: "real", TypeOID: 700}}
	values := [][]byte{[]byte("9007199254740993.00000001"), []byte("NULL"), []byte(`\x00ff`), []byte("[0:1]={1,2}"), []byte("-0")}
	row := nativePostgresRow(columns, values)
	if !protocol.NativeMatrixValid([][]protocol.NativeValue{row}, 1, len(columns)) || row[0].Kind != "decimal" || row[1].Kind != "text" || row[2].Kind != "binary" || row[3].Kind != "native" || row[4].Kind != "float32" {
		t.Fatal("PostgreSQL native kinds changed")
	}
	if *row[0].Value != string(values[0]) || *row[2].Value != "AP8=" || *row[3].Value != string(values[3]) || *row[4].Value != "80000000" {
		t.Fatal("PostgreSQL native payload changed")
	}
}

func TestNativePostgresCollectorBudgetsPairedRowsAsOnePrefix(t *testing.T) {
	collector := newResultCollector(protocol.Command{RequestID: "r", ResultValues: protocol.NativeResultValuesFormat}, []pgconn.FieldDescription{{Name: "v", DataTypeOID: 25}}, MaxResultBytes)
	text := strings.Repeat("x", protocol.MaxNativeValueBytes/3)
	for range 5 {
		collector.addRow([]*string{&text}, []protocol.NativeValue{protocol.NativeScalar("text", text)})
	}
	result := collector.finish(pgconn.NewCommandTag("SELECT 5"), 0, "idle")
	if len(result.Rows) != 2 || len(result.NativeValues) != 2 || !result.Truncated || result.RowCount != 5 {
		t.Fatal("typed prefix/outcome changed")
	}
	if _, err := json.Marshal(result); err != nil {
		t.Fatal("paired PostgreSQL result cannot serialize")
	}
}

func TestNativeRoundedPostgresFloatRetainsOriginalWireText(t *testing.T) {
	column := protocol.Column{NativeType: "double precision", TypeOID: 701, TypeIdentity: "unresolved:pgtype-v1:rounded"}
	raw := []byte("1.23456789012")
	value := nativePostgresRow([]protocol.Column{column}, [][]byte{raw})[0]
	if value.Kind != "native" || value.Value == nil || *value.Value != string(raw) || value.Comparable() {
		t.Fatal("rounded text became IEEE/equality authority")
	}
}

func TestNativePostgresBinaryFloatsPreserveWidthsPayloadsAndSignedZero(t *testing.T) {
	for _, test := range []struct {
		oid        uint32
		raw        []byte
		kind, text string
	}{
		{700, []byte{0x80, 0, 0, 0}, "float32", "80000000"},
		{700, []byte{0x7f, 0xc0, 0, 1}, "float32", "7fc00001"},
		{701, []byte{0x7f, 0xf8, 0, 0, 0, 0, 0, 1}, "float64", "7ff8000000000001"},
	} {
		value, _, ok := nativePostgresBinaryFloat(test.oid, test.raw)
		if !ok || value.Kind != test.kind || value.Value == nil || *value.Value != test.text {
			t.Fatal("binary float evidence changed")
		}
	}
	if _, _, ok := nativePostgresBinaryFloat(700, make([]byte, 8)); ok {
		t.Fatal("wrong IEEE width admitted")
	}
}
