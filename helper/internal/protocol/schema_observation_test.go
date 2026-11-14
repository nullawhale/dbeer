package protocol

import (
	"encoding/json"
	"os"
	"testing"
)

func TestSchemaObservationSharedContract(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/schema-observation-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Requests []struct {
			Valid   bool            `json:"valid"`
			Command json.RawMessage `json:"command"`
		} `json:"requests"`
		Observations []struct {
			Valid       bool              `json:"valid"`
			Observation SchemaObservation `json:"observation"`
		} `json:"observations"`
	}
	if json.Unmarshal(data, &fixture) != nil {
		t.Fatal("invalid shared observation fixture")
	}
	for i, item := range fixture.Requests {
		_, err := ParseCommand(item.Command)
		if (err == nil) != item.Valid {
			t.Fatalf("request case %d differs", i)
		}
	}
	for i, item := range fixture.Observations {
		if item.Observation.Valid() != item.Valid {
			t.Fatalf("observation case %d differs", i)
		}
	}
}
