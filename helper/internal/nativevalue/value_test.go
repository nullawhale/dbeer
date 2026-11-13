package nativevalue

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

func TestSharedEncodedBudget(t *testing.T) {
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
		budget := &nativeValueBudget{}
		if !value.valid(0, budget) || budget.bytes != len(encoded) {
			t.Fatalf("native case %d encoded budget mismatch: %d != %d", i, budget.bytes, len(encoded))
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
