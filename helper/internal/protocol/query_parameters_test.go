package protocol

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestQueryParameterSharedFixtureAndClosedShapes(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/query-parameters-v1.json")
	if err != nil {
		t.Fatal("read parameter fixture")
	}
	var fixture struct {
		Capability          string
		Execute, Assessment json.RawMessage
		InvalidParameters   []json.RawMessage
	}
	if json.Unmarshal(data, &fixture) != nil || fixture.Capability != QueryParametersCapability {
		t.Fatal("decode fixture")
	}
	command, err := ParseCommand(fixture.Execute)
	if err != nil || len(command.Parameters) != 8 || command.Parameters[6].Value != nil || command.Parameters[7].Value == nil || *command.Parameters[7].Value != "" {
		t.Fatal("typed values or null/empty distinction lost")
	}
	assessment, err := ParseCommand(fixture.Assessment)
	if err != nil || len(assessment.Operations) != 1 || len(assessment.Operations[0].Parameters) != 8 {
		t.Fatal("assessment lost bindings")
	}
	for _, raw := range fixture.InvalidParameters {
		frame := `{"type":"execute","requestId":"r","sessionId":"s","queryId":"q","sql":"SELECT :x","parameters":` + string(raw) + `}`
		if _, err := ParseCommand([]byte(frame)); err == nil {
			t.Fatal("malformed parameter accepted")
		}
	}
	for _, raw := range []string{`null`, `{}`, `[{"name":"x","type":"text","value":"a","value":"b"}]`} {
		if _, err := ParseCommand([]byte(`{"type":"execute","requestId":"r","sessionId":"s","queryId":"q","sql":"SELECT :x","parameters":` + raw + `}`)); err == nil {
			t.Fatal("invalid parameter collection accepted")
		}
	}
}

func TestQueryParameterLimitsAndTypedValueValidation(t *testing.T) {
	for _, test := range []struct {
		kind, value string
		valid       bool
	}{
		{"integer", "+001", true}, {"integer", "-9223372036854775808", true}, {"integer", "9223372036854775808", false},
		{"decimal", "+000.100000000000000000001", true}, {"decimal", ".5", false}, {"decimal", "1.", false}, {"decimal", "1e2", false},
		{"date", "0001-01-01", true}, {"date", "0000-01-01", false}, {"date", "2024-02-29", true}, {"date", "2023-02-29", false},
		{"timestamp", "2026-11-01 01:02:03.1", true}, {"timestamp", "2026-11-01 01:02:03.1234567", false}, {"timestamp", "2026-11-01 24:00:00", false},
		{"boolean", "true", true}, {"boolean", "1", false}, {"text", "", true}, {"text", "NULL", true}, {"text", "\x00", false},
	} {
		p := QueryParameter{Name: "x", Type: test.kind, Value: &test.value}
		if p.Valid() != test.valid {
			t.Fatalf("unexpected %s validation", test.kind)
		}
	}
	large := strings.Repeat("x", MaxQueryParameterBytes)
	if !QueryParametersValid([]QueryParameter{{Name: "x", Type: "text", Value: &large}}) {
		t.Fatal("allowed size rejected")
	}
	if QueryParametersValid([]QueryParameter{{Name: "x", Type: "text", Value: &large}, {Name: "y", Type: "text", Value: &large}}) {
		t.Fatal("total limit ignored")
	}
	if QueryParameterNameValid(strings.Repeat("a", 65)) || QueryParameterNameValid("é") || QueryParameterNameValid("1x") {
		t.Fatal("invalid name accepted")
	}
}
