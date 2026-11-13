package mongodb

import (
	"math"
	"testing"

	"dbeer/helper/internal/protocol"
	"go.mongodb.org/mongo-driver/v2/bson"
)

func TestNativeBSONRetainsOrderedDuplicateKeysAndScalarTags(t *testing.T) {
	decimal, err := bson.ParseDecimal128("9007199254740993.00000000000001")
	if err != nil {
		t.Fatal(err)
	}
	raw, err := bson.Marshal(bson.D{{Key: "é", Value: int64(9223372036854775807)}, {Key: "e\u0301", Value: decimal}, {Key: "é", Value: bson.A{nil, bson.Binary{Subtype: 0x80, Data: []byte{0, 255}}, math.Float64frombits(0x7ff8000000000001)}}})
	if err != nil {
		t.Fatal(err)
	}
	value, err := nativeDocument(raw)
	if err != nil || !value.Valid() || value.Kind != "object" || len(value.Entries) != 3 {
		t.Fatal("BSON native document unavailable")
	}
	if *value.Entries[0].Key.Value != "é" || *value.Entries[1].Key.Value != "e\u0301" || *value.Entries[2].Key.Value != "é" {
		t.Fatal("BSON keys normalized or deduplicated")
	}
	if value.Entries[0].Value.Kind != "integer" || *value.Entries[0].Value.Value != "9223372036854775807" || value.Entries[1].Value.Kind != "decimal" || *value.Entries[1].Value.Value != "9007199254740993.00000000000001" {
		t.Fatal("BSON numeric tag or precision lost")
	}
	items := value.Entries[2].Value.Items
	if len(items) != 3 || items[0].Kind != "null" || items[1].Kind != "binary" || items[1].NativeType != "binary:80" || *items[1].Value != "AP8=" || items[2].Kind != "float64" || *items[2].Value != "7ff8000000000001" {
		t.Fatal("BSON nested binary/NULL/NaN evidence changed")
	}
	if !protocol.NativeMatrixValid([][]protocol.NativeValue{{value}}, 1, 1) {
		t.Fatal("BSON native matrix invalid")
	}
}
