package mariadb

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

func explainMonitorAdmin(t *testing.T) *Session {
	t.Helper()
	settings := dataIntegrationSettings(t)
	settings.User, settings.Password = os.Getenv("DBEER_TEST_MARIADB_ADMIN_USER"), os.Getenv("DBEER_TEST_MARIADB_ADMIN_PASSWORD")
	if settings.User == "" || settings.Password == "" {
		if os.Getenv("DBEER_REQUIRE_MARIADB_MONITOR") == "1" {
			t.Fatal("required private MariaDB monitor administrator is missing")
		}
		t.Skip("private MariaDB monitor administrator is not configured")
	}
	opened, err := Open(context.Background(), settings)
	if err != nil {
		t.Fatal("cannot open private native MariaDB monitor fixture")
	}
	s := opened.(*Session)
	t.Cleanup(s.Close)
	return s
}

func TestMariaDBMonitorNativeLiveInnoDBWaitAndRestrictedVisibility(t *testing.T) {
	observer, holder, waiter := explainMonitorAdmin(t), explainMonitorAdmin(t), explainMonitorAdmin(t)
	qualified := QuoteIdentifier(dataIntegrationSettings(t).Database) + "." + QuoteIdentifier(fmt.Sprintf("dbeer_monitor_native_%d", observer.connectionID))
	dataRun(t, observer, "CREATE TABLE "+qualified+" (id INT PRIMARY KEY,n INT NOT NULL) ENGINE=InnoDB")
	t.Cleanup(func() {
		holder.Execute(context.Background(), protocol.Command{SQL: "ROLLBACK"})
		waiter.Close()
		observer.Execute(context.Background(), protocol.Command{SQL: "DROP TABLE IF EXISTS " + qualified})
	})
	dataRun(t, observer, "INSERT INTO "+qualified+" VALUES(1,0)")
	dataRun(t, holder, "BEGIN")
	dataRun(t, holder, "UPDATE "+qualified+" SET n=n+1 WHERE id=1")
	dataRun(t, waiter, "BEGIN")
	if holder.TransactionStatus() != "transaction" || waiter.TransactionStatus() != "transaction" || holder.connectionID == waiter.connectionID {
		t.Fatal("native blocking fixture has no independent open transactions")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	done := make(chan protocol.Response, 1)
	go func() {
		done <- waiter.Execute(ctx, protocol.Command{SQL: "UPDATE " + qualified + " SET n=n+1 WHERE id=1"})
	}()
	deadline := time.Now().Add(5 * time.Second)
	found := false
	edgeSeen, sessionSeen, queryAgeSeen, transactionAgeSeen := false, false, false, false
	for time.Now().Before(deadline) {
		select {
		case completed := <-done:
			t.Fatalf("native lock waiter exited before observation: type=%s category=%s state=%s", completed.Type, completed.Category, completed.SQLState)
		default:
		}
		response := observer.MonitorSnapshot(context.Background(), protocol.Command{Type: "monitor.snapshot"})
		if response.Type != "monitor.result" || response.Monitor == nil || !response.Connected || response.TransactionStatus != "idle" {
			t.Fatalf("native monitor failed: %s/%s", response.Category, response.SQLState)
		}
		if strings.Contains(strings.Join(response.Monitor.Notices, " "), "InnoDB blocking relationships require additional access") {
			t.Fatal("private administrator cannot read the native InnoDB blocking views")
		}
		for _, edge := range response.Monitor.Waits {
			if edge.Kind == "data" && edge.WaitingID == strconv.FormatUint(uint64(waiter.connectionID), 10) && edge.BlockingID == strconv.FormatUint(uint64(holder.connectionID), 10) {
				edgeSeen = true
				for _, session := range response.Monitor.Sessions {
					if session.ID == edge.WaitingID {
						sessionSeen = true
						queryAgeSeen = session.QueryAgeMs != nil
						transactionAgeSeen = session.TransactionAgeMs != nil
					}
					if session.ID == edge.WaitingID && session.QueryAgeMs != nil && session.TransactionAgeMs != nil && session.WaitType != nil && *session.WaitType == "data" {
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
		t.Fatalf("native InnoDB witness incomplete: edge=%t session=%t commandAge=%t transactionAge=%t", edgeSeen, sessionSeen, queryAgeSeen, transactionAgeSeen)
	}
	dataRun(t, holder, "ROLLBACK")
	select {
	case result := <-done:
		if result.Type != "query.result" {
			t.Fatal("owned lock waiter did not resume")
		}
	case <-ctx.Done():
		t.Fatal("owned lock waiter did not complete")
	}
	dataRun(t, waiter, "ROLLBACK")
	limited := dataIntegrationSession(t)
	response := limited.MonitorSnapshot(context.Background(), protocol.Command{Type: "monitor.snapshot"})
	if response.Type != "monitor.result" || response.Monitor == nil || response.Monitor.SessionsComplete || response.Monitor.WaitsComplete || !strings.Contains(strings.Join(response.Monitor.Notices, " "), "additional access") {
		t.Fatal("restricted native monitoring claimed global or complete access")
	}
	for _, session := range response.Monitor.Sessions {
		if session.ID == strconv.FormatUint(uint64(holder.connectionID), 10) {
			t.Fatal("restricted account unexpectedly observed another user's session")
		}
	}
	if *dataRun(t, observer, "SELECT n FROM "+qualified).Rows[0][0] != "0" {
		t.Fatal("monitoring changed owned data or committed the held transactions")
	}
}

func TestMariaDBMonitorNativeLiveCancelledObservationDoesNotWrite(t *testing.T) {
	s := dataIntegrationSession(t)
	before := s.connectionID
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	response := s.MonitorSnapshot(ctx, protocol.Command{Type: "monitor.snapshot"})
	if response.Type != "error" || response.Category != "cancelled" || response.OutcomeUnknown || s.connectionID != before {
		t.Fatal("cancelled monitor observation created an unknown write or changed its physical owner")
	}
	dataRun(t, s, "SELECT 1")
}
