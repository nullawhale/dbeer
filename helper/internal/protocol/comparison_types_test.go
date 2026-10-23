package protocol

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestAllEngineComparisonTypeFixture(t *testing.T) {
	raw, err := os.ReadFile("../../../protocol/fixtures/comparison-type-support-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		FormatVersion int
		Commands      []json.RawMessage
		Columns       []Column
	}
	if json.Unmarshal(raw, &fixture) != nil || fixture.FormatVersion != 1 || len(fixture.Commands) != 3 {
		t.Fatal("invalid type support fixture")
	}
	for _, raw := range fixture.Commands {
		command, err := ParseCommand(raw)
		if err != nil {
			t.Fatal("Cassandra comparison command rejected")
		}
		encoded, _ := json.Marshal(command)
		if _, err := ParseCommand(encoded); err != nil {
			t.Fatal("comparison command did not round trip")
		}
		// A different target engine must still fail before opening either side.
		mismatch := strings.Replace(string(raw), `"engine": "cassandra"`, `"engine": "mysql"`, 1)
		if _, err := ParseCommand([]byte(mismatch)); err == nil {
			t.Fatal("cross-engine comparison was admitted")
		}
	}
	encoded, _ := json.Marshal(fixture.Columns)
	var columns []Column
	if json.Unmarshal(encoded, &columns) != nil || columns[0].TypeIdentity != fixture.Columns[0].TypeIdentity {
		t.Fatal("structural type identity was lost")
	}
}
