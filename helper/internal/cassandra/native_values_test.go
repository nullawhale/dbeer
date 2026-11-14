package cassandra

import (
	"encoding/binary"
	"testing"

	"dbeer/helper/internal/protocol"
	gocql "github.com/apache/cassandra-gocql-driver/v2"
)

func TestNativeCQLRawCollectionsRetainOrderDuplicatesAndNullTuples(t *testing.T) {
	text := gocql.NewNativeType(4, gocql.TypeText, "")
	mapType := gocql.NewNativeType(5, gocql.TypeCustom, "map<text, bigint>")
	field := func(data []byte) []byte {
		prefix := make([]byte, 4)
		binary.BigEndian.PutUint32(prefix, uint32(len(data)))
		return append(prefix, data...)
	}
	encoded := []byte{0, 0, 0, 2}
	for _, number := range []uint64{9007199254740993, 9007199254740994} {
		encoded = append(encoded, field([]byte("same"))...)
		data := make([]byte, 8)
		binary.BigEndian.PutUint64(data, number)
		encoded = append(encoded, field(data)...)
	}
	row, err := nativeCQLRow([]rawValue{{info: mapType, data: encoded}})
	if err != nil || len(row) != 1 || row[0].Kind != "map" || len(row[0].Entries) != 2 || *row[0].Entries[0].Value.Value != "9007199254740993" || *row[0].Entries[1].Value.Value != "9007199254740994" {
		t.Fatal("CQL ordered map entries lost")
	}
	tuple := gocql.TupleTypeInfo{Elems: []gocql.TypeInfo{text, text}}
	row, err = nativeCQLRow([]rawValue{{info: tuple, data: nil}, {info: tuple, data: []byte{255, 255, 255, 255, 255, 255, 255, 255}}})
	if err != nil || row[0].Kind != "null" || row[1].Kind != "tuple" || len(row[1].Items) != 2 || row[1].Items[0].Kind != "null" {
		t.Fatal("NULL tuple conflated with tuple containing NULL")
	}
	if !protocol.NativeMatrixValid([][]protocol.NativeValue{row}, 1, 2) {
		t.Fatal("CQL native matrix invalid")
	}
}
