package mysql

import (
	"dbeer/helper/internal/protocol"
	"encoding/binary"
	"encoding/json"
	wire "github.com/go-mysql-org/go-mysql/mysql"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestNativeMySQLTextDriverFloatsNeverBecomeCapturedIEEE(t *testing.T) {
	fields := []*wire.Field{{Type: wire.MYSQL_TYPE_FLOAT}, {Type: wire.MYSQL_TYPE_DOUBLE, Decimal: 31}}
	data := append(wire.PutLengthEncodedString([]byte("1.000000")), wire.PutLengthEncodedString([]byte("1.0000000000000002"))...)
	values, e := wire.RowData(data).ParseText(fields, nil)
	if e != nil || values[0].Type != wire.FieldValueTypeFloat {
		t.Fatal("actual text driver path unavailable")
	}
	raw, e := nativeTextFields(data, len(fields))
	if e != nil {
		t.Fatal(e)
	}
	columns := make([]protocol.Column, len(fields))
	for i, f := range fields {
		columns[i] = protocol.Column{NativeType: nativeType(f), TypeIdentity: mysqlWireTypeIdentity(f)}
	}
	row := nativeMySQLRow(columns, fields, values, raw)
	if row[0].Kind != "native" || *row[0].Value != "1.000000" || !strings.HasPrefix(row[0].TypeIdentity, "unresolved:") || row[1].Kind != "native" || *row[1].Value != "1.0000000000000002" {
		t.Fatal("text float provenance or original bytes were changed")
	}
	packet := make([]byte, 6)
	binary.LittleEndian.PutUint32(packet[2:], math.Float32bits(math.Nextafter32(1, 2)))
	parsed, e := wire.RowData(packet).ParseBinary(fields[:1], nil)
	if e != nil {
		t.Fatal(e)
	}
	captured := nativeMySQLRow(columns[:1], fields[:1], parsed, nil)
	if captured[0].Kind != "float32" || *captured[0].Value != "3f800001" {
		t.Fatal("actual binary float bits were lost")
	}
	for _, bad := range [][]byte{nil, {1}, {0, 0}} {
		if _, e := nativeTextFields(bad, 1); e == nil {
			t.Fatal("malformed or trailing raw text admitted")
		}
	}
}
func TestNativeMySQLResolvedScalarFixtureMatchesProducer(t *testing.T) {
	var fixture struct {
		MySQL []struct {
			Column protocol.Column      `json:"column"`
			Native protocol.NativeValue `json:"native"`
		} `json:"mysql"`
	}
	data, e := os.ReadFile(filepath.Join("..", "..", "..", "protocol", "fixtures", "native-scalar-bindings-v1.json"))
	if e != nil {
		t.Fatal(e)
	}
	if json.Unmarshal(data, &fixture) != nil || len(fixture.MySQL) != 6 {
		t.Fatal("fixture invalid")
	}
	for _, entry := range fixture.MySQL {
		var identity struct {
			Type     byte
			Charset  uint16
			Length   uint32
			Decimals byte
			Flags    uint16
		}
		if json.Unmarshal([]byte(entry.Column.TypeIdentity), &identity) != nil {
			t.Fatal("identity")
		}
		field := &wire.Field{Type: identity.Type, Charset: identity.Charset, ColumnLength: identity.Length, Decimal: identity.Decimals, Flag: identity.Flags}
		if mysqlWireTypeIdentity(field) != entry.Column.TypeIdentity || nativeType(field) != entry.Column.NativeType {
			t.Fatal("fixture native metadata changed")
		}
		packet := wire.PutLengthEncodedString([]byte(*entry.Native.Value))
		values, e := wire.RowData(packet).ParseText([]*wire.Field{field}, nil)
		if e != nil {
			t.Fatal(e)
		}
		raw, e := nativeTextFields(packet, 1)
		if e != nil {
			t.Fatal(e)
		}
		row := nativeMySQLRow([]protocol.Column{entry.Column}, []*wire.Field{field}, values, raw)
		if !reflect.DeepEqual(row[0], entry.Native) {
			t.Fatal("resolved native scalar fixture changed")
		}
	}
}
