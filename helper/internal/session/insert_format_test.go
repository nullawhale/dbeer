package session

import (
	"context"
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/protocol"
)

func TestSharedOfflineInsertFormattingNeverOpensDatabase(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/copy-inserts-v1/cases.json")
	if err != nil {
		t.Fatal("shared INSERT fixtures are unavailable")
	}
	var fixture struct {
		Cases []struct {
			Command  json.RawMessage
			Response json.RawMessage
		}
	}
	if json.Unmarshal(data, &fixture) != nil {
		t.Fatal("invalid shared INSERT fixture")
	}
	var opened atomic.Int32
	manager := New(func(context.Context, protocol.Connection) (adapter.Session, error) {
		opened.Add(1)
		return blockingSession(), nil
	})
	defer manager.Close()
	for index, item := range fixture.Cases {
		command, err := protocol.ParseCommand(item.Command)
		if err != nil {
			t.Fatal("valid shared INSERT command rejected")
		}
		submit(t, manager, command)
		actual := receive(t, manager)
		encoded, err := json.Marshal(actual)
		if err != nil {
			t.Fatal("offline result could not be encoded")
		}
		var expectedValue, actualValue any
		if json.Unmarshal(item.Response, &expectedValue) != nil || json.Unmarshal(encoded, &actualValue) != nil || !reflect.DeepEqual(expectedValue, actualValue) {
			t.Fatalf("offline INSERT fixture %d did not preserve its expected SQL or safe error", index)
		}
	}
	if opened.Load() != 0 {
		t.Fatal("offline formatting opened a database")
	}
}

func TestOfflineInsertFormattingLeavesBusySessionUntouched(t *testing.T) {
	manager := New(func(context.Context, protocol.Connection) (adapter.Session, error) { return blockingSession(), nil })
	defer manager.Close()
	id := openTestSession(t, manager, "live")
	query := startTestQuery(t, manager, id, "slow", "SELECT 'slow'")
	request := protocol.InsertFormatRequest{Engine: "mysql", Schema: "target", Table: "target", Columns: []protocol.InsertFormatColumn{{Name: "value"}}, Rows: [][]protocol.CellValue{{{Kind: "null"}}}}
	submit(t, manager, protocol.Command{Type: "formatInserts", RequestID: "offline", Insert: &request})
	if response := receive(t, manager); response.Type != "insertSQL" || response.RequestID != "offline" || response.SessionID != "" || response.QueryID != "" {
		t.Fatal("offline generation waited for or borrowed a busy session")
	}
	submit(t, manager, protocol.Command{Type: "cancel", RequestID: "stop", SessionID: id, QueryID: query.QueryID})
	seen := map[string]bool{}
	for range 2 {
		seen[receive(t, manager).RequestID] = true
	}
	if !seen[query.RequestID] || !seen["stop"] {
		t.Fatal("offline formatting disturbed live query cancellation")
	}
}

func TestOfflineInsertBoundsIncludeExpandedSQLAndJSON(t *testing.T) {
	for _, item := range []struct{ engine, value string }{
		{"mysql", strings.Repeat("s", 5*1024*1024)},
		{"postgresql", strings.Repeat("<", 3*1024*1024)},
	} {
		request := protocol.InsertFormatRequest{Engine: item.engine, Schema: "public", Table: "target", Columns: []protocol.InsertFormatColumn{{Name: "v"}}, Rows: [][]protocol.CellValue{{{Kind: "text", Value: &item.value}}}}
		response := formatInserts(protocol.Command{Type: "formatInserts", RequestID: "bounded", Insert: &request})
		if response.Type != "error" || response.Category != "validation" || response.SQL != "" || strings.Contains(response.Message, item.value[:32]) {
			t.Fatal("expanded SQL or JSON exceeded its bounds or exposed data")
		}
	}
}
