package protocol

import (
	"encoding/json"
	"os"
	"testing"
)

func TestDatabaseToolsSharedContract(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/database-tools-v1.json")
	if err != nil {
		t.Fatal("missing database tools fixture")
	}
	var fixture struct {
		ValidCommands                []json.RawMessage
		InvalidCommands              []string
		ValidReplies, InvalidReplies []struct {
			Type          string
			DatabaseTools DatabaseToolsReply
		}
	}
	if json.Unmarshal(data, &fixture) != nil || len(fixture.ValidCommands) == 0 || len(fixture.ValidReplies) == 0 {
		t.Fatal("invalid database tools fixture")
	}
	for index, command := range fixture.ValidCommands {
		if _, err := ParseCommand(command); err != nil {
			t.Errorf("valid command %d rejected", index)
		}
	}
	for index, command := range fixture.InvalidCommands {
		if _, err := ParseCommand([]byte(command)); err == nil {
			t.Errorf("invalid command %d accepted", index)
		}
	}
	for index, reply := range fixture.ValidReplies {
		if !reply.DatabaseTools.Valid(reply.Type) {
			t.Errorf("valid reply %d rejected", index)
		}
	}
	for index, reply := range fixture.InvalidReplies {
		if reply.DatabaseTools.Valid(reply.Type) {
			t.Errorf("invalid reply %d accepted", index)
		}
	}
}
