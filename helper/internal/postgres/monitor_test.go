package postgres

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5/pgconn"
)

func monitorRow(values ...string) []*string {
	row := make([]*string, len(values))
	for i := range values {
		value := values[i]
		row[i] = &value
	}
	return row
}

func TestPostgresMonitorSnapshotRetainsTypedAgesAndPreparedBlockers(t *testing.T) {
	calls := 0
	snapshot, err := collectMonitorSnapshot(context.Background(), func(_ context.Context, sql string, args ...any) ([][]*string, error) {
		calls++
		switch sql {
		case monitorSessionsSQL:
			idle := monitorRow("11", "reader", "example", "local", "tool", "idle in transaction", "SELECT 1", "123", "9000", "Client", "ClientRead")
			active := monitorRow("12", "reader", "example", "local", "tool", "active", "SELECT 2", "7000", "8000", "Lock", "transactionid")
			return [][]*string{idle, active}, nil
		case monitorWaitsSQL:
			ids := args[0].([]int32)
			if len(ids) != 2 || ids[0] != 11 || ids[1] != 12 {
				t.Fatal("blocking lookup lost the bounded observed backend set")
			}
			return [][]*string{monitorRow("12", "11"), monitorRow("12", "11"), monitorRow("12", "0")}, nil
		}
		return nil, errors.New("unexpected monitoring query")
	}, "12")
	if err != nil || calls != 2 || !snapshot.Valid() || len(snapshot.Waits) != 2 || !snapshot.Sessions[1].IsMonitor {
		t.Fatal("monitor snapshot was invalid or duplicated parallel/prepared blockers")
	}
	if snapshot.Sessions[0].QueryAgeMs != nil || snapshot.Sessions[0].TransactionAgeMs == nil || *snapshot.Sessions[1].QueryAgeMs != "7000" {
		t.Fatal("idle last-query time must not be presented as a running duration")
	}
}

func TestPostgresMonitorPermissionsCancellationAndMalformedMetadata(t *testing.T) {
	for _, stage := range []int{1, 2} {
		calls := 0
		snapshot, err := collectMonitorSnapshot(context.Background(), func(_ context.Context, sql string, _ ...any) ([][]*string, error) {
			calls++
			if calls == stage {
				return nil, &pgconn.PgError{Code: "42501", Message: "untrusted diagnostic"}
			}
			return [][]*string{monitorRow("7", "reader", "example", "local", "tool", "active", "SELECT 1", "1", "1", "Lock", "relation")}, nil
		}, "7")
		if err != nil || !snapshot.Valid() || snapshot.WaitsComplete || stage == 1 && snapshot.SessionsComplete || len(snapshot.Notices) == 0 {
			t.Fatal("permission failure was presented as a complete empty observation")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	_, err := collectMonitorSnapshot(ctx, func(_ context.Context, _ string, _ ...any) ([][]*string, error) {
		cancel()
		return nil, &pgconn.PgError{Code: "42501"}
	}, "7")
	if !errors.Is(err, context.Canceled) {
		t.Fatal("cancellation was swallowed as a permission notice")
	}
	_, err = collectMonitorSnapshot(context.Background(), func(_ context.Context, _ string, _ ...any) ([][]*string, error) {
		return [][]*string{monitorRow("007")}, nil
	}, "7")
	if err == nil {
		t.Fatal("malformed session metadata must fail closed")
	}
}

func TestPostgresMonitorBoundsEncodedBytesAndUnicode(t *testing.T) {
	rows := [][]*string{}
	for i := 1; i <= 501; i++ {
		rows = append(rows, monitorRow(strconv.Itoa(i), "reader", "example", "local", "tool", "active", strings.Repeat("\x01", 4097), "1", "1", "Lock", "relation"))
	}
	snapshot, err := collectMonitorSnapshot(context.Background(), func(_ context.Context, sql string, args ...any) ([][]*string, error) {
		if sql == monitorSessionsSQL {
			return rows, nil
		}
		if len(args[0].([]int32)) != 500 {
			t.Fatal("blocking lookup exceeded the maximum observed session count")
		}
		return [][]*string{}, nil
	}, "1")
	if err != nil || !snapshot.Valid() || snapshot.SessionsComplete || snapshot.WaitsComplete || len(snapshot.Sessions) >= 500 {
		t.Fatal("encoded control-character expansion exceeded the snapshot bound")
	}
	value := "\xff\x00" + strings.Repeat("界", 2000)
	result, limited := monitorText(&value, 4096)
	if !limited || !utf8.ValidString(*result) || len(*result) > 4096 || strings.ContainsRune(*result, 0) {
		t.Fatal("display truncation split UTF-8 or retained invalid text")
	}
	started := time.Now().UTC().Add(time.Hour)
	boundMonitorSnapshot(snapshot, started)
	finished, err := time.Parse(time.RFC3339Nano, snapshot.CollectedAt)
	if err != nil || finished.Before(started) {
		t.Fatal("clock movement reversed the collection interval")
	}
}
