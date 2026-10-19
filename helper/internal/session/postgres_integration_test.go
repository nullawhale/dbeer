package session_test

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"strconv"
	"testing"
	"time"

	"dbeer/helper/internal/postgres"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/session"
	"github.com/jackc/pgx/v5"
)

type pgHarness struct {
	t          *testing.T
	manager    *session.Manager
	observer   *pgx.Conn
	connection protocol.Connection
	sequence   int
}

func newPGHarness(t *testing.T) *pgHarness {
	t.Helper()
	dsn := os.Getenv("DBEER_TEST_DSN")
	if dsn == "" {
		t.Skip("DBEER_TEST_DSN is not configured")
	}
	postgres.PrepareEnvironment()
	config, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal("invalid PostgreSQL integration configuration")
	}
	mode, ca := "disable", ""
	if parsed, err := url.Parse(dsn); err == nil && parsed.Scheme != "" {
		if value := parsed.Query().Get("sslmode"); value != "" {
			mode = value
		}
		ca = parsed.Query().Get("sslrootcert")
	} else if config.TLSConfig != nil {
		t.Fatal("TLS integration configuration requires URL syntax")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	observer, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		t.Fatal("cannot connect PostgreSQL integration observer")
	}
	manager := session.New(postgres.Open)
	t.Cleanup(func() {
		manager.Close()
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = observer.Close(ctx)
	})
	return &pgHarness{t: t, manager: manager, observer: observer, connection: protocol.Connection{Engine: "postgresql", Host: config.Host, Port: int(config.Port), Database: config.Database, User: config.User, Password: config.Password, SSLMode: mode, SSLRootCert: ca}}
}

func (h *pgHarness) id() string {
	h.sequence++
	return fmt.Sprintf("multi-pg-%d", h.sequence)
}

func (h *pgHarness) send(command protocol.Command) {
	h.t.Helper()
	if !h.manager.Submit(command) {
		h.t.Fatal("session manager stopped unexpectedly")
	}
}

func (h *pgHarness) receive() protocol.Response {
	h.t.Helper()
	select {
	case response, ok := <-h.manager.Responses():
		if !ok {
			h.t.Fatal("session manager stopped before its response")
		}
		return response
	case <-time.After(8 * time.Second):
		h.t.Fatal("session manager did not respond promptly")
		return protocol.Response{}
	}
}

func (h *pgHarness) connect() string {
	h.t.Helper()
	command := protocol.Command{Type: "connect", RequestID: h.id(), Connection: &h.connection}
	h.send(command)
	response := h.receive()
	if response.Type != "connect.result" || response.RequestID != command.RequestID || response.Engine != "postgresql" || response.TransactionStatus != "idle" || len(response.Capabilities) == 0 || !protocol.ValidID(response.SessionID) {
		h.t.Fatal("real PostgreSQL session did not connect with engine capabilities")
	}
	return response.SessionID
}

func (h *pgHarness) start(id, sql string) protocol.Command {
	h.t.Helper()
	command := protocol.Command{Type: "execute", RequestID: h.id(), SessionID: id, QueryID: h.id(), SQL: sql}
	h.send(command)
	response := h.receive()
	if response.Type != "query.started" || response.RequestID != command.RequestID || response.SessionID != id || response.QueryID != command.QueryID {
		h.t.Fatal("query did not publish a correlated start event")
	}
	return command
}

func (h *pgHarness) query(id, sql, state string) protocol.Response {
	h.t.Helper()
	command := h.start(id, sql)
	response := h.receive()
	if response.Type != "query.result" || response.RequestID != command.RequestID || response.SessionID != id || response.QueryID != command.QueryID || response.TransactionStatus != state {
		h.t.Fatalf("unexpected PostgreSQL query outcome: type=%q category=%q state=%q", response.Type, response.Category, response.TransactionStatus)
	}
	for _, column := range response.Columns {
		if column.Engine != "postgresql" || column.NativeType == "" {
			h.t.Fatal("PostgreSQL result omitted engine-native type metadata")
		}
	}
	return response
}

func (h *pgHarness) pid(id string) int32 {
	h.t.Helper()
	response := h.query(id, "SELECT pg_backend_pid()", "idle")
	if len(response.Rows) != 1 || len(response.Rows[0]) != 1 || response.Rows[0][0] == nil {
		h.t.Fatal("PostgreSQL session did not return its backend PID")
	}
	pid, err := strconv.ParseInt(*response.Rows[0][0], 10, 32)
	if err != nil || pid <= 0 {
		h.t.Fatal("PostgreSQL backend PID is invalid")
	}
	return int32(pid)
}

func (h *pgHarness) waitBackend(pid int32, exists, active bool) {
	h.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	for {
		var found bool
		err := h.observer.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE pid=$1 AND (NOT $2::boolean OR state='active'))", pid, active).Scan(&found)
		if err != nil {
			h.t.Fatal("cannot inspect PostgreSQL backend state")
		}
		if found == exists {
			return
		}
		select {
		case <-ctx.Done():
			h.t.Fatal("PostgreSQL backend did not reach its expected state")
		case <-time.After(10 * time.Millisecond):
		}
	}
}

func TestPostgresSessionsKeepIndependentTransactionsSettingsAndTempTables(t *testing.T) {
	h := newPGHarness(t)
	a, b := h.connect(), h.connect()
	if h.pid(a) == h.pid(b) {
		t.Fatal("logical SQL sessions shared one physical connection")
	}
	h.query(a, "BEGIN", "transaction")
	h.query(a, "SET application_name = 'DBeer isolated A'", "transaction")
	h.query(a, "CREATE TEMP TABLE dbeer_isolated_session(value text)", "transaction")
	h.query(a, "INSERT INTO dbeer_isolated_session VALUES ('only A')", "transaction")
	response := h.query(b, "SELECT current_setting('application_name'), to_regclass('pg_temp.dbeer_isolated_session')::text", "idle")
	if len(response.Rows) != 1 || *response.Rows[0][0] != "DBeer" || response.Rows[0][1] != nil {
		t.Fatal("session settings or temporary tables escaped their SQL tab")
	}
	query := h.start(a, "SELECT 1/0")
	response = h.receive()
	if response.Type != "error" || response.RequestID != query.RequestID || response.SQLState != "22012" || response.TransactionStatus != "failedTransaction" || !response.Connected {
		t.Fatal("SQL error did not preserve only A's failed transaction")
	}
	h.query(b, "SELECT 42", "idle")
	h.query(b, "BEGIN", "transaction")
	h.query(a, "ROLLBACK", "idle")
	h.query(a, "SELECT 42", "idle")
	h.query(b, "SELECT 42", "transaction")
	h.query(b, "ROLLBACK", "idle")
}

func TestPostgresSessionsConnectAndStopWhileOtherQueriesRemainActive(t *testing.T) {
	h := newPGHarness(t)
	a, b := h.connect(), h.connect()
	pidA, pidB := h.pid(a), h.pid(b)
	qa := h.start(a, "SELECT pg_sleep(20)")
	qb := h.start(b, "SELECT pg_sleep(20)")
	h.waitBackend(pidA, true, true)
	h.waitBackend(pidB, true, true)
	c := h.connect() // Two long SQL commands must not block a third connection.
	h.query(c, "SELECT 42", "idle")
	cancel := protocol.Command{Type: "cancel", RequestID: h.id(), SessionID: a, QueryID: qa.QueryID}
	h.send(cancel)
	for range 2 {
		response := h.receive()
		if response.RequestID == cancel.RequestID {
			if response.Type != "cancel.ack" || response.Status != "accepted" {
				t.Fatal("Stop did not acknowledge the selected execution")
			}
		} else if response.RequestID != qa.RequestID || response.Type != "error" || response.Category != "cancelled" || response.SQLState != "57014" || !response.Connected || response.OutcomeUnknown {
			t.Fatal("Stop affected an execution in another SQL session")
		}
	}
	h.waitBackend(pidB, true, true)
	h.query(a, "SELECT 42", "idle")
	h.send(protocol.Command{Type: "disconnect", RequestID: h.id(), SessionID: a})
	if h.receive().Type != "disconnect.ack" {
		t.Fatal("selected session did not disconnect")
	}
	h.waitBackend(pidA, false, false)
	h.waitBackend(pidB, true, true)
	// Disconnect must cancel only B, and its execute retains one terminal event.
	h.send(protocol.Command{Type: "disconnect", RequestID: h.id(), SessionID: b})
	terminal, ack := h.receive(), h.receive()
	if terminal.RequestID != qb.RequestID || terminal.Category != "cancelled" || ack.Type != "disconnect.ack" {
		t.Fatal("disconnect did not terminate its selected execution and session")
	}
	h.waitBackend(pidB, false, false)
	h.query(c, "SELECT 42", "idle")
}

func TestPostgresSessionLossInvalidatesOnlyItsOwnSession(t *testing.T) {
	h := newPGHarness(t)
	a, b := h.connect(), h.connect()
	pid := h.pid(a)
	command := h.start(a, "SELECT pg_sleep(20)")
	h.waitBackend(pid, true, true)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	var terminated bool
	if h.observer.QueryRow(ctx, "SELECT pg_terminate_backend($1)", pid).Scan(&terminated) != nil || !terminated {
		t.Fatal("cannot terminate the disposable PostgreSQL test backend")
	}
	response := h.receive()
	if response.RequestID != command.RequestID || response.Type != "error" || response.Connected || !response.OutcomeUnknown {
		t.Fatal("lost physical connection did not invalidate its execution")
	}
	h.query(b, "SELECT 42", "idle")
	h.send(protocol.Command{Type: "execute", RequestID: h.id(), SessionID: a, QueryID: h.id(), SQL: "SELECT 42"})
	if response := h.receive(); response.Type != "error" || response.Connected || response.OutcomeUnknown {
		t.Fatal("failed session remained available after connection loss")
	}
}
