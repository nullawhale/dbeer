package protocol

import (
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"
)

func TestSharedComparisonWireContract(t *testing.T) {
	data, e := os.ReadFile("../../../protocol/fixtures/result-comparison-v1.json")
	if e != nil {
		t.Fatal(e)
	}
	var fixture struct {
		Version             int
		Capability          string
		Commands, Responses []json.RawMessage
	}
	if json.Unmarshal(data, &fixture) != nil || fixture.Version != Version || fixture.Capability != ResultComparisonCapability {
		t.Fatal("invalid comparison fixture")
	}
	for i, raw := range fixture.Commands {
		command, e := ParseCommand(raw)
		if e != nil || command.Comparison == nil || command.SessionID != "" || command.Connection != nil {
			t.Fatalf("comparison command %d invalid: %v", i, e)
		}
	}
	for i, raw := range fixture.Responses {
		var response Response
		if json.Unmarshal(raw, &response) != nil || response.Comparison == nil {
			t.Fatalf("invalid response %d", i)
		}
		encoded, e := json.Marshal(response)
		if e != nil {
			t.Fatal(e)
		}
		var before, after any
		json.Unmarshal(raw, &before)
		json.Unmarshal(encoded, &after)
		if !reflect.DeepEqual(before, after) {
			t.Fatalf("response %d changed shape", i)
		}
	}
}
func TestComparisonParserRejectsAmbiguityArbitraryAccessAndUnboundedOutput(t *testing.T) {
	start := `{"type":"compare.start","requestId":"start","comparison":{"left":{"kind":"snapshot","id":"11111111-1111-1111-1111-111111111111"},"right":{"kind":"snapshot","id":"22222222-2222-2222-2222-222222222222"},"mode":"key","columns":[{"left":0,"right":0,"key":true}]}}`
	invalid := []string{
		strings.Replace(start, `"id":"11111111-1111-1111-1111-111111111111"`, `"id":"../../../file"`, 1),
		strings.Replace(start, `"kind":"snapshot"`, `"kind":"path"`, 1),
		strings.Replace(start, `"mode":"key",`, "", 1),
		strings.Replace(start, `"mode":"key"`, `"mode":"rowOrder"`, 1),
		strings.Replace(start, `,"key":true`, "", 1),
		strings.Replace(start, `"left":0`, `"left":-1`, 1),
		strings.Replace(start, `"left":0`, `"left":null`, 1),
		strings.Replace(start, `"left":0`, `"left":0,"left":1`, 1),
		strings.Replace(start, `"left":0`, `"left":0,"path":"/fixture"`, 1),
		strings.Replace(start, `"columns":[{"left":0,"right":0,"key":true}]`, `"columns":[{"left":0,"right":0,"key":true},{"left":0,"right":1}]`, 1),
		strings.Replace(start, `"columns":[{"left":0,"right":0,"key":true}]`, `"columns":null`, 1),
		`{"type":"compare.page","requestId":"p","comparison":{"jobId":"job","maxBytes":16777216}}`,
		`{"type":"compare.page","requestId":"p","comparison":{"jobId":"job","maxBytes":4095}}`,
		`{"type":"compare.page","requestId":"p","comparison":{"jobId":"job","limit":1001}}`,
		`{"type":"compare.page","requestId":"p","comparison":{"jobId":"job","cellOffset":-1}}`,
		`{"type":"compare.page","requestId":"p","comparison":{"jobId":"job","offset":null}}`,
		`{"type":"compare.value","requestId":"p","comparison":{"jobId":"job","valueRef":"ref","maxBytes":1048577}}`,
		`{"type":"compare.value","requestId":"p","comparison":{"jobId":"job","valueRef":"ref","offset":-1}}`,
		`{"type":"compare.status","requestId":"p","comparison":{"jobId":"job","left":{"kind":"snapshot","id":"11111111-1111-1111-1111-111111111111"}}}`,
		`{"type":"compare.cancel","requestId":"p","sessionId":"db","comparison":{"jobId":"job"}}`,
	}
	for i, raw := range invalid {
		if _, e := ParseCommand([]byte(raw)); e == nil {
			t.Fatalf("invalid comparison %d accepted", i)
		}
	}
	for _, kind := range []string{"status", "cancel", "close"} {
		raw := `{"type":"compare.` + kind + `","requestId":"p","comparison":{"jobId":"job"}}`
		if _, e := ParseCommand([]byte(raw)); e != nil {
			t.Fatal("valid control rejected")
		}
	}
}
