package mysql

import (
	"context"
	"fmt"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

func TestMySQLReadOnlyServerModeAndTransactionGuard(t *testing.T) {
	session := integrationSession(t)
	table := fmt.Sprintf("dbeer_readonly_%d", time.Now().UnixNano())
	run(t, session, "CREATE TABLE `"+table+"` (id INT) ENGINE=InnoDB")
	t.Cleanup(func() {
		_ = session.SetReadOnly(context.Background(), false)
		run(t, session, "DROP TABLE IF EXISTS `"+table+"`")
	})
	if err := session.SetReadOnly(context.Background(), true); err != nil {
		t.Fatal("cannot enable server read-only mode")
	}
	response := run(t, session, "SELECT @@session.transaction_read_only")
	if len(response.Rows) != 1 || response.Rows[0][0] == nil || *response.Rows[0][0] != "1" {
		t.Fatal("server default transaction mode is not read-only")
	}
	run(t, session, "SELECT count(*) FROM `"+table+"`")
	response = session.Execute(context.Background(), protocol.Command{SQL: "INSERT INTO `" + table + "` VALUES (1)"})
	if response.Type != "error" || response.SQLState != "25006" || !response.Connected {
		t.Fatalf("server read-only write outcome: type=%s SQLSTATE=%s", response.Type, response.SQLState)
	}
	run(t, session, "BEGIN")
	if err := session.SetReadOnly(context.Background(), false); err == nil || session.TransactionStatus() != "transaction" {
		t.Fatal("changing mode must preserve and reject an open transaction")
	}
	run(t, session, "ROLLBACK")
	if err := session.SetReadOnly(context.Background(), false); err != nil {
		t.Fatal("cannot restore server read-write mode")
	}
	run(t, session, "INSERT INTO `"+table+"` VALUES (2)")
}

func TestMySQLReadOnlyRejectsNonIdleStateWithoutSQL(t *testing.T) {
	for _, state := range []string{"transaction", "failedTransaction", "unknown"} {
		session := &Session{}
		session.transaction.Store(state)
		if err := session.SetReadOnly(context.Background(), true); err == nil || session.TransactionStatus() != state {
			t.Fatalf("mode change accepted non-idle state %s", state)
		}
	}
}
