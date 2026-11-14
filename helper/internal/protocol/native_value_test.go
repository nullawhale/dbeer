package protocol

import (
	"encoding/json"
	"math"
	"os"
	"reflect"
	"strings"
	"testing"
)

func TestNativeValueSharedContract(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/native-result-values-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Capability, Format string
		Valid, Invalid     []json.RawMessage
		InvalidJSON        []string
	}
	if json.Unmarshal(data, &fixture) != nil || fixture.Capability != NativeResultValuesCapability || fixture.Format != NativeResultValuesFormat || len(fixture.Valid) < 20 || len(fixture.Invalid) < 20 {
		t.Fatal("invalid native value fixture")
	}
	for i, raw := range fixture.Valid {
		var value, roundTrip NativeValue
		if err := json.Unmarshal(raw, &value); err != nil || !value.Valid() {
			t.Fatalf("valid native case %d rejected: %v", i, err)
		}
		encoded, err := json.Marshal(value)
		if err != nil || json.Unmarshal(encoded, &roundTrip) != nil || !reflect.DeepEqual(value, roundTrip) {
			t.Fatalf("native case %d did not round trip", i)
		}
	}
	for i, raw := range fixture.Invalid {
		var value NativeValue
		if json.Unmarshal(raw, &value) == nil {
			t.Fatalf("invalid native case %d accepted", i)
		}
	}
	for i, raw := range fixture.InvalidJSON {
		var value NativeValue
		if json.Unmarshal([]byte(raw), &value) == nil {
			t.Fatalf("invalid native JSON case %d accepted", i)
		}
	}
}

func TestNativeValueBoundsAndBitPatterns(t *testing.T) {
	for _, value := range []NativeValue{NativeFloat32(float32(math.Copysign(0, -1))), NativeFloat64(math.Copysign(0, -1))} {
		if !value.Valid() || !strings.HasPrefix(*value.Value, "8") {
			t.Fatal("floating signed zero was lost")
		}
	}
	value := NativeValue{Kind: "null"}
	for i := 0; i < MaxNativeValueDepth; i++ {
		value = NativeValue{Kind: "list", Items: []NativeValue{value}}
	}
	if !value.Valid() {
		t.Fatal("maximum bounded depth rejected")
	}
	value = NativeValue{Kind: "list", Items: []NativeValue{value}}
	if value.Valid() {
		t.Fatal("excessive depth accepted")
	}
	large := NativeScalar("text", strings.Repeat("<", MaxNativeValueBytes/6))
	if large.Valid() {
		t.Fatal("escaped scalar bypassed byte budget")
	}
	row := []NativeValue{NativeScalar("text", strings.Repeat("x", MaxNativeValueBytes/3))}
	if !NativeMatrixValid([][]NativeValue{row, row}, 2, 1) || NativeMatrixValid([][]NativeValue{row, row, row}, 3, 1) {
		t.Fatal("matrix does not enforce aggregate byte budget")
	}
	if NativeMatrixValid([][]NativeValue{{{Kind: "null"}}}, 1, 2) {
		t.Fatal("wrong native matrix shape accepted")
	}
	entries := []NativeEntry{{Key: NativeScalar("text", "key"), Value: NativeScalar("integer", "1")}, {Key: NativeScalar("text", "key"), Value: NativeScalar("integer", "2")}}
	value = NativeValue{Kind: "object", Entries: entries}
	encoded, err := json.Marshal(value)
	var decoded NativeValue
	if err != nil || json.Unmarshal(encoded, &decoded) != nil || !reflect.DeepEqual(value, decoded) {
		t.Fatal("ordered duplicate entries were lost")
	}
}

func TestNativeResultOptInKeepsLegacyWireAndEmptyTypedMatrices(t *testing.T) {
	base := `{"type":"execute","requestId":"r","sessionId":"s","queryId":"q","sql":"SELECT 1"`
	for _, suffix := range []string{`}`, `,"resultValues":"nativeV1"}`} {
		command, err := ParseCommand([]byte(base + suffix))
		if err != nil || command.ResultValues != "" && command.ResultValues != NativeResultValuesFormat {
			t.Fatal("valid result representation rejected")
		}
	}
	for _, suffix := range []string{`,"resultValues":null}`, `,"resultValues":""}`, `,"resultValues":"future"}`, `,"resultValues":true}`} {
		if _, err := ParseCommand([]byte(base + suffix)); err == nil {
			t.Fatal("unknown result representation accepted")
		}
	}
	if _, err := ParseCommand([]byte(`{"type":"hello","requestId":"r","protocolVersion":6,"resultValues":"nativeV1"}`)); err == nil {
		t.Fatal("result opt-in accepted outside a result operation")
	}
	legacy, err := json.Marshal(ResultSet{})
	if err != nil || strings.Contains(string(legacy), "nativeValues") {
		t.Fatal("legacy result wire changed")
	}
	typed, err := json.Marshal(ResultSet{NativeValues: [][]NativeValue{}})
	if err != nil || !strings.Contains(string(typed), `"nativeValues":[]`) {
		t.Fatal("empty typed result lost its representation")
	}
	if _, err := json.Marshal(ResultSet{Columns: []Column{{Name: "x"}}, Rows: [][]*string{{nil}}, NativeValues: [][]NativeValue{}}); err == nil {
		t.Fatal("mismatched native result serialized")
	}
}
