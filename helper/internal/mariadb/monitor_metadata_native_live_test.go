package mariadb

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

func TestMariaDBMonitorNativeEnabledMetadataConflict(t *testing.T) {
	if os.Getenv("DBEER_TEST_MARIADB_PERFORMANCE_SCHEMA") != "1" {
		if os.Getenv("DBEER_REQUIRE_MARIADB_MONITOR_P_S") == "1" {
			t.Fatal("required enabled native Performance Schema fixture is missing")
		}
		t.Skip("enabled native Performance Schema fixture is not selected")
	}
	observer, holder, waiter := explainMonitorAdmin(t), explainMonitorAdmin(t), explainMonitorAdmin(t)
	before := dataRun(t, observer, `SELECT ENABLED,TIMED FROM performance_schema.setup_instruments WHERE NAME='wait/lock/metadata/sql/mdl'`).Rows
	if len(before) != 1 || len(before[0]) != 2 || before[0][0] == nil || before[0][1] == nil {
		t.Fatal("native metadata instrumentation is unavailable")
	}
	for _, value := range before[0] {
		if *value != "YES" && *value != "NO" {
			t.Fatal("native metadata instrumentation has an unknown state")
		}
	}
	// Explicit fixture setup on this owned disposable server. Production
	// MonitorSnapshot never enables or changes instrumentation.
	dataRun(t, observer, `UPDATE performance_schema.setup_instruments SET ENABLED='YES',TIMED='YES' WHERE NAME='wait/lock/metadata/sql/mdl'`)
	t.Cleanup(func() {
		observer.Execute(context.Background(), protocol.Command{SQL: `UPDATE performance_schema.setup_instruments SET ENABLED='` + *before[0][0] + `',TIMED='` + *before[0][1] + `' WHERE NAME='wait/lock/metadata/sql/mdl'`})
	})
	qualified := QuoteIdentifier(dataIntegrationSettings(t).Database) + "." + QuoteIdentifier(fmt.Sprintf("dbeer_metadata_native_%d", observer.connectionID))
	dataRun(t, observer, "CREATE TABLE "+qualified+" (id INT PRIMARY KEY) ENGINE=InnoDB")
	t.Cleanup(func() {
		holder.Execute(context.Background(), protocol.Command{SQL: "ROLLBACK"})
		waiter.Close()
		observer.Execute(context.Background(), protocol.Command{SQL: "DROP TABLE IF EXISTS " + qualified})
	})
	dataRun(t, observer, "INSERT INTO "+qualified+" VALUES(1)")
	dataRun(t, holder, "BEGIN")
	dataRun(t, holder, "SELECT id FROM "+qualified)
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	done := make(chan protocol.Response, 1)
	go func() {
		done <- waiter.Execute(ctx, protocol.Command{SQL: "ALTER TABLE " + qualified + " ADD COLUMN owned_extra INT NULL"})
	}()
	deadline := time.Now().Add(5 * time.Second)
	found := false
	for time.Now().Before(deadline) {
		select {
		case completed := <-done:
			t.Fatalf("native metadata waiter completed before its conflict: %s/%s", completed.Type, completed.Category)
		default:
		}
		response := observer.MonitorSnapshot(context.Background(), protocol.Command{Type: "monitor.snapshot"})
		if response.Type != "monitor.result" || response.Monitor == nil || !response.Monitor.Valid() || !response.Connected {
			t.Fatal("enabled native metadata observation failed")
		}
		for _, edge := range response.Monitor.Waits {
			if edge.Kind == "metadata" && edge.WaitingID == strconv.FormatUint(uint64(waiter.connectionID), 10) && edge.BlockingID == strconv.FormatUint(uint64(holder.connectionID), 10) && edge.Object != nil && *edge.Object == qualified {
				for _, session := range response.Monitor.Sessions {
					if session.ID == edge.WaitingID && session.WaitType != nil && *session.WaitType == "metadata" {
						found = true
					}
				}
			}
		}
		if found {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}
	if !found {
		t.Fatal("actual native EXCLUSIVE metadata blocker and waiting physical owner were not observed")
	}
	dataRun(t, holder, "ROLLBACK")
	select {
	case completed := <-done:
		if completed.Type != "query.result" {
			t.Fatal("owned native metadata waiter did not finish after release")
		}
	case <-ctx.Done():
		t.Fatal("owned native metadata waiter did not finish")
	}
	if *dataRun(t, observer, "SELECT COUNT(*) FROM "+qualified).Rows[0][0] != "1" {
		t.Fatal("native metadata collection changed owned row data")
	}
}
