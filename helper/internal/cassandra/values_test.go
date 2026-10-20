package cassandra

import (
	"encoding/binary"
	"math/big"
	"testing"

	gocql "github.com/apache/cassandra-gocql-driver/v2"
	"gopkg.in/inf.v0"
)

func native(typ gocql.Type) gocql.TypeInfo { return gocql.NewNativeType(5, typ, "") }
func TestCassandraScalarResultTypesMatchCatalogNames(t *testing.T) {
	for typ, want := range map[gocql.Type]string{gocql.TypeText: "text", gocql.TypeVarchar: "text", gocql.TypeInt: "int", gocql.TypeBlob: "blob", gocql.TypeDecimal: "decimal", gocql.TypeTimestamp: "timestamp"} {
		if typeName(native(typ)) != want {
			t.Fatal("scalar result type does not match canonical catalog type")
		}
	}
}
func TestCassandraLosslessCQLValues(t *testing.T) {
	decimal, _ := new(inf.Dec).SetString("123456789012345678901234567890.0000012300")
	integer, _ := new(big.Int).SetString("12345678901234567890123456789012345678901234567890", 10)
	tuple := gocql.TupleTypeInfo{Elems: []gocql.TypeInfo{native(gocql.TypeText), native(gocql.TypeInt)}}
	udt := gocql.UDTTypeInfo{Keyspace: "ks", Name: "entry", Elements: []gocql.UDTField{{Name: "label", Type: native(gocql.TypeText)}, {Name: "amount", Type: native(gocql.TypeDecimal)}}}
	for _, tc := range []struct {
		name  string
		info  gocql.TypeInfo
		value any
		want  string
	}{
		{"empty text", native(gocql.TypeText), "", ""},
		{"literal NULL", native(gocql.TypeText), "NULL", "NULL"},
		{"decimal", native(gocql.TypeDecimal), decimal, decimal.String()},
		{"varint", native(gocql.TypeVarint), integer, integer.String()},
		{"blob", native(gocql.TypeBlob), []byte{0, 255, 1}, "AP8B"},
		{"empty blob", native(gocql.TypeBlob), []byte{}, ""},
		{"timestamp extreme", native(gocql.TypeTimestamp), int64(-1 << 63), "-9223372036854775808"},
		{"tuple", tuple, []any{"a'b", nil}, "('a''b', null)"},
		{"all-null tuple", tuple, []any{nil, nil}, "(null, null)"},
		{"list", gocql.NewNativeType(5, gocql.TypeCustom, "list<text>"), []string{"NULL", "", "a'b"}, "['NULL', '', 'a''b']"},
		{"map", gocql.NewNativeType(5, gocql.TypeCustom, "map<text, blob>"), map[string][]byte{"data": {0, 255}}, "{'data': 0x00ff}"},
		{"UDT", udt, map[string]any{"label": "NULL", "amount": decimal}, `{"label": 'NULL', "amount": ` + decimal.String() + `}`},
		{"vector", gocql.VectorType{SubType: native(gocql.TypeFloat), Dimensions: 3}, []float32{1.25, -2.5, 0}, "[1.25, -2.5, 0]"},
		{"duration", native(gocql.TypeDuration), gocql.Duration{Months: -1, Days: -2, Nanoseconds: -3}, "-1mo2d3ns"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			data, err := gocql.Marshal(tc.info, tc.value)
			if err != nil {
				t.Fatal(err)
			}
			value, err := renderValue(tc.info, data, false)
			if err != nil {
				t.Fatal(err)
			}
			if value == nil || *value != tc.want {
				t.Fatalf("value=%v, want %q", value, tc.want)
			}
			null, err := renderValue(tc.info, nil, false)
			if err != nil || null != nil {
				t.Fatalf("NULL became %v, %v", null, err)
			}
		})
	}
}
func TestCassandraRawTuplePreservesOuterNULL(t *testing.T) {
	info := gocql.TupleTypeInfo{Elems: []gocql.TypeInfo{native(gocql.TypeInt), native(gocql.TypeInt)}}
	var raw rawValue
	if err := gocql.Unmarshal(wholeTuple{info}, nil, &raw); err != nil {
		t.Fatal(err)
	}
	if raw.data != nil {
		t.Fatal("NULL tuple lost")
	}
	data, err := gocql.Marshal(info, []any{nil, nil})
	if err != nil {
		t.Fatal(err)
	}
	if err := gocql.Unmarshal(wholeTuple{info}, data, &raw); err != nil {
		t.Fatal(err)
	}
	value, err := renderValue(raw.info, raw.data, false)
	if err != nil || value == nil || *value != "(null, null)" {
		t.Fatalf("all-null tuple=%v,%v", value, err)
	}
}
func TestCassandraMalformedCollectionsAreRejected(t *testing.T) {
	info := gocql.NewNativeType(5, gocql.TypeCustom, "list<text>")
	for _, data := range [][]byte{{0, 0, 0}, {255, 255, 255, 255}, {0, 0, 0, 1, 0, 0, 0, 5, 'x'}} {
		if _, err := renderValue(info, data, false); err == nil {
			t.Fatal("malformed value accepted")
		}
	}
	var prefix [4]byte
	binary.BigEndian.PutUint32(prefix[:], 0xffffffff)
	if value, err := renderValue(native(gocql.TypeBlob), prefix[:], false); err != nil || value == nil || *value != "/////w==" {
		t.Fatal("blob bytes altered")
	}
}

func TestCassandraDecimalExtremeScalesHaveBoundedExactScientificRendering(t *testing.T) {
	for _, test := range []struct {
		scale       int32
		coefficient byte
		want        string
	}{{2147483647, 1, "1E-2147483647"}, {-2147483648, 1, "1E2147483648"}, {2147483647, 255, "-1E-2147483647"}, {-2147483648, 0, "0E2147483648"}, {5000, 123, "123E-5000"}} {
		data := make([]byte, 5)
		binary.BigEndian.PutUint32(data, uint32(test.scale))
		data[4] = test.coefficient
		value, err := renderValue(native(gocql.TypeDecimal), data, false)
		if err != nil || value == nil || *value != test.want {
			t.Fatalf("scale=%d got=%v err=%v want=%s", test.scale, value, err, test.want)
		}
		if len(*value) > 32 {
			t.Fatal("decimal expanded scale padding")
		}
	}
}
