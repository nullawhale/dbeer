package cassandra

import (
	"context"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestCassandraLocalRejectionsWereNotSent(t *testing.T) {
	session := &Session{}
	for _, sql := range []string{"", "COMMIT", "ROLLBACK", "BEGIN"} {
		response := session.Execute(context.Background(), protocol.Command{Type: "execute", SQL: sql})
		if response.Type != "error" || !response.SQLNotExecuted || response.OutcomeUnknown {
			t.Fatalf("unsupported or empty CQL was counted as executed: %q", sql)
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	response := session.Execute(ctx, protocol.Command{Type: "execute", SQL: "SELECT * FROM demo"})
	if response.Category != "cancelled" || !response.SQLNotExecuted || response.OutcomeUnknown {
		t.Fatal("CQL cancelled before its first statement was counted as executed")
	}
}
