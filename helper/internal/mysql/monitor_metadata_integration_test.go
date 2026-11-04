package mysql

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

func TestMySQLMonitorMetadataIndependentDDLWait(t *testing.T) {
	if os.Getenv("DBEER_TEST_MYSQL_MONITOR_PRIVILEGES") != "1" {
		t.Skip("metadata lock checks require disposable DBEER_TEST_MYSQL_MONITOR_PRIVILEGES=1")
	}
	holder, waiter, queuedReader := integrationSession(t), integrationSession(t), integrationSession(t)
	settings := integrationSettings(t)
	settings.User, settings.Password = os.Getenv("DBEER_TEST_MYSQL_MONITOR_USER"), os.Getenv("DBEER_TEST_MYSQL_MONITOR_PASSWORD")
	if settings.User == "" || settings.Password == "" {
		t.Fatal("disposable MySQL observer credentials are missing")
	}
	opened, err := Open(context.Background(), settings)
	if err != nil {
		t.Fatal("cannot open independent metadata observer")
	}
	monitor := opened.(*Session)
	defer monitor.Close()
	if monitor.SetReadOnly(context.Background(), true) != nil {
		t.Fatal("cannot make metadata observer readonly")
	}
	table := QuoteIdentifier(fmt.Sprintf("dbeer_monitor_metadata_%d", time.Now().UnixNano()))
	run(t, holder, "CREATE TABLE "+table+" (id INTEGER PRIMARY KEY) ENGINE=InnoDB")
	defer run(t, holder, "DROP TABLE IF EXISTS "+table)
	run(t, holder, "BEGIN")
	defer run(t, holder, "ROLLBACK")
	run(t, holder, "SELECT * FROM "+table)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	done := make(chan protocol.Response, 1)
	go func() {
		defer close(done)
		done <- waiter.Execute(ctx, protocol.Command{Type: "execute", SQL: "ALTER TABLE " + table + " ADD COLUMN marker INTEGER"})
	}()
	defer func() { cancel(); <-done }()
	command := protocol.Command{Type: "monitor.snapshot", RequestID: "metadata-monitor", SessionID: "metadata-monitor", QueryID: "metadata-snapshot"}
	holderID := strconv.FormatUint(uint64(holder.connectionID), 10)
	waiterID := strconv.FormatUint(uint64(waiter.connectionID), 10)
	observed := false
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		response := monitor.MonitorSnapshot(context.Background(), command)
		if response.Type != "monitor.result" || response.Monitor == nil || !response.Monitor.Valid() {
			t.Fatalf("metadata observer failed: category=%s SQLSTATE=%s", response.Category, response.SQLState)
		}
		for _, edge := range response.Monitor.Waits {
			if edge.Kind == "metadata" && edge.WaitingID == waiterID && edge.BlockingID == holderID {
				observed = true
			}
			if edge.Kind == "metadata" && edge.WaitingID == edge.BlockingID {
				t.Fatal("DDL's own upgradable lock was reported as a blocker")
			}
		}
		if observed {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !observed || holder.TransactionStatus() != "transaction" || monitor.TransactionStatus() != "idle" {
		t.Fatal("metadata observer missed the DDL blocker or changed an independent transaction")
	}
	// A new reader waits behind the pending DDL even though its requested read
	// lock is compatible with the original holder. The lock queue is not exposed
	// by Performance Schema: retain the waiting session without inventing an edge.
	readerCtx, cancelReader := context.WithTimeout(context.Background(), 10*time.Second)
	readerDone := make(chan protocol.Response, 1)
	go func() {
		defer close(readerDone)
		readerDone <- queuedReader.Execute(readerCtx, protocol.Command{Type: "execute", SQL: "SELECT * FROM " + table})
	}()
	defer func() { cancelReader(); <-readerDone }()
	readerID := strconv.FormatUint(uint64(queuedReader.connectionID), 10)
	readerObserved := false
	deadline = time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		response := monitor.MonitorSnapshot(context.Background(), command)
		if response.Type != "monitor.result" || response.Monitor == nil || !response.Monitor.Valid() {
			t.Fatal("metadata observer failed while sampling a queued reader")
		}
		for _, session := range response.Monitor.Sessions {
			if session.ID == readerID && session.WaitType != nil && *session.WaitType == "metadata" {
				readerObserved = true
			}
		}
		for _, edge := range response.Monitor.Waits {
			if edge.Kind == "metadata" && edge.WaitingID == readerID && edge.BlockingID == holderID {
				t.Fatal("a compatible granted reader was reported as a metadata blocker")
			}
		}
		if readerObserved {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !readerObserved {
		t.Fatal("queued metadata reader was omitted when its blocker could not be proven")
	}
	run(t, holder, "ROLLBACK")
	if response := <-done; response.Type != "query.result" {
		t.Fatal("DDL did not finish after its metadata blocker released")
	}
	if response := <-readerDone; response.Type != "query.result" {
		t.Fatal("queued reader did not finish after DDL released its metadata lock")
	}
	response := monitor.MonitorSnapshot(context.Background(), command)
	if response.Type != "monitor.result" || response.Monitor == nil {
		t.Fatal("metadata observer failed after lock release")
	}
	for _, edge := range response.Monitor.Waits {
		if edge.Kind == "metadata" && edge.WaitingID == waiterID && edge.BlockingID == holderID {
			t.Fatal("released metadata blocker remained in the next observation")
		}
	}
}
