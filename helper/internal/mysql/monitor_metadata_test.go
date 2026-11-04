package mysql

import (
	"context"
	"errors"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func metadataFixtureQuery(rows [][]*string) monitorQuery {
	return func(_ context.Context, sql string) ([][]*string, error) {
		switch sql {
		case monitorMetadataInstrumentSQL:
			return [][]*string{monitorRow("YES")}, nil
		case monitorMetadataLostSQL:
			return [][]*string{monitorRow("0")}, nil
		case monitorMetadataWaitsSQL:
			return rows, nil
		}
		return nil, errors.New("unexpected metadata query")
	}
}

func TestMySQLMonitorMetadataOnlyConfirmsExclusiveTableConflicts(t *testing.T) {
	rows := [][]*string{
		monitorRow("11", "12", "TABLE", "sample", "orders", "EXCLUSIVE", "SHARED_READ"),
		monitorRow("11", "12", "TABLE", "sample", "orders", "EXCLUSIVE", "SHARED_READ"),
		monitorRow("13", "12", "TABLE", "sample", "orders", "SHARED_READ", "SHARED_READ"),
		monitorRow("14", "14", "TABLE", "sample", "orders", "EXCLUSIVE", "SHARED_UPGRADABLE"),
		monitorRow("15", "16", "SCHEMA", "sample", "", "EXCLUSIVE", "INTENTION_EXCLUSIVE"),
		monitorRow("17", "18", "TABLE", "sample", "orders", "SHARED_WRITE", "EXCLUSIVE"),
		monitorRow("19", "20", "TABLE", "sample", "orders", "EXCLUSIVE", "FUTURE_MODE"),
	}
	waits, pending, complete, notices, err := collectMonitorMetadataWaits(context.Background(), metadataFixtureQuery(rows))
	if err != nil || complete || len(waits) != 2 || len(pending) != 6 || len(notices) == 0 {
		t.Fatal("metadata wait observation lost pending sessions or overstated completeness")
	}
	if waits[0].WaitingID != "11" || waits[0].BlockingID != "12" || waits[1].WaitingID != "17" ||
		waits[0].Kind != "metadata" || waits[0].Object == nil || *waits[0].Object != "`sample`.`orders`" {
		t.Fatal("confirmed metadata conflicts lost their owners or object identity")
	}
	for _, wait := range waits {
		if wait.WaitingID == wait.BlockingID || wait.WaitingID == "13" || wait.WaitingID == "15" || wait.WaitingID == "19" {
			t.Fatal("compatible, same-session or unsupported metadata locks were labelled blockers")
		}
	}
}

func TestMySQLMonitorMetadataDisabledDeniedAndLostInstrumentationAreExplicit(t *testing.T) {
	calls := 0
	waits, pending, complete, notices, err := collectMonitorMetadataWaits(context.Background(), func(context.Context, string) ([][]*string, error) {
		calls++
		return [][]*string{monitorRow("NO")}, nil
	})
	if err != nil || calls != 1 || complete || len(waits) != 0 || len(pending) != 0 || len(notices) == 0 {
		t.Fatal("disabled metadata instrumentation appeared as complete")
	}
	for _, lost := range []bool{false, true} {
		_, _, complete, notices, err = collectMonitorMetadataWaits(context.Background(), func(_ context.Context, sql string) ([][]*string, error) {
			switch sql {
			case monitorMetadataInstrumentSQL:
				return [][]*string{monitorRow("YES")}, nil
			case monitorMetadataLostSQL:
				if lost {
					return [][]*string{monitorRow("5")}, nil
				}
				return nil, &wire.MyError{Code: 1142, Message: "untrusted diagnostic"}
			case monitorMetadataWaitsSQL:
				return [][]*string{}, nil
			}
			return nil, errors.New("unexpected metadata query")
		})
		if err != nil || complete || len(notices) == 0 {
			t.Fatal("lost or unverifiable metadata records appeared complete")
		}
	}
	_, _, complete, notices, err = collectMonitorMetadataWaits(context.Background(), func(context.Context, string) ([][]*string, error) {
		return nil, &wire.MyError{Code: 1142, Message: "untrusted diagnostic"}
	})
	if err != nil || complete || strings.Contains(strings.Join(notices, " "), "untrusted diagnostic") {
		t.Fatal("metadata permission failure exposed raw diagnostics or complete coverage")
	}
}

func TestMySQLMonitorMetadataKeepsUnresolvedWaitersAndBoundsRows(t *testing.T) {
	unresolved := monitorRow("11", "12", "TABLE", "sample", "orders", "SHARED_READ", "SHARED_READ")
	unresolved[1], unresolved[6] = nil, nil
	rows := make([][]*string, protocol.MaxMonitorWaits+1)
	for index := range rows {
		rows[index] = unresolved
	}
	waits, pending, complete, notices, err := collectMonitorMetadataWaits(context.Background(), metadataFixtureQuery(rows))
	if err != nil || complete || len(waits) != 0 || !pending["11"] || len(notices) > 4 {
		t.Fatal("unresolved metadata waiter was lost or row limit was ignored")
	}
	for _, notice := range notices {
		if len(notice) > protocol.MaxMonitorFieldBytes {
			t.Fatal("metadata diagnostic exceeded transport bounds")
		}
	}
	_, _, complete, _, err = collectMonitorMetadataWaits(context.Background(), metadataFixtureQuery([][]*string{}))
	if err != nil || !complete {
		t.Fatal("enabled metadata collection with no pending requests is invalid")
	}
}

func TestMySQLMonitorMetadataCancellationAndMalformedIdentitiesFailClosed(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	_, _, _, _, err := collectMonitorMetadataWaits(ctx, func(context.Context, string) ([][]*string, error) {
		cancel()
		return nil, &wire.MyError{Code: 1142}
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatal("metadata cancellation was swallowed as a permissions notice")
	}
	bad := monitorRow("0011", "12", "TABLE", "sample", "orders", "EXCLUSIVE", "SHARED_READ")
	if _, _, _, _, err := collectMonitorMetadataWaits(context.Background(), metadataFixtureQuery([][]*string{bad})); err == nil {
		t.Fatal("metadata collection accepted a malformed connection identifier")
	}
	if _, _, _, _, err := collectMonitorMetadataWaits(context.Background(), func(context.Context, string) ([][]*string, error) {
		return nil, errors.New("transport failure")
	}); err == nil {
		t.Fatal("metadata transport failure appeared as an empty observation")
	}
}
