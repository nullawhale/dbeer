package protocol

import (
	"dbeer/helper/internal/tableedit"
	"encoding/json"
	"os"
	"testing"
)

func TestPhysicalSharedContract(t *testing.T) {
	raw, e := os.ReadFile("../../../protocol/fixtures/table-structure-physical-v1.json")
	if e != nil {
		t.Fatal(e)
	}
	var f struct {
		Valid   []json.RawMessage
		Invalid []string
	}
	if json.Unmarshal(raw, &f) != nil {
		t.Fatal("bad fixture")
	}
	for i, r := range f.Valid {
		if _, e := ParseCommand(r); e != nil {
			t.Errorf("valid %d rejected", i)
		}
	}
	for i, r := range f.Invalid {
		if _, e := ParseCommand([]byte(r)); e == nil {
			t.Errorf("invalid %d admitted", i)
		}
	}
}

func TestPhysicalEmptyStatusProductionMarshallerHasClosedEmptyEnvelope(t *testing.T) {
	raw, e := json.Marshal(Response{Type: "structure.physical.status.result", RequestID: "r", SessionID: "s", QueryID: "q", Connected: true, TransactionStatus: "idle", Structure: &tableedit.Reply{Physical: &tableedit.PhysicalReply{}}})
	if e != nil {
		t.Fatal(e)
	}
	var r map[string]json.RawMessage
	if json.Unmarshal(raw, &r) != nil {
		t.Fatal("cannot decode actual status frame")
	}
	var envelope map[string]json.RawMessage
	if json.Unmarshal(r["structure"], &envelope) != nil || len(envelope) != 1 || string(envelope["physical"]) != "{}" {
		t.Fatal("empty status invented null collections or retained data")
	}
	for _, key := range []string{"requestId", "sessionId", "queryId"} {
		if len(r[key]) == 0 || string(r[key]) == "null" {
			t.Fatal("empty status lost correlation")
		}
	}
}
