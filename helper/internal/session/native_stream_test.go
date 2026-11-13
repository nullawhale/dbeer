package session

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestNativeStreamBindsTypedChunksAndDoesNotRepeatTerminalValues(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	manager := &Manager{events: make(chan event, 4), stop: make(chan struct{})}
	owner := &owner{id: "session", manager: manager}
	command := protocol.Command{Type: "execute", RequestID: "request", SessionID: "session", QueryID: "query", ResultValues: protocol.NativeResultValuesFormat}
	credit := newCreditState(owner, command)
	collected := make(chan []protocol.Response, 1)
	go func() {
		var frames []protocol.Response
		for {
			select {
			case event := <-manager.events:
				frames = append(frames, event.response)
				credit.ack(event.response.Sequence)
			case <-ctx.Done():
				collected <- frames
				return
			}
		}
	}()
	sink := &streamSink{ctx: ctx, credit: credit, nativeRequested: true}
	columns := []protocol.Column{{Index: 0, Name: "native", Engine: "mongodb", NativeType: "BSON document"}}
	if err := sink.Begin(0, columns); err != nil {
		t.Fatal(err)
	}
	native := protocol.NativeValue{Kind: "object", Entries: []protocol.NativeEntry{
		{Key: protocol.NativeScalar("text", "key"), Value: protocol.NativeScalar("decimal", "9007199254740993.00000001")},
		{Key: protocol.NativeScalar("text", "key"), Value: protocol.NativeBinary([]byte{0, 255})},
	}}
	display := "synthetic display"
	for i := 0; i < 2; i++ {
		if err := sink.NativeRow(0, []protocol.NativeValue{native}); err != nil {
			t.Fatal(err)
		}
		if err := sink.Row(0, []*string{&display}); err != nil {
			t.Fatal(err)
		}
	}
	if err := sink.End(0, protocol.ResultSet{Columns: columns, RowCount: 2, DisplayedRowCount: 2, CommandTag: "SELECT", NativeValues: [][]protocol.NativeValue{{native}, {native}}}); err != nil {
		t.Fatal(err)
	}
	result := sink.finish(protocol.Response{Type: "query.result", RequestID: "request", SessionID: "session", QueryID: "query", TransactionStatus: "idle", NativeValues: [][]protocol.NativeValue{{native}, {native}}})
	if result.NativeValues != nil || len(result.ResultSets) != 1 || result.ResultSets[0].NativeValues != nil || result.ResultSets[0].DisplayedRowCount != 2 {
		t.Fatal("terminal duplicated or lost streamed values")
	}
	cancel()
	frames := <-collected
	if len(frames) != 2 || frames[0].NativeValues == nil || len(frames[0].NativeValues) != 0 || len(frames[1].NativeValues) != 2 || len(frames[1].NativeValues[0][0].Entries) != 2 {
		t.Fatal("native chunk identity lost")
	}
	for _, frame := range frames {
		encoded, err := json.Marshal(frame)
		if err != nil || !strings.Contains(string(encoded), `"nativeValues":`) {
			t.Fatal("native chunk cannot serialize")
		}
	}
}

func TestNativeStreamRejectsMissingAndUnsolicitedRows(t *testing.T) {
	sink := &streamSink{nativeRequested: true, sets: []*streamSet{{columns: []protocol.Column{{Name: "x"}}, sourceWidth: 1}}}
	display := "text"
	if sink.Row(0, []*string{&display}) == nil {
		t.Fatal("missing typed evidence accepted")
	}
	sink = &streamSink{sets: []*streamSet{{columns: []protocol.Column{{Name: "x"}}, sourceWidth: 1}}}
	if sink.NativeRow(0, []protocol.NativeValue{protocol.NativeScalar("text", display)}) == nil {
		t.Fatal("unsolicited typed evidence accepted")
	}
}
