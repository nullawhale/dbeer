package postgres

import (
	"context"
	"fmt"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

func TestPostgresReadOnlyServerModeAndTransactionGuard(t *testing.T) {
	h := newSQLIntegrationSession(t, 5*time.Second)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	opened, err := Open(ctx, h.connection)
	if err != nil {
		t.Fatal("cannot open read-only integration session")
	}
	session := opened.(*Session)
	defer session.Close()
	table := fmt.Sprintf("dbeer_readonly_%d", time.Now().UnixNano())
	if _, err := h.observer.Exec(ctx, "CREATE TABLE "+table+" (id integer)"); err != nil {
		t.Fatal("cannot create read-only integration fixture")
	}
	t.Cleanup(func() {
		if _, err := h.observer.Exec(context.Background(), "DROP TABLE IF EXISTS "+table); err != nil {
			t.Error("cannot remove read-only integration fixture")
		}
	})
	if err := session.SetReadOnly(ctx, true); err != nil {
		t.Fatal("cannot enable server read-only mode")
	}
	execute := func(sql string) protocol.Response { return session.Execute(ctx, protocol.Command{SQL: sql}) }
	response := execute("SHOW default_transaction_read_only")
	if response.Type != "query.result" || len(response.Rows) != 1 || response.Rows[0][0] == nil || *response.Rows[0][0] != "on" {
		t.Fatal("server default transaction mode is not read-only")
	}
	if response := execute("SELECT count(*) FROM " + table); response.Type != "query.result" {
		t.Fatal("server read-only mode rejected a read")
	}
	if response := execute("INSERT INTO " + table + " VALUES (1)"); response.Type != "error" || response.SQLState != "25006" || !response.Connected {
		t.Fatalf("server read-only write outcome: type=%s SQLSTATE=%s", response.Type, response.SQLState)
	}
	if response := execute("BEGIN"); response.Type != "query.result" || session.TransactionStatus() != "transaction" {
		t.Fatal("cannot begin read-only transaction")
	}
	if err := session.SetReadOnly(ctx, false); err == nil || session.TransactionStatus() != "transaction" {
		t.Fatal("changing mode must preserve and reject an open transaction")
	}
	if response := execute("ROLLBACK"); response.Type != "query.result" {
		t.Fatal("cannot finish read-only transaction")
	}
	if err := session.SetReadOnly(ctx, false); err != nil {
		t.Fatal("cannot restore server read-write mode")
	}
	if response := execute("INSERT INTO " + table + " VALUES (2)"); response.Type != "query.result" {
		t.Fatal("restored read-write mode rejected a write")
	}
}
