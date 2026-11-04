package protocol

import (
	"encoding/json"
	"os"
	"testing"
)

func TestDataTransferSharedContract(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/data-transfer-v1.json")
	if err != nil {
		t.Fatal("cannot read transfer fixture")
	}
	var fixture struct {
		ValidRequests, InvalidRequests []struct {
			Kind    string
			Request json.RawMessage
		}
		ValidReplies []TransferReply
	}
	if json.Unmarshal(data, &fixture) != nil || len(fixture.ValidRequests) == 0 || len(fixture.InvalidRequests) == 0 || len(fixture.ValidReplies) == 0 {
		t.Fatal("invalid transfer fixture")
	}
	for index, item := range fixture.ValidRequests {
		if _, ok := ParseTransfer(item.Request, item.Kind); !ok {
			t.Errorf("valid transfer request %d rejected", index)
		}
	}
	for index, item := range fixture.InvalidRequests {
		if _, ok := ParseTransfer(item.Request, item.Kind); ok {
			t.Errorf("invalid transfer request %d accepted", index)
		}
	}
	for index, item := range fixture.ValidReplies {
		if !item.Valid() {
			t.Errorf("valid transfer reply %d rejected", index)
		}
	}
}
