package postgres

import (
	"context"
	"strconv"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
)

func TestPostgresMonitorRestrictedRoleKeepsMaskedActivityUnavailable(t *testing.T) {
	fixture := newChangeFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var canCreateRole bool
	if fixture.observer.QueryRow(ctx, "SELECT rolsuper OR rolcreaterole FROM pg_catalog.pg_roles WHERE rolname=current_user").Scan(&canCreateRole) != nil {
		t.Fatal("cannot inspect disposable role fixture privileges")
	}
	if !canCreateRole {
		t.Skip("restricted monitor checks require disposable role creation privileges")
	}
	role := pgx.Identifier{fixture.schema + "_monitor"}.Sanitize()
	fixture.exec("CREATE ROLE " + role)
	t.Cleanup(func() { fixture.exec("DROP ROLE " + role) })
	monitorConn, err := connect(ctx, fixture.settings)
	if err != nil {
		t.Fatal("cannot open restricted PostgreSQL monitor")
	}
	defer closeConnection(monitorConn)
	if _, err = monitorConn.Exec(ctx, "SET ROLE "+role); err != nil {
		t.Fatal("cannot select the disposable restricted role")
	}
	monitor := &Session{conn: monitorConn}
	if monitor.SetReadOnly(ctx, true) != nil {
		t.Fatal("cannot enable physical readonly monitoring")
	}
	var readonly string
	if monitorConn.QueryRow(ctx, "SHOW default_transaction_read_only").Scan(&readonly) != nil || readonly != "on" {
		t.Fatal("monitor physical session did not retain readonly mode")
	}
	response := monitor.MonitorSnapshot(ctx, protocol.Command{Type: "monitor.snapshot", RequestID: "restricted-monitor", SessionID: "restricted-monitor", QueryID: "snapshot"})
	if response.Type != "monitor.result" || response.Monitor == nil || !response.Monitor.Valid() {
		t.Fatalf("restricted PostgreSQL collection failed: category=%s SQLSTATE=%s", response.Category, response.SQLState)
	}
	holderID := strconv.FormatUint(uint64(fixture.conn.PgConn().PID()), 10)
	for _, session := range response.Monitor.Sessions {
		if session.ID == holderID {
			if session.Query != nil || session.State != nil || session.QueryAgeMs != nil || session.TransactionAgeMs != nil || response.Monitor.SessionsComplete || len(response.Monitor.Notices) == 0 {
				t.Fatal("restricted activity was presented as visible or complete")
			}
			if monitor.TransactionStatus() != "idle" {
				t.Fatal("restricted monitoring opened a transaction")
			}
			return
		}
	}
	t.Fatal("restricted monitor omitted the independently owned session")
}

func TestPostgresMonitorClosedReadHasNoUnknownWriteOutcome(t *testing.T) {
	fixture := newChangeFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := connect(ctx, fixture.settings)
	if err != nil {
		t.Fatal("cannot open the disposable monitor connection")
	}
	closeConnection(conn)
	monitor := &Session{conn: conn}
	response := monitor.MonitorSnapshot(ctx, protocol.Command{Type: "monitor.snapshot", RequestID: "closed-monitor", SessionID: "closed-monitor", QueryID: "snapshot"})
	if response.Type != "error" || response.Connected || response.OutcomeUnknown || response.Monitor != nil {
		t.Fatal("a closed readonly monitor reported a usable session or uncertain write outcome")
	}
}
