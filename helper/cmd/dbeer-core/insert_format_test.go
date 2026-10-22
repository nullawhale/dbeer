package main

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"testing"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

func TestOfflineInsertFormattingAdvertisesCapabilityAndNeverConnects(t *testing.T) {
	const input = `{"type":"hello","requestId":"hello","protocolVersion":5}
{"type":"formatInserts","requestId":"copy","insert":{"engine":"postgresql","schema":"","table":"target","columns":[{"name":"value"}],"rows":[[{"kind":"null"}]]}}
{"type":"shutdown","requestId":"shutdown"}
`
	var output bytes.Buffer
	if err := runWithFactory(strings.NewReader(input), &output, func(context.Context, protocol.Connection) (adapter.Session, error) {
		t.Error("offline formatting must never open a database")
		return nil, nil
	}); err != nil {
		t.Fatal("offline INSERT transport failed")
	}
	decoder := json.NewDecoder(&output)
	var hello, response, shutdown protocol.Response
	if decoder.Decode(&hello) != nil || decoder.Decode(&response) != nil || decoder.Decode(&shutdown) != nil {
		t.Fatal("offline INSERT transport lost a response")
	}
	capability := false
	for _, name := range hello.Capabilities {
		capability = capability || name == "formatInsertsV1"
	}
	if hello.Type != "hello.ack" || !capability || response.Type != "insertSQL" || response.SQL != `INSERT INTO "target" ("value") VALUES (NULL);` || response.SessionID != "" || response.QueryID != "" || shutdown.Type != "shutdown.ack" {
		t.Fatal("offline INSERT capability or response is invalid")
	}
}
