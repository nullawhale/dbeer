package session

import (
	"context"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestStreamTerminalStorageEvidenceFollowsAcknowledgedRows(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	m := &Manager{events: make(chan event), stop: make(chan struct{})}
	credit := newCreditState(&owner{id: "session", manager: m}, protocol.Command{RequestID: "browse", SessionID: "session", QueryID: "query"})
	sink := &streamSink{ctx: ctx, credit: credit}
	go func() {
		for {
			select {
			case <-ctx.Done():
				return
			case event := <-m.events:
				credit.ack(event.response.Sequence)
			}
		}
	}()
	columns := []protocol.Column{{Index: 0, Name: "id", Engine: "postgresql", NativeType: "int4"}}
	value := "1"
	if err := sink.Begin(0, columns); err != nil {
		t.Fatal(err)
	}
	if err := sink.Row(0, []*string{&value}); err != nil {
		t.Fatal(err)
	}
	if err := sink.End(0, protocol.ResultSet{Columns: columns, RowCount: 1, DisplayedRowCount: 1, StorageTokens: []string{"pgrow-v1/16384/(0,1)/456"}}); err != nil {
		t.Fatal(err)
	}
	response := sink.finish(protocol.Response{Type: "query.result"})
	if len(response.StorageTokens) != 1 || response.StorageTokens[0] != "pgrow-v1/16384/(0,1)/456" || len(response.ResultSets[0].StorageTokens) != 1 {
		t.Fatal("terminal lost original-row evidence")
	}
}

func TestStorageEvidenceCannotExceedTheAcknowledgedDisplayBudget(t *testing.T) {
	sink := &streamSink{bytes: displayBytes, sets: []*streamSet{{sent: 1}}}
	if err := sink.End(0, protocol.ResultSet{StorageTokens: []string{"bounded"}}); err != nil {
		t.Fatal(err)
	}
	if sink.sets[0].summary.StorageTokens != nil {
		t.Fatal("storage evidence bypassed display budget")
	}
}
