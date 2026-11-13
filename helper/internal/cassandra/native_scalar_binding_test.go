package cassandra

import (
	"bytes"
	"dbeer/helper/internal/protocol"
	"encoding/base64"
	"encoding/json"
	gocql "github.com/apache/cassandra-gocql-driver/v2"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

type scalarBindingRecord struct {
	Column protocol.Column      `json:"column"`
	Native protocol.NativeValue `json:"native"`
	Wire   string               `json:"wire"`
}

func TestNativeCQLResolvedScalarFixtureRoundTripsExistingBinder(t *testing.T) {
	var fixture struct {
		Cassandra   []scalarBindingRecord `json:"cassandra"`
		Unsupported []scalarBindingRecord `json:"cassandraUnsupported"`
	}
	data, e := os.ReadFile(filepath.Join("..", "..", "..", "protocol", "fixtures", "native-scalar-bindings-v1.json"))
	if e != nil {
		t.Fatal(e)
	}
	if json.Unmarshal(data, &fixture) != nil || len(fixture.Cassandra) != 5 || len(fixture.Unsupported) != 2 {
		t.Fatal("fixture invalid")
	}
	for _, entry := range fixture.Cassandra {
		raw, e := base64.StdEncoding.DecodeString(entry.Wire)
		if e != nil {
			t.Fatal(e)
		}
		info := gocql.NewNativeType(5, gocql.TypeCustom, entry.Native.NativeType)
		row, e := nativeCQLRow([]rawValue{{info: info, data: raw}})
		if e != nil || !reflect.DeepEqual(row[0], entry.Native) {
			t.Fatal("actual native scalar changed")
		}
		encoded, e := (textParameter{Value: *entry.Native.Value}).MarshalCQL(info)
		if e != nil || !bytes.Equal(encoded, raw) || !editScalarType(entry.Native.NativeType) {
			t.Fatal("existing binder did not retain original scalar bytes")
		}
		request, columns := changeFixture()
		columns[0].nativeType = entry.Native.NativeType
		request.Columns[0].NativeType = entry.Native.NativeType
		request.Changes[0].Original[0] = protocol.CellValue{Kind: "text", Value: entry.Native.Value}
		if _, reason := planChange(request, columns); reason != "" {
			t.Fatal("existing full-row change plan rejected native key")
		}
	}
	for _, entry := range fixture.Unsupported {
		raw, e := base64.StdEncoding.DecodeString(entry.Wire)
		if e != nil {
			t.Fatal(e)
		}
		info := gocql.NewNativeType(5, gocql.TypeCustom, entry.Native.NativeType)
		row, e := nativeCQLRow([]rawValue{{info: info, data: raw}})
		if e != nil || row[0].Kind != "opaque" || !reflect.DeepEqual(row[0], entry.Native) {
			t.Fatal("unroundtrippable scalar lost original raw bytes")
		}
	}

}
