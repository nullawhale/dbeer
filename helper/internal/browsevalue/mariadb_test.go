package browsevalue

import (
	"dbeer/helper/internal/protocol"
	"testing"
)

func TestMariaDBNumericSourcePreservesNativeIEEEAndUnsignedIdentity(t *testing.T) {
	value := "18446744073709551615"
	operand := protocol.NativeCellFilterValue{SourceEngine: "mariadb", SourceType: "bigint(20) unsigned", Cell: protocol.CellValue{Kind: "text", Value: &value}, SQLiteStorage: "preserve"}
	got, e := Server(operand, Target{Numeric: true})
	if e != nil || got.Value == nil || *got.Value != value {
		t.Fatal("native unsigned numeric source lost exactness")
	}
	value = "0.1"
	operand.SourceType = "double"
	if _, e = Server(operand, Target{Numeric: true, FloatBits: 32}); e == nil {
		t.Fatal("native binary64 source was rounded to binary32")
	}
	value = "0.5"
	if _, e = Server(operand, Target{Numeric: true, FloatBits: 32}); e != nil {
		t.Fatal("exact native IEEE value was refused")
	}
}
