package mysql

import (
	"context"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestMySQLLocalRejectionsWereNotSent(t *testing.T) {
	for _, sql := range []string{"COPY demo FROM STDIN", "LOAD DATA LOCAL INFILE 'fixture' INTO TABLE demo", "\\status"} {
		session := &Session{}
		session.transaction.Store("idle")
		response := session.Execute(context.Background(), protocol.Command{Type: "execute", SQL: sql})
		if response.Type != "error" || !response.SQLNotExecuted || response.OutcomeUnknown {
			t.Fatalf("local unsupported command was counted as executed: %q", sql)
		}
	}
	for _, closed := range []bool{false, true} {
		session := &Session{}
		session.transaction.Store("idle")
		session.closed.Store(closed)
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		response := session.Execute(ctx, protocol.Command{Type: "execute", SQL: "SELECT 1"})
		if response.Type != "error" || !response.SQLNotExecuted || response.OutcomeUnknown {
			t.Fatal("closed or cancelled-before-send command was counted as executed")
		}
	}
}
