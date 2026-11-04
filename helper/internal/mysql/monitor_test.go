package mysql

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func monitorRow(values ...string) []*string {
	row := make([]*string, len(values))
	for i := range values {
		value := values[i]
		row[i] = &value
	}
	return row
}

func TestMySQLMonitorSnapshotMapsConnectionsAndOmitsLostEndpoints(t *testing.T) {
	snapshot, err := collectMonitorSnapshot(context.Background(), func(_ context.Context, sql string) ([][]*string, error) {
		switch sql {
		case monitorEnabledSQL:
			return [][]*string{monitorRow("1")}, nil
		case monitorTimedSessionsSQL:
			return nil, &wire.MyError{Code: 1142}
		case monitorSessionsSQL:
			return [][]*string{monitorRow("11", "reader", "example", "localhost", "executing", "SELECT 1"), monitorRow("12", "reader", "example", "localhost", "Sleep", "")}, nil
		case monitorWaitsSQL:
			lost := monitorRow("11", "0", "example.table", "X")
			lost[1] = nil
			return [][]*string{monitorRow("11", "12", "example.table", "X"), monitorRow("11", "12", "example.table", "X"), lost}, nil
		case monitorMetadataInstrumentSQL:
			return [][]*string{monitorRow("YES")}, nil
		case monitorMetadataLostSQL:
			return [][]*string{monitorRow("0")}, nil
		case monitorMetadataWaitsSQL:
			return [][]*string{}, nil
		}
		return nil, errors.New("unexpected monitoring query")
	}, "11")
	if err != nil || !snapshot.Valid() || len(snapshot.Waits) != 1 || snapshot.WaitsComplete || !snapshot.Sessions[0].IsMonitor {
		t.Fatal("snapshot lost connection identities or invented a missing endpoint")
	}
	for _, item := range snapshot.Sessions {
		if item.QueryAgeMs != nil || item.TransactionAgeMs != nil {
			t.Fatal("process state time must not be presented as query or transaction duration")
		}
	}
}

func TestMySQLMonitorDisabledPermissionsAndCancellation(t *testing.T) {
	for _, disabled := range []bool{false, true} {
		calls := 0
		snapshot, err := collectMonitorSnapshot(context.Background(), func(_ context.Context, sql string) ([][]*string, error) {
			calls++
			if sql == monitorEnabledSQL {
				if disabled {
					return [][]*string{monitorRow("0")}, nil
				}
				return [][]*string{monitorRow("1")}, nil
			}
			return nil, &wire.MyError{Code: 1142, State: "42000", Message: "untrusted diagnostic"}
		}, "11")
		if err != nil || !snapshot.Valid() || snapshot.SessionsComplete || snapshot.WaitsComplete || disabled && calls != 1 {
			t.Fatal("disabled or inaccessible instrumentation appeared as a complete empty observation")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	_, err := collectMonitorSnapshot(ctx, func(_ context.Context, _ string) ([][]*string, error) {
		cancel()
		return nil, &wire.MyError{Code: 1142}
	}, "11")
	if !errors.Is(err, context.Canceled) {
		t.Fatal("cancellation was swallowed as unavailable instrumentation")
	}
	_, err = collectMonitorSnapshot(context.Background(), func(_ context.Context, _ string) ([][]*string, error) {
		return nil, errors.New("transport failure")
	}, "11")
	if err == nil {
		t.Fatal("transport failure was swallowed as an empty observation")
	}
}

func TestMySQLMonitorBoundsEncodedSnapshotAndRejectsMalformedIDs(t *testing.T) {
	rows := [][]*string{}
	for i := 1; i <= 501; i++ {
		rows = append(rows, monitorRow(strconv.Itoa(i), "reader", "example", "localhost", "executing", strings.Repeat("\x01", 4097)))
	}
	snapshot, err := collectMonitorSnapshot(context.Background(), func(_ context.Context, sql string) ([][]*string, error) {
		if sql == monitorEnabledSQL {
			return [][]*string{monitorRow("1")}, nil
		}
		if sql == monitorSessionsSQL {
			return rows, nil
		}
		if sql == monitorTimedSessionsSQL {
			return nil, &wire.MyError{Code: 1142}
		}
		return [][]*string{}, nil
	}, "1")
	if err != nil || !snapshot.Valid() || snapshot.SessionsComplete || len(snapshot.Sessions) >= protocol.MaxMonitoredSessions {
		t.Fatal("encoded control-character expansion exceeded the snapshot bound")
	}
	if _, _, err := decodeMonitorSession(monitorRow("0001", "reader", "example", "localhost", "executing", "SELECT 1"), "1"); err == nil {
		t.Fatal("noncanonical connection identity must fail closed")
	}
}
