package mariadb

import (
	"context"
	"errors"
	"strings"
	"testing"
	"unicode/utf8"

	"dbeer/helper/internal/protocol"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func mariaDBMonitorRow(values ...string) []*string {
	row := make([]*string, len(values))
	for i := range values {
		value := values[i]
		row[i] = &value
	}
	return row
}

func TestMariaDBMonitorNativeObservationsAndPartialPermissions(t *testing.T) {
	for _, restricted := range []bool{false, true} {
		query := func(_ context.Context, sql string) ([][]*string, error) {
			switch sql {
			case mariaDBMonitorSessionsSQL:
				return [][]*string{mariaDBMonitorRow("0", "system", "", "", "Daemon", "", "0"), mariaDBMonitorRow("7", "user", "db", "localhost", "Sending data", "SELECT 1", "1234"), mariaDBMonitorRow("8", "user", "db", "localhost", "Updating", "UPDATE owned SET n=1", "17")}, nil
			case mariaDBMonitorTransactionsSQL:
				if restricted {
					return nil, &wire.MyError{Code: 1227}
				}
				return [][]*string{mariaDBMonitorRow("0", "0"), mariaDBMonitorRow("8", "9007199254740993")}, nil
			case mariaDBMonitorDataWaitsSQL:
				if restricted {
					return nil, &wire.MyError{Code: 1227}
				}
				return [][]*string{mariaDBMonitorRow("8", "7", "`db`.`owned`", "X"), mariaDBMonitorRow("8", "7", "`db`.`owned`", "X")}, nil
			case `SELECT CAST(@@performance_schema AS CHAR)`:
				return [][]*string{mariaDBMonitorRow("OFF")}, nil
			}
			return nil, errors.New("unexpected native monitor query")
		}
		result, err := collectMariaDBMonitor(context.Background(), query, "7")
		if err != nil || result.Engine != "mariadb" || len(result.Sessions) != 2 || !result.Sessions[0].IsMonitor || *result.Sessions[0].QueryAgeMs != "1234" || result.SessionsComplete || result.WaitsComplete {
			t.Fatal("native monitor mislabeled visibility or durations")
		}
		if restricted {
			if result.Sessions[1].TransactionAgeMs != nil || len(result.Waits) != 0 || !strings.Contains(strings.Join(result.Notices, " "), "additional access") {
				t.Fatal("restricted collection inferred unavailable transaction or wait facts")
			}
		} else if len(result.Waits) != 1 || *result.Sessions[1].TransactionAgeMs != "9007199254740993" || *result.Sessions[1].WaitType != "data" {
			t.Fatal("native ages, duplicate edges or data wait state were lost")
		}
	}
}

func TestMariaDBMonitorMetadataConfirmedEdgesOnly(t *testing.T) {
	read := func(sql string) ([][]*string, error) {
		switch {
		case strings.HasPrefix(sql, "SELECT CAST(@@performance_schema"):
			return [][]*string{mariaDBMonitorRow("1")}, nil
		case strings.Contains(sql, "setup_instruments"):
			return [][]*string{mariaDBMonitorRow("YES")}, nil
		case sql == mariaDBMonitorMetadataSQL:
			return [][]*string{
				mariaDBMonitorRow("8", "7", "TABLE", "CaseSensitive", "o`b", "EXCLUSIVE", "SHARED_READ"),
				mariaDBMonitorRow("9", "7", "TABLE", "db", "compatible", "SHARED_READ", "SHARED_READ"),
				mariaDBMonitorRow("10", "7", "SCHEMA", "db", "", "EXCLUSIVE", "SHARED"),
				mariaDBMonitorRow("11", "11", "TABLE", "db", "self", "EXCLUSIVE", "SHARED_READ"),
			}, nil
		}
		return nil, errors.New("unexpected instrumentation query")
	}
	snapshot := &protocol.SessionMonitorSnapshot{Sessions: []protocol.MonitoredSession{{ID: "8"}}, Waits: []protocol.MonitorWait{}}
	if err := collectMariaDBMetadataWaits(context.Background(), read, snapshot); err != nil || len(snapshot.Waits) != 1 || snapshot.Waits[0].Kind != "metadata" || *snapshot.Waits[0].Object != "`CaseSensitive`.`o``b`" || *snapshot.Sessions[0].WaitType != "metadata" {
		t.Fatal("metadata candidates were falsely presented as blocking edges")
	}
	if !strings.Contains(mariaDBMonitorMetadataSQL, "CAST(granted.OBJECT_NAME AS BINARY)") || !strings.Contains(mariaDBMonitorMetadataSQL, "CAST(granted.OBJECT_SCHEMA AS BINARY)") {
		t.Fatal("case-sensitive native object identities can collide")
	}
}

func TestMariaDBMonitorMalformedCancellationAndBounds(t *testing.T) {
	for _, row := range [][]*string{
		mariaDBMonitorRow("1", "u", "d", "h", "s", "q", "-1"),
		mariaDBMonitorRow("1", "u", "d", "h", "s", "q", "1.25"),
		mariaDBMonitorRow("18446744073709551616", "u", "d", "h", "s", "q", "1"),
	} {
		_, err := collectMariaDBMonitor(context.Background(), func(context.Context, string) ([][]*string, error) { return [][]*string{row}, nil }, "1")
		if err == nil {
			t.Fatal("accepted invalid native process metadata")
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	called := false
	_, err := collectMariaDBMonitor(ctx, func(context.Context, string) ([][]*string, error) { called = true; return nil, nil }, "1")
	if !errors.Is(err, context.Canceled) || called {
		t.Fatal("cancelled observation dispatched SQL")
	}
	text := strings.Repeat("é", protocol.MaxMonitorQueryBytes) + "\x00"
	limited, changed := mariaDBMonitorText(&text, protocol.MaxMonitorQueryBytes-1)
	if !changed || limited == nil || !utf8.ValidString(*limited) || strings.ContainsRune(*limited, 0) || len(*limited) > protocol.MaxMonitorQueryBytes-1 {
		t.Fatal("native text bounds split UTF-8 or leaked NUL")
	}
}
