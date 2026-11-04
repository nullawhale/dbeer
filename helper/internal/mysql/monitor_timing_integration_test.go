package mysql

import (
	"context"
	"os"
	"strconv"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

func TestMySQLMonitorActiveEventTimingsExpireAfterQueryAndTransaction(t *testing.T) {
	if os.Getenv("DBEER_TEST_MYSQL_MONITOR_PRIVILEGES") != "1" {
		t.Skip("timing checks require the disposable instrumented monitor fixture")
	}
	target := integrationSession(t)
	settings := integrationSettings(t)
	settings.User, settings.Password = os.Getenv("DBEER_TEST_MYSQL_MONITOR_USER"), os.Getenv("DBEER_TEST_MYSQL_MONITOR_PASSWORD")
	if settings.User == "" || settings.Password == "" {
		t.Fatal("disposable MySQL monitor credentials are missing")
	}
	opened, err := Open(context.Background(), settings)
	if err != nil {
		t.Fatal("cannot open independent timing observer")
	}
	monitor := opened.(*Session)
	defer monitor.Close()
	if monitor.SetReadOnly(context.Background(), true) != nil {
		t.Fatal("cannot set readonly timing observer")
	}
	run(t, target, "BEGIN")
	defer run(t, target, "ROLLBACK")
	queryContext, stopQuery := context.WithTimeout(context.Background(), 8*time.Second)
	defer stopQuery()
	done := make(chan protocol.Response, 1)
	go func() {
		done <- target.Execute(queryContext, protocol.Command{Type: "execute", RequestID: "timed-query", SessionID: "target", QueryID: "timed-query", SQL: "SELECT SLEEP(10)"})
	}()
	queryFinished := false
	defer func() {
		stopQuery()
		if !queryFinished {
			<-done
		}
	}()
	waitRunning(t, target)
	id := strconv.FormatUint(uint64(target.connectionID), 10)
	command := protocol.Command{Type: "monitor.snapshot", RequestID: "timing", SessionID: "observer", QueryID: "timing"}
	observe := func() protocol.MonitoredSession {
		t.Helper()
		response := monitor.MonitorSnapshot(context.Background(), command)
		if response.Type != "monitor.result" || response.Monitor == nil || !response.Monitor.Valid() {
			t.Fatalf("timing observation failed: category=%s SQLSTATE=%s", response.Category, response.SQLState)
		}
		for _, item := range response.Monitor.Sessions {
			if item.ID == id {
				return item
			}
		}
		t.Fatal("active timing target was not visible")
		return protocol.MonitoredSession{}
	}
	observed := false
	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		item := observe()
		if item.QueryAgeMs != nil && item.TransactionAgeMs != nil && *item.QueryAgeMs != "0" && *item.TransactionAgeMs != "0" {
			observed = true
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !observed || target.TransactionStatus() != "transaction" || monitor.TransactionStatus() != "idle" {
		t.Fatal("active instrumented query and transaction durations were unavailable or changed transaction ownership")
	}
	stopQuery()
	response := <-done
	queryFinished = true
	// An interrupted standalone SLEEP can return a successful result instead of
	// an interruption error. Both outcomes authoritatively finish this read.
	authoritative := response.Type == "query.result" || response.Type == "error" && response.Category == "cancelled"
	if !authoritative || response.OutcomeUnknown || response.Type == "error" && !response.Connected || target.closed.Load() || response.TransactionStatus != "transaction" {
		t.Fatalf("timing read lacks an authoritative terminal state: type=%s category=%s connected=%t unknown=%t", response.Type, response.Category, response.Connected, response.OutcomeUnknown)
	}
	item := observe()
	if item.QueryAgeMs != nil || item.TransactionAgeMs == nil || target.TransactionStatus() != "transaction" {
		t.Fatal("completed query retained timing or erased the still-open transaction timing")
	}
	run(t, target, "ROLLBACK")
	item = observe()
	if item.QueryAgeMs != nil || item.TransactionAgeMs != nil {
		t.Fatal("completed Performance Schema events were presented as active durations")
	}
}
