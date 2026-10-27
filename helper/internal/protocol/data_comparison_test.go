package protocol

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestDataComparisonSharedStrictWire(t *testing.T) {
	raw, e := os.ReadFile("../../../protocol/fixtures/data-comparison-v1.json")
	if e != nil {
		t.Fatal(e)
	}
	var fixture struct {
		Version    int               `json:"version"`
		Capability string            `json:"capability"`
		Commands   []json.RawMessage `json:"commands"`
	}
	if json.Unmarshal(raw, &fixture) != nil || fixture.Version != Version || fixture.Capability != DataComparisonCapability {
		t.Fatal("invalid fixture")
	}
	for _, raw := range fixture.Commands {
		command, e := ParseCommand(raw)
		if e != nil || command.DataComparison == nil {
			t.Fatal("data command rejected")
		}
		b, _ := json.Marshal(command)
		if _, e = ParseCommand(b); e != nil {
			t.Fatal("command did not round trip")
		}
	}
	start := string(fixture.Commands[1])
	for _, bad := range []string{strings.Replace(start, `"readLimit": 3`, `"readLimit":0`, 1), strings.Replace(start, `"readLimit": 3`, `"readLimit":100001`, 1), strings.Replace(start, `"key": true`, `"key":false`, 1), strings.Replace(start, `"filters": []`, `"filters":null`, 1), strings.Replace(start, `"postgresql"`, `"mysql"`, 1), strings.Replace(start, `"postgresql"`, `"unknown"`, -1), strings.Replace(start, `"requestId": "start"`, `"requestId":"start","sql":"SELECT 1"`, 1), strings.Replace(start, `"key": true`, `"key":true,"key":false`, 1), strings.Replace(start, `"descriptorDigest": "`+strings.Repeat("a", 64)+`"`, `"descriptorDigest":"oid:1"`, 1), `{"type":"data.page","requestId":"p","dataComparison":{"jobId":"job","limit":0}}`, `{"type":"data.value","requestId":"v","dataComparison":{"jobId":"job","valueRef":"v","offset":null}}`} {
		if _, e = ParseCommand([]byte(bad)); e == nil {
			t.Fatal("unsafe data request admitted")
		}
	}
}
