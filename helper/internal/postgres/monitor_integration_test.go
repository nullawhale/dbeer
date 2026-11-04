package postgres

import (
	"context"
	"strconv"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

func TestPostgresMonitorIndependentBlockedSessions(t *testing.T) {
	fixture := newChangeFixture(t)
	table := fixture.table("monitor_locks")
	fixture.exec("CREATE TABLE " + table + " (id integer PRIMARY KEY, value integer)")
	fixture.exec("INSERT INTO " + table + " VALUES (1,0)")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	waiter, err := connect(ctx, fixture.settings)
	if err != nil {
		t.Fatal("cannot open PostgreSQL monitor waiter")
	}
	defer closeConnection(waiter)
	monitorConn, err := connect(ctx, fixture.settings)
	if err != nil {
		t.Fatal("cannot open independent PostgreSQL monitor")
	}
	defer closeConnection(monitorConn)
	monitor := &Session{conn: monitorConn}
	if _, err := fixture.conn.Exec(ctx, "BEGIN"); err != nil {
		t.Fatal("cannot begin PostgreSQL monitor holder transaction")
	}
	defer fixture.conn.Exec(context.Background(), "ROLLBACK")
	if _, err := fixture.conn.Exec(ctx, "UPDATE "+table+" SET value=1 WHERE id=1"); err != nil {
		t.Fatal("cannot establish PostgreSQL monitor holder lock")
	}
	waitCtx, stopWait := context.WithTimeout(context.Background(), 8*time.Second)
	done := make(chan error, 1)
	go func() {
		defer close(done)
		_, err := waiter.Exec(waitCtx, "UPDATE "+table+" SET value=2 WHERE id=1")
		done <- err
	}()
	defer func() { stopWait(); <-done }()
	holderID := strconv.FormatUint(uint64(fixture.conn.PgConn().PID()), 10)
	waiterID := strconv.FormatUint(uint64(waiter.PgConn().PID()), 10)
	command := protocol.Command{Type: "monitor.snapshot", RequestID: "monitor", SessionID: "monitor", QueryID: "snapshot"}
	observed := false
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		response := monitor.MonitorSnapshot(ctx, command)
		if response.Type != "monitor.result" || response.Monitor == nil || !response.Monitor.Valid() {
			t.Fatalf("PostgreSQL monitor collection failed: category=%s SQLSTATE=%s", response.Category, response.SQLState)
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
	if !observed || transactionStatus(fixture.conn) != "transaction" || monitor.TransactionStatus() != "idle" {
		t.Fatal("independent monitor missed the blocker or changed the holder transaction")
	}
	cancelCtx, stop := context.WithCancel(context.Background())
	stop()
	response := monitor.MonitorSnapshot(cancelCtx, command)
	if response.Type != "error" || response.Category != "cancelled" || transactionStatus(fixture.conn) != "transaction" {
		t.Fatal("monitor cancellation altered the independently held transaction")
	}
	if _, err := fixture.conn.Exec(ctx, "ROLLBACK"); err != nil {
		t.Fatal("cannot release PostgreSQL holder transaction")
	}
	if err := <-done; err != nil {
		t.Fatal("waiter did not finish after its blocker released the transaction")
	}
	response = monitor.MonitorSnapshot(ctx, command)
	if response.Type != "monitor.result" || response.Monitor == nil {
		t.Fatal("PostgreSQL monitor failed after lock release")
	}
	for _, edge := range response.Monitor.Waits {
		if edge.WaitingID == waiterID && edge.BlockingID == holderID {
			t.Fatal("released PostgreSQL blocker remained in the next snapshot")
		}
	}
}
