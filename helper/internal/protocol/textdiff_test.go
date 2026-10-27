package protocol

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestSharedTextDiffWireAndStrictSelection(t *testing.T) {
	b, e := os.ReadFile("../../../protocol/fixtures/text-diff-v1.json")
	if e != nil {
		t.Fatal(e)
	}
	var fixture struct{ Commands, Responses []json.RawMessage }
	if e = json.Unmarshal(b, &fixture); e != nil {
		t.Fatal(e)
	}
	for _, raw := range fixture.Commands {
		c, e := ParseCommand(raw)
		if e != nil {
			t.Fatal("diff fixture rejected")
		}
		wire, e := json.Marshal(c)
		if e != nil {
			t.Fatal(e)
		}
		if _, e = ParseCommand(wire); e != nil {
			t.Fatal("diff command did not round trip")
		}
	}
	for _, raw := range fixture.Responses {
		var response Response
		if e = json.Unmarshal(raw, &response); e != nil {
			t.Fatal(e)
		}
		encoded, e := json.Marshal(response)
		if e != nil || !strings.Contains(string(encoded), `"diff"`) || !strings.Contains(string(encoded), `"offset":0`) {
			t.Fatal("response omitted diff or selection binding")
		}
	}
	for _, raw := range []string{
		`{"type":"schema.diff","requestId":"d","schemaComparison":{"jobId":"job","offset":-1}}`,
		`{"type":"schema.diff","requestId":"d","schemaComparison":{"jobId":"job","offset":null}}`,
		`{"type":"schema.diff","requestId":"d","schemaComparison":{"jobId":"job","offset":1,"offset":2}}`,
		`{"type":"schema.diff","requestId":"d","schemaComparison":{"jobId":"job","offset":0,"valueRef":"other"}}`,
		`{"type":"data.diff","requestId":"d","dataComparison":{"jobId":"job","offset":-1,"cellOffset":0}}`,
		`{"type":"data.diff","requestId":"d","dataComparison":{"jobId":"job","offset":0,"cellOffset":-1}}`,
		`{"type":"data.diff","requestId":"d","dataComparison":{"jobId":"job","offset":0,"cellOffset":null}}`,
		`{"type":"data.diff","requestId":"d","dataComparison":{"jobId":"job","offset":0,"cellOffset":0,"valueRef":"other"}}`,
		`{"type":"data.diff","requestId":"d","dataComparison":{"jobId":"job","offset":9223372036854775808,"cellOffset":0}}`,
	} {
		if _, e = ParseCommand([]byte(raw)); e == nil {
			t.Fatal("invalid diff request admitted")
		}
	}
}
