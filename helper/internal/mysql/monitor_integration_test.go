package mysql

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

func TestMySQLMonitorRestrictedPermissionsArePartial(t *testing.T) {
	session := integrationSession(t)
	response := session.MonitorSnapshot(context.Background(), protocol.Command{Type: "monitor.snapshot", RequestID: "monitor", SessionID: "monitor", QueryID: "snapshot"})
	if response.Type != "monitor.result" || response.Monitor == nil || !response.Monitor.Valid() {
		t.Fatalf("restricted MySQL monitor failed: category=%s SQLSTATE=%s", response.Category, response.SQLState)
	}
	if !response.Connected || response.TransactionStatus != "idle" {
		t.Fatal("monitor observation omitted its reusable idle connection status")
	}
	if _, err := json.Marshal(response); err != nil {
		t.Fatal("real monitor observation could not cross the protocol serialization boundary")
	}
	if response.Monitor.SessionsComplete || len(response.Monitor.Notices) == 0 {
		t.Fatal("restricted MySQL credentials incorrectly reported complete server visibility")
	}
	if session.TransactionStatus() != "idle" {
		t.Fatal("restricted monitor unexpectedly opened a transaction")
	}
}

func TestMySQLMonitorIndependentBlockedSessions(t *testing.T) {
	if os.Getenv("DBEER_TEST_MYSQL_MONITOR_PRIVILEGES") != "1" {
		t.Skip("monitor lock checks require disposable DBEER_TEST_MYSQL_MONITOR_PRIVILEGES=1")
	}
	holder, waiter := integrationSession(t), integrationSession(t)
	settings := integrationSettings(t)
	settings.User, settings.Password = os.Getenv("DBEER_TEST_MYSQL_MONITOR_USER"), os.Getenv("DBEER_TEST_MYSQL_MONITOR_PASSWORD")
	if settings.User == "" || settings.Password == "" {
		t.Fatal("disposable MySQL monitor credentials are missing")
	}
	opened, err := Open(context.Background(), settings)
	if err != nil {
		t.Fatal("cannot open independent MySQL monitor")
	}
	monitor := opened.(*Session)
	defer monitor.Close()
	table := QuoteIdentifier(fmt.Sprintf("dbeer_monitor_%d", time.Now().UnixNano()))
	run(t, holder, "CREATE TABLE "+table+" (id INTEGER PRIMARY KEY,value INTEGER) ENGINE=InnoDB")
	defer run(t, holder, "DROP TABLE IF EXISTS "+table)
	run(t, holder, "INSERT INTO "+table+" VALUES (1,0)")
	run(t, holder, "BEGIN")
	defer run(t, holder, "ROLLBACK")
	run(t, holder, "UPDATE "+table+" SET value=1 WHERE id=1")
	waitCtx, stopWait := context.WithTimeout(context.Background(), 8*time.Second)
	done := make(chan protocol.Response, 1)
	go func() {
		defer close(done)
		done <- waiter.Execute(waitCtx, protocol.Command{Type: "execute", SQL: "UPDATE " + table + " SET value=2 WHERE id=1"})
	}()
	defer func() { stopWait(); <-done }()
	holderID := strconv.FormatUint(uint64(holder.connectionID), 10)
	waiterID := strconv.FormatUint(uint64(waiter.connectionID), 10)
	command := protocol.Command{Type: "monitor.snapshot", RequestID: "monitor", SessionID: "monitor", QueryID: "snapshot"}
	observed := false
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		response := monitor.MonitorSnapshot(context.Background(), command)
		if response.Type != "monitor.result" || response.Monitor == nil || !response.Monitor.Valid() {
			t.Fatalf("MySQL monitor collection failed: category=%s SQLSTATE=%s", response.Category, response.SQLState)
		}
		for _, edge := range response.Monitor.Waits {
			if edge.WaitingID == waiterID && edge.BlockingID == holderID {
				observed = true
			}
		}
		if observed {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !observed || holder.TransactionStatus() != "transaction" || monitor.TransactionStatus() != "idle" {
		t.Fatal("independent MySQL monitor missed its blocker or changed the holder transaction")
	}
	cancelCtx, stop := context.WithCancel(context.Background())
	stop()
	response := monitor.MonitorSnapshot(cancelCtx, command)
	if response.Type != "error" || response.Category != "cancelled" || holder.TransactionStatus() != "transaction" {
		t.Fatal("MySQL monitor cancellation altered the independently held transaction")
	}
	run(t, holder, "ROLLBACK")
	if response := <-done; response.Type != "query.result" {
		t.Fatal("MySQL waiter did not complete after its blocker released the transaction")
	}
	response = monitor.MonitorSnapshot(context.Background(), command)
	if response.Type != "monitor.result" || response.Monitor == nil {
		t.Fatal("MySQL monitor failed after lock release")
	}
	for _, edge := range response.Monitor.Waits {
		if edge.WaitingID == waiterID && edge.BlockingID == holderID {
			t.Fatal("released MySQL blocker remained in the next snapshot")
		}
	}
}

func TestMySQLMonitorLostOwnTransportHasNoWriteOutcome(t *testing.T) {
	holder, monitor := integrationSession(t), integrationSession(t)
	run(t, holder, "BEGIN")
	defer run(t, holder, "ROLLBACK")
	run(t, holder, "SELECT 1")
	if monitor.work.transport.Close() != nil {
		t.Fatal("cannot close the monitor's own test transport")
	}
	response := monitor.MonitorSnapshot(context.Background(), protocol.Command{Type: "monitor.snapshot", RequestID: "lost-monitor", SessionID: "monitor", QueryID: "lost-monitor"})
	if response.Type != "error" || response.Category != "connection" || response.Connected || response.OutcomeUnknown || response.TransactionStatus != "unknown" || !strings.Contains(response.Message, "monitor connection") {
		t.Fatalf("lost read-only monitor transport carried an incorrect outcome: type=%s category=%s connected=%t unknown=%t", response.Type, response.Category, response.Connected, response.OutcomeUnknown)
	}
	if holder.TransactionStatus() != "transaction" {
		t.Fatal("monitor transport loss altered another session's transaction")
	}
	run(t, holder, "SELECT 1")
}
