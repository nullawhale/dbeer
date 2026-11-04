package protocol

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
)

func monitorFixture(t *testing.T) SessionMonitorSnapshot {
	t.Helper()
	return SessionMonitorSnapshot{Engine: "postgresql", CollectionStartedAt: "2026-01-02T03:04:05Z", CollectedAt: "2026-01-02T03:04:05.01Z", Sessions: []MonitoredSession{}, Waits: []MonitorWait{}, SessionsComplete: true, WaitsComplete: true, Notices: []string{}}
}

func TestSessionMonitorSharedContract(t *testing.T) {
	data, err := os.ReadFile("../../../protocol/fixtures/session-monitor-v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		ValidCommands    []json.RawMessage        `json:"validCommands"`
		InvalidCommands  []string                 `json:"invalidCommands"`
		Snapshots        []SessionMonitorSnapshot `json:"snapshots"`
		InvalidSnapshots []SessionMonitorSnapshot `json:"invalidSnapshots"`
		ValidResponses   []struct {
			Monitor SessionMonitorSnapshot `json:"monitor"`
		} `json:"validResponses"`
	}
	if json.Unmarshal(data, &fixture) != nil || len(fixture.Snapshots) != 2 || len(fixture.ValidResponses) != 2 {
		t.Fatal("invalid session monitor fixture")
	}
	for index, frame := range fixture.ValidCommands {
		if _, err := ParseCommand(frame); err != nil {
			t.Errorf("valid monitor command %d rejected", index)
		}
	}
	for index, frame := range fixture.InvalidCommands {
		if _, err := ParseCommand([]byte(frame)); err == nil {
			t.Errorf("invalid monitor command %d accepted", index)
		}
	}
	for index, snapshot := range fixture.Snapshots {
		if !snapshot.Valid() {
			t.Errorf("valid monitor snapshot %d rejected", index)
		}
	}
	for index, snapshot := range fixture.InvalidSnapshots {
		if snapshot.Valid() {
			t.Errorf("invalid monitor snapshot %d accepted", index)
		}
	}
	for _, response := range fixture.ValidResponses {
		if !response.Monitor.Valid() {
			t.Fatal("shared response contains an invalid snapshot")
		}
	}
}

func TestSessionMonitorBoundsUseUTF8AndEncodedBytes(t *testing.T) {
	pointer := func(value string) *string { return &value }
	base := monitorFixture(t)
	base.Sessions = []MonitoredSession{{ID: "0", Query: pointer(strings.Repeat("я", MaxMonitorQueryBytes/2)), QueryAgeMs: pointer("18446744073709551615")}}
	base.Waits = []MonitorWait{{WaitingID: "0", BlockingID: "999", Kind: "lock"}}
	if !base.Valid() {
		t.Fatal("bounded Unicode query or invisible blocker rejected")
	}
	for _, query := range []string{strings.Repeat("я", MaxMonitorQueryBytes/2) + "a", "bad\x00query", string([]byte{0xff})} {
		invalid := base
		invalid.Sessions = []MonitoredSession{{ID: "1", Query: pointer(query)}}
		if invalid.Valid() {
			t.Fatal("oversized or malformed UTF-8 query accepted")
		}
	}
	for _, decimal := range []string{"", "01", "+1", "-1", "1.0", "1e2", "１２", strings.Repeat("1", 21)} {
		if ValidMonitorDecimal(decimal) {
			t.Fatal("noncanonical session identifier or age accepted")
		}
	}
	full := monitorFixture(t)
	for index := range MaxMonitoredSessions {
		full.Sessions = append(full.Sessions, MonitoredSession{ID: fmt.Sprint(index)})
	}
	for index := range MaxMonitorWaits {
		full.Waits = append(full.Waits, MonitorWait{WaitingID: fmt.Sprint(index), BlockingID: "0", Kind: "data"})
	}
	if !full.Valid() {
		t.Fatal("maximum bounded observation rejected")
	}
	full.Sessions = append(full.Sessions, MonitoredSession{ID: "9999"})
	if full.Valid() {
		t.Fatal("session limit exceeded")
	}
	full.Sessions = full.Sessions[:MaxMonitoredSessions]
	full.Waits = append(full.Waits, MonitorWait{WaitingID: "9999", BlockingID: "0", Kind: "data"})
	if full.Valid() {
		t.Fatal("wait limit exceeded")
	}
	oversized := monitorFixture(t)
	field := pointer(strings.Repeat("<", MaxMonitorFieldBytes))
	for index := range 100 {
		oversized.Sessions = append(oversized.Sessions, MonitoredSession{ID: fmt.Sprint(index), User: field, Database: field, Client: field, Application: field, State: field, WaitType: field, WaitEvent: field})
	}
	if oversized.Valid() {
		t.Fatal("JSON escaping exceeded the encoded observation limit")
	}
}

func TestSessionMonitorResponseHasOnlyBoundedObservationFields(t *testing.T) {
	snapshot := monitorFixture(t)
	response := Response{Type: "monitor.result", RequestID: "request", SessionID: "session", QueryID: "query", Monitor: &snapshot, Connected: true, TransactionStatus: "idle", SQL: "must not leak", Rows: [][]*string{{nil}}, DisplayNotice: "ignored"}
	encoded, err := json.Marshal(response)
	if err != nil {
		t.Fatal("valid monitor result rejected")
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(encoded, &fields) != nil || len(fields) != 7 || fields["monitor"] == nil || fields["rows"] != nil || fields["sql"] != nil {
		t.Fatal("monitor result exposed an unrelated payload")
	}
	for _, mutate := range []func(*Response){
		func(response *Response) { response.Monitor = nil },
		func(response *Response) { response.Connected = false },
		func(response *Response) { response.TransactionStatus = "transaction" },
	} {
		invalid := response
		mutate(&invalid)
		if _, err := json.Marshal(invalid); err == nil {
			t.Fatal("invalid monitor terminal response serialized")
		}
	}
}
