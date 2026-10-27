package mysql

import (
	"encoding/binary"
	"testing"
)

func TestDataTextRowsNeverConvertNumbersAndPreserveNullBytes(t *testing.T) {
	values := []string{"9007199254740993.12345678901234567890", "18446744073709551615", "1.2345678901234567", "", "NULL", string([]byte{0, 255})}
	data := []byte{0xfb}
	for _, value := range values {
		data = append(data, byte(len(value)))
		data = append(data, []byte(value)...)
	}
	row, e := decodeDataTextRow(data, len(values)+1)
	if e != nil || row[0] != nil {
		t.Fatal("wire NULL lost")
	}
	for i, v := range values {
		if row[i+1] == nil || *row[i+1] != v {
			t.Fatal("wire field bytes changed")
		}
	}
	for _, bad := range [][]byte{{0xfc, 1}, {1}, {0, 0}} {
		if _, e := decodeDataTextRow(bad, 1); e == nil {
			t.Fatal("malformed row admitted")
		}
	}
	large := make([]byte, 3+300)
	large[0] = 0xfc
	binary.LittleEndian.PutUint16(large[1:3], 300)
	if row, e := decodeDataTextRow(large, 1); e != nil || len(*row[0]) != 300 {
		t.Fatal("length-encoded field failed")
	}
}
