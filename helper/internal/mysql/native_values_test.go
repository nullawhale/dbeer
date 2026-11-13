package mysql

import (
	"math"
	"testing"

	"dbeer/helper/internal/protocol"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func TestNativeMySQLWireValuesKeepExactKindsAndWidths(t *testing.T) {
	fields := []*wire.Field{{Type: wire.MYSQL_TYPE_LONGLONG, Flag: wire.UNSIGNED_FLAG}, {Type: wire.MYSQL_TYPE_NEWDECIMAL}, {Type: wire.MYSQL_TYPE_BLOB, Charset: 63}, {Type: wire.MYSQL_TYPE_FLOAT}, {Type: wire.MYSQL_TYPE_FLOAT}}
	columns := make([]protocol.Column, len(fields))
	for index, field := range fields {
		columns[index] = protocol.Column{NativeType: nativeType(field), TypeIdentity: mysqlWireTypeIdentity(field)}
	}
	values := []wire.FieldValue{wire.NewFieldValue(wire.FieldValueTypeUnsigned, math.MaxUint64, nil), wire.NewFieldValue(wire.FieldValueTypeString, 0, []byte("9007199254740993.000000001")), wire.NewFieldValue(wire.FieldValueTypeString, 0, []byte{0, 255}), wire.NewFieldValue(wire.FieldValueTypeFloat, math.Float64bits(math.Copysign(0, -1)), nil), wire.NewFieldValue(wire.FieldValueTypeString, 0, []byte("0.1"))}
	row := nativeMySQLRow(columns, fields, values, nil)
	if !protocol.NativeMatrixValid([][]protocol.NativeValue{row}, 1, len(fields)) || row[0].Kind != "integer" || *row[0].Value != "18446744073709551615" || row[1].Kind != "decimal" || row[2].Kind != "binary" || *row[2].Value != "AP8=" || row[3].Kind != "float32" || *row[3].Value != "80000000" {
		t.Fatal("MySQL native wire fidelity changed")
	}
	if row[4].Kind != "native" || *row[4].Value != "0.1" {
		t.Fatal("lossy MySQL text float was promoted to invented IEEE evidence")
	}
}
