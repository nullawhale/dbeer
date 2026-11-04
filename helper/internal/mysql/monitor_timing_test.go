package mysql

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

func monitorActiveTimedRow(id string) []*string {
	row := monitorRow(id, "reader", "example", "localhost", "executing", "SELECT fixture", "Query", "1", "", "2500999999", "", "SELECT fixture", "1", "", "ACTIVE", "9000999999", "")
	for _, index := range []int{8, 10, 13, 16} {
		row[index] = nil
	}
	return row
}

func TestMySQLMonitorEventTimingUsesExactUnsignedPicoseconds(t *testing.T) {
	for input, expected := range map[string]string{
		"0": "0", "999999999": "0", "1000000000": "1", "2500999999": "2",
		"18446744073709551615": "18446744073",
	} {
		actual, err := monitorPicosecondsToMilliseconds(&input)
		if err != nil || actual == nil || *actual != expected {
			t.Fatal("unsigned timer lost its exact millisecond floor")
		}
	}
	if actual, err := monitorPicosecondsToMilliseconds(nil); err != nil || actual != nil {
		t.Fatal("unavailable timing became zero")
	}
	for _, input := range []string{"-1", "01", "1.0", "18446744073709551616", strings.Repeat("9", 21)} {
		if _, err := monitorPicosecondsToMilliseconds(&input); err == nil {
			t.Fatal("malformed or overflowing event timer was accepted")
		}
	}
}

func TestMySQLMonitorCompletedDisabledNestedAndMismatchedEventsStayUnavailable(t *testing.T) {
	for _, test := range []struct {
		name   string
		mutate func([]*string)
	}{
		{"completed", func(row []*string) { row[8] = monitorRow("9")[0] }},
		{"consumer or instrument disabled", func(row []*string) { row[7] = monitorRow("0")[0] }},
		{"idle", func(row []*string) { row[6] = monitorRow("Sleep")[0] }},
		{"nested", func(row []*string) { row[10] = monitorRow("STATEMENT")[0] }},
		{"mismatched text", func(row []*string) { row[11] = monitorRow("SELECT another_fixture")[0] }},
		{"missing text", func(row []*string) { row[11] = nil }},
		{"untimed", func(row []*string) { row[9] = nil }},
	} {
		t.Run(test.name, func(t *testing.T) {
			row := monitorActiveTimedRow("11")
			var session protocol.MonitoredSession
			if applyMonitorTiming(&session, row) != nil || session.QueryAgeMs == nil || session.TransactionAgeMs == nil {
				t.Fatal("active event timing was not reported")
			}
			test.mutate(row)
			if applyMonitorTiming(&session, row) != nil || session.QueryAgeMs != nil {
				t.Fatal("inactive or mismatched query retained an old timer")
			}
		})
	}
	for _, mutate := range []func([]*string){
		func(row []*string) { row[12] = monitorRow("0")[0] },
		func(row []*string) { row[13] = monitorRow("9")[0] },
		func(row []*string) { row[14] = monitorRow("COMMITTED")[0] },
		func(row []*string) { row[15] = nil },
		func(row []*string) { row[16] = monitorRow("PREPARED")[0] },
	} {
		row := monitorActiveTimedRow("11")
		mutate(row)
		var session protocol.MonitoredSession
		if applyMonitorTiming(&session, row) != nil || session.TransactionAgeMs != nil {
			t.Fatal("completed, untimed or detached transaction acquired a live duration")
		}
	}
}

func TestMySQLMonitorCollectsActiveTimingsAndBothBoundedWaitKinds(t *testing.T) {
	snapshot, err := collectMonitorSnapshot(context.Background(), func(_ context.Context, sql string) ([][]*string, error) {
		switch sql {
		case monitorEnabledSQL:
			return [][]*string{monitorRow("1")}, nil
		case monitorTimedSessionsSQL:
			return [][]*string{monitorActiveTimedRow("11")}, nil
		case monitorWaitsSQL:
			rows := [][]*string{}
			for index := range protocol.MaxMonitorWaits {
				rows = append(rows, monitorRow("11", strconv.Itoa(index+20), "example.table", "X"))
			}
			return rows, nil
		case monitorMetadataInstrumentSQL:
			return [][]*string{monitorRow("YES")}, nil
		case monitorMetadataLostSQL:
			return [][]*string{monitorRow("0")}, nil
		case monitorMetadataWaitsSQL:
			return [][]*string{monitorRow("11", "12", "TABLE", "example", "table", "EXCLUSIVE", "SHARED_WRITE")}, nil
		}
		return nil, errors.New("unexpected monitoring query")
	}, "11")
	if err != nil || !snapshot.Valid() || len(snapshot.Waits) != protocol.MaxMonitorWaits || snapshot.WaitsComplete {
		t.Fatal("combined wait collectors exceeded their shared observation budget")
	}
	item := snapshot.Sessions[0]
	if item.QueryAgeMs == nil || *item.QueryAgeMs != "2" || item.TransactionAgeMs == nil || *item.TransactionAgeMs != "9" || item.WaitType == nil || *item.WaitType != "metadata" {
		t.Fatal("event timing or pending metadata state was lost during collection")
	}
	if snapshot.Waits[len(snapshot.Waits)-1].Kind != "metadata" {
		t.Fatal("data-lock rows consumed all capacity and hid metadata evidence")
	}
}

func TestMySQLMonitorBoundsAndDeduplicatesAllCollectorNotices(t *testing.T) {
	started := time.Now().UTC()
	snapshot := &protocol.SessionMonitorSnapshot{Engine: "mysql", CollectionStartedAt: started.Format(time.RFC3339Nano), Sessions: []protocol.MonitoredSession{}, Waits: []protocol.MonitorWait{}, SessionsComplete: false, WaitsComplete: false}
	for index := range 30 {
		snapshot.Notices = append(snapshot.Notices, "limitation "+strconv.Itoa(index), "shared limitation")
	}
	boundMonitorSnapshot(snapshot, started)
	if !snapshot.Valid() || len(snapshot.Notices) >= protocol.MaxMonitorNotices {
		t.Fatal("collector notices exhausted the reserved encoded-limit disclosure slot")
	}
	if !strings.Contains(snapshot.Notices[len(snapshot.Notices)-1], "Additional") {
		t.Fatal("omitted limitations were silently dropped")
	}
}
