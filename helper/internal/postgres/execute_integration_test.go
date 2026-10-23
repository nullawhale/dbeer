package postgres

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
)

// These tests use an explicitly supplied, disposable PostgreSQL database. The
// DSN and driver errors can contain credentials, so failures never print them.
type sqlIntegrationSession struct {
	t          *testing.T
	owner      *Owner
	observer   *pgx.Conn
	connection protocol.Connection
	sessionID  string
	sequence   int
}

func newSQLIntegrationSession(t *testing.T, queryTimeout time.Duration) *sqlIntegrationSession {
	t.Helper()
	return newSQLIntegrationSessionWithConnector(t, queryTimeout, connect)
}

func newSQLIntegrationSessionWithConnector(t *testing.T, queryTimeout time.Duration, connector connectFunc) *sqlIntegrationSession {
	t.Helper()
	dsn := os.Getenv("DBEER_TEST_DSN")
	if dsn == "" {
		t.Skip("DBEER_TEST_DSN is not configured")
	}
	cleanEnvironment(t)
	config, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal("invalid integration connection settings")
	}
	mode, ca := "disable", ""
	if parsed, err := url.Parse(dsn); err == nil && parsed.Scheme != "" {
		if value := parsed.Query().Get("sslmode"); value != "" {
			mode = value
		}
		ca = parsed.Query().Get("sslrootcert")
	} else if config.TLSConfig != nil {
		t.Fatal("integration DSN with TLS must use URL syntax")
	}
	connection := protocol.Connection{Host: config.Host, Port: int(config.Port), Database: config.Database,
		User: config.User, Password: config.Password, SSLMode: mode, SSLRootCert: ca}
	config.RuntimeParams["application_name"] = "DBeer SQL integration observer"
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	observer, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		t.Fatal("cannot connect integration observer")
	}
	owner := newOwnerWithTimeout(connector, queryTimeout)
	t.Cleanup(func() {
		owner.Close()
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = observer.Close(ctx)
	})
	h := &sqlIntegrationSession{t: t, owner: owner, observer: observer, connection: connection}
	command := protocol.Command{Type: "connect", RequestID: h.id(), Connection: &h.connection}
	h.submit(command)
	response := h.receive()
	if response.Type != "connect.result" || response.RequestID != command.RequestID || !protocol.ValidID(response.SessionID) || response.TransactionStatus != "idle" {
		t.Fatal("SQL integration session did not connect")
	}
	h.sessionID = response.SessionID
	return h
}

func (h *sqlIntegrationSession) id() string {
	h.sequence++
	return fmt.Sprintf("sql-integration-%d", h.sequence)
}

func (h *sqlIntegrationSession) submit(command protocol.Command) {
	h.t.Helper()
	if !h.owner.Submit(command) {
		h.t.Fatal("owner stopped before accepting an integration command")
	}
}

func (h *sqlIntegrationSession) receive() protocol.Response {
	h.t.Helper()
	select {
	case response, ok := <-h.owner.Responses():
		if !ok {
			h.t.Fatal("owner stopped before its terminal response")
		}
		return response
	case <-time.After(10 * time.Second):
		h.t.Fatal("SQL integration command did not finish promptly")
		return protocol.Response{}
	}
}

func (h *sqlIntegrationSession) start(sql string) protocol.Command {
	h.t.Helper()
	command := protocol.Command{Type: "execute", RequestID: h.id(), SessionID: h.sessionID, QueryID: h.id(), SQL: sql}
	h.submit(command)
	response := h.receive()
	if response.Type != "query.started" || response.RequestID != command.RequestID || response.QueryID != command.QueryID || response.SessionID != command.SessionID {
		h.t.Fatal("execute did not emit its matching start event")
	}
	return command
}

func (h *sqlIntegrationSession) finish(command protocol.Command) protocol.Response {
	h.t.Helper()
	response := h.receive()
	if response.RequestID != command.RequestID || response.QueryID != command.QueryID || response.SessionID != command.SessionID || (response.Type != "query.result" && response.Type != "error") {
		h.t.Fatal("execute did not emit exactly its matching terminal response")
	}
	return response
}

func (h *sqlIntegrationSession) execute(sql string) protocol.Response {
	h.t.Helper()
	return h.finish(h.start(sql))
}

func (h *sqlIntegrationSession) result(sql, commandTag, transactionStatus string, rowCount int64) protocol.Response {
	h.t.Helper()
	response := h.execute(sql)
	if response.Type != "query.result" || response.CommandTag != commandTag || response.RowCount != rowCount || response.TransactionStatus != transactionStatus || response.DurationMS < 0 || math.IsNaN(response.DurationMS) || math.IsInf(response.DurationMS, 0) {
		h.t.Fatalf("unexpected SQL outcome: type=%q category=%q tag=%q state=%q rows=%d", response.Type, response.Category, response.CommandTag, response.TransactionStatus, response.RowCount)
	}
	if response.DisplayedRowCount != len(response.Rows) {
		h.t.Fatal("displayed row count disagrees with the returned rows")
	}
	return response
}

func (h *sqlIntegrationSession) backendPID() int32 {
	h.t.Helper()
	response := h.result("SELECT pg_backend_pid()", "SELECT 1", "idle", 1)
	if len(response.Rows) != 1 || len(response.Rows[0]) != 1 || response.Rows[0][0] == nil {
		h.t.Fatal("backend PID was not returned")
	}
	pid, err := strconv.ParseInt(*response.Rows[0][0], 10, 32)
	if err != nil || pid <= 0 {
		h.t.Fatal("backend PID was not valid")
	}
	return int32(pid)
}

func (h *sqlIntegrationSession) backendExists(pid int32, activeOnly bool) bool {
	h.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	var exists bool
	err := h.observer.QueryRow(ctx, "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid=$1 AND (NOT $2::boolean OR state='active'))", pid, activeOnly).Scan(&exists)
	if err != nil {
		h.t.Fatal("cannot inspect PostgreSQL session state")
	}
	return exists
}

func (h *sqlIntegrationSession) waitBackend(pid int32, active, exists bool) {
	h.t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for h.backendExists(pid, active) != exists {
		if time.Now().After(deadline) {
			h.t.Fatal("PostgreSQL backend did not reach its expected state")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func (h *sqlIntegrationSession) waitSleeping(pid int32) {
	h.t.Helper()
	// Parse/Describe can briefly be active before Execute. Tests interrupting
	// server execution wait for the actual sleep event rather than that phase.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		var sleeping bool
		if err := h.observer.QueryRow(ctx, "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid=$1 AND wait_event='PgSleep')", pid).Scan(&sleeping); err != nil {
			h.t.Fatal("server execution did not begin")
		}
		if sleeping {
			return
		}
		time.Sleep(time.Millisecond)
	}
}

func assertSQLCell(t *testing.T, response protocol.Response, row, column int, expected *string) {
	t.Helper()
	if row >= len(response.Rows) || column >= len(response.Rows[row]) {
		t.Fatal("expected result cell is missing")
	}
	actual := response.Rows[row][column]
	if (actual == nil) != (expected == nil) || (actual != nil && *actual != *expected) {
		t.Fatalf("result cell %d,%d did not retain its exact PostgreSQL text", row, column)
	}
}

func sqlText(value string) *string { return &value }

func TestPostgresExecutePreservesTextAndColumnIdentity(t *testing.T) {
	h := newSQLIntegrationSession(t, 30*time.Second)
	unicode := "κόσμος\n世界\t\"\\"
	jsonText := `{"message":"κόσμος","items":[1,null]}`
	response := h.result(`SELECT 1 AS x, 2 AS x, NULL::text AS n, ''::text AS empty, 'NULL'::text AS literal,
		9007199254740993::bigint AS big,
		12345678901234567890.12345678901234567890::numeric AS exact,
		$dbeer$`+unicode+`$dbeer$::text AS unicode,
		'`+jsonText+`'::json AS payload`, "SELECT 1", "idle", 1)
	expected := []*string{sqlText("1"), sqlText("2"), nil, sqlText(""), sqlText("NULL"), sqlText("9007199254740993"), sqlText("12345678901234567890.12345678901234567890"), sqlText(unicode), sqlText(jsonText)}
	names := []string{"x", "x", "n", "empty", "literal", "big", "exact", "unicode", "payload"}
	oids := []uint32{23, 23, 25, 25, 25, 20, 1700, 25, 114}
	if len(response.Columns) != len(expected) || len(response.Rows) != 1 || len(response.Rows[0]) != len(expected) || response.Truncated {
		t.Fatal("SELECT result shape changed")
	}
	for i, value := range expected {
		if response.Columns[i].Index != i || response.Columns[i].Name != names[i] || response.Columns[i].TypeOID != oids[i] {
			t.Fatal("column ordering, duplicate name, or type OID was lost")
		}
		assertSQLCell(t, response, 0, i, value)
	}
	raw, err := json.Marshal(response)
	if err != nil || !json.Valid(raw) || strings.Contains(string(raw), "\n") {
		t.Fatal("result cannot be carried by one NDJSON frame")
	}
	var decoded protocol.Response
	if json.Unmarshal(raw, &decoded) != nil {
		t.Fatal("serialized result did not decode")
	}
	for i, value := range expected {
		assertSQLCell(t, decoded, 0, i, value)
	}
	response = h.result("SELECT 1 AS zero, NULL::text AS n WHERE false", "SELECT 0", "idle", 0)
	if len(response.Columns) != 2 || response.Columns[0].Name != "zero" || response.Columns[1].Name != "n" || len(response.Rows) != 0 || response.Truncated {
		t.Fatal("zero-row SELECT lost its column metadata")
	}
}

func TestPostgresExecuteKeepsOneSessionForDDLDMLAndTransactions(t *testing.T) {
	h := newSQLIntegrationSession(t, 30*time.Second)
	pid := h.backendPID()
	for _, command := range []struct {
		sql, tag string
		rows     int64
	}{
		{"CREATE TEMP TABLE dbeer_session_values (id bigint, marker text)", "CREATE TABLE", 0},
		{"INSERT INTO dbeer_session_values VALUES (1, 'first'), (2, 'second')", "INSERT 0 2", 2},
		{"UPDATE dbeer_session_values SET marker='updated' WHERE id=1", "UPDATE 1", 1},
		{"DELETE FROM dbeer_session_values WHERE id=2", "DELETE 1", 1},
	} {
		response := h.result(command.sql, command.tag, "idle", command.rows)
		if len(response.Columns) != 0 || len(response.Rows) != 0 || response.Truncated {
			t.Fatal("DDL or DML unexpectedly returned tabular data")
		}
	}
	response := h.result("SELECT id, marker FROM dbeer_session_values", "SELECT 1", "idle", 1)
	assertSQLCell(t, response, 0, 0, sqlText("1"))
	assertSQLCell(t, response, 0, 1, sqlText("updated"))
	h.result("BEGIN", "BEGIN", "transaction", 0)
	response = h.execute("SELECT 1/0")
	if response.Type != "error" || response.Category != "sql" || response.SQLState != "22012" || !response.Connected || response.OutcomeUnknown || response.TransactionStatus != "failedTransaction" {
		t.Fatal("SQL failure did not preserve the failed transaction state")
	}
	response = h.execute("SELECT 1")
	if response.Type != "error" || response.Category != "sql" || response.SQLState != "25P02" || !response.Connected || response.TransactionStatus != "failedTransaction" {
		t.Fatal("failed transaction was automatically reset")
	}
	h.result("ROLLBACK", "ROLLBACK", "idle", 0)
	h.result("BEGIN", "BEGIN", "transaction", 0)
	h.result("COMMIT", "COMMIT", "idle", 0)
	if h.backendPID() != pid {
		t.Fatal("SQL commands did not share one physical PostgreSQL session")
	}
}

func TestPostgresExecuteRejectsMultipleStatementsWithoutPartialExecution(t *testing.T) {
	h := newSQLIntegrationSession(t, 30*time.Second)
	h.result("CREATE TEMP TABLE dbeer_no_partial (id integer)", "CREATE TABLE", "idle", 0)
	response := h.execute("INSERT INTO dbeer_no_partial VALUES (1); INSERT INTO dbeer_no_partial VALUES (2)")
	if response.Type != "error" || response.Category != "sql" || response.SQLState != "42601" || !response.Connected || response.OutcomeUnknown || response.TransactionStatus != "idle" {
		t.Fatal("multiple statements were not rejected by the extended query protocol")
	}
	response = h.result("SELECT count(*) FROM dbeer_no_partial", "SELECT 1", "idle", 1)
	assertSQLCell(t, response, 0, 0, sqlText("0"))
	response = h.result("SELECT ';'::text AS semicolon", "SELECT 1", "idle", 1)
	assertSQLCell(t, response, 0, 0, sqlText(";"))
	h.result("DO $dbeer$ BEGIN PERFORM 1; PERFORM 2; END $dbeer$", "DO", "idle", 0)
}

func TestPostgresExecuteDrainsRowsPastDisplayLimits(t *testing.T) {
	h := newSQLIntegrationSession(t, 30*time.Second)
	pid := h.backendPID()
	response := h.result("SELECT n FROM generate_series(1, 1107) AS n", "SELECT 1107", "idle", 1107)
	if !response.Truncated || len(response.Rows) != 1000 || len(response.Columns) != 1 {
		t.Fatal("row limit did not retain exactly the first 1000 rows")
	}
	assertSQLCell(t, response, 0, 0, sqlText("1"))
	assertSQLCell(t, response, 999, 0, sqlText("1000"))
	if h.backendPID() != pid {
		t.Fatal("row-limited result did not leave the same session reusable")
	}
	for _, test := range []struct {
		name, sql string
		rows      int64
		largeRow  bool
	}{
		{"control-character escaping", "SELECT repeat(chr(1), 2048) AS escaped FROM generate_series(1, 1000)", 1000, false},
		{"HTML-character escaping", "SELECT repeat('<>&', 1024) AS escaped FROM generate_series(1, 1000)", 1000, false},
		{"single oversized row", "SELECT repeat('x', 9*1024*1024) AS oversized", 1, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			h := newSQLIntegrationSession(t, 30*time.Second)
			pid := h.backendPID()
			response := h.result(test.sql, "SELECT "+strconv.FormatInt(test.rows, 10), "idle", test.rows)
			raw, err := json.Marshal(response)
			if err != nil || len(raw) > 8*1024*1024 || !response.Truncated || len(response.Columns) != 1 {
				t.Fatal("serialized result exceeded its budget or omitted truncation metadata")
			}
			if test.largeRow && len(response.Rows) != 0 {
				t.Fatal("oversized row was retained")
			}
			if !test.largeRow && (len(response.Rows) == 0 || len(response.Rows) >= int(test.rows)) {
				t.Fatal("escaped rows were not budgeted by their serialized size")
			}
			if h.backendPID() != pid {
				t.Fatal("size-limited result was not fully drained on the same session")
			}
		})
	}
}

func TestPostgresExecuteCancelAndBusyGuards(t *testing.T) {
	h := newSQLIntegrationSession(t, 30*time.Second)
	pid := h.backendPID()
	query := h.start("SELECT pg_sleep(20)")
	h.waitBackend(pid, true, true)
	h.waitSleeping(pid)
	for _, command := range []protocol.Command{
		{Type: "execute", RequestID: h.id(), SessionID: h.sessionID, QueryID: h.id(), SQL: "SELECT 1"},
		{Type: "disconnect", RequestID: h.id(), SessionID: h.sessionID},
		{Type: "connect", RequestID: h.id(), Connection: &h.connection},
	} {
		h.submit(command)
		response := h.receive()
		if response.Type != "error" || response.RequestID != command.RequestID || response.Category != "busy" || !response.Connected || response.OutcomeUnknown {
			t.Fatal("conflicting command was not promptly rejected while SQL was active")
		}
	}
	wrongCancel := protocol.Command{Type: "cancel", RequestID: h.id(), SessionID: h.sessionID, QueryID: "not-the-active-query"}
	h.submit(wrongCancel)
	if response := h.receive(); response.Type != "cancel.ack" || response.RequestID != wrongCancel.RequestID || response.Status != "alreadyFinished" {
		t.Fatal("cancellation did not require the matching active query ID")
	}
	cancel := protocol.Command{Type: "cancel", RequestID: h.id(), SessionID: h.sessionID, QueryID: query.QueryID}
	h.submit(cancel)
	var final protocol.Response
	seenCancel := false
	for i := 0; i < 2; i++ {
		response := h.receive()
		switch response.RequestID {
		case cancel.RequestID:
			if seenCancel || response.Type != "cancel.ack" || response.Status != "accepted" {
				t.Fatal("active cancellation was not acknowledged exactly once")
			}
			seenCancel = true
		case query.RequestID:
			if final.Type != "" || response.QueryID != query.QueryID || response.SessionID != h.sessionID {
				t.Fatal("cancelled execute produced duplicate or mismatched terminal responses")
			}
			final = response
		default:
			t.Fatal("unexpected response while cancelling SQL")
		}
	}
	if !seenCancel || final.Type != "error" || final.Category != "cancelled" || final.SQLState != "57014" || !final.Connected || final.OutcomeUnknown || final.TransactionStatus != "idle" {
		t.Fatal("server cancellation did not preserve a known, reusable session")
	}
	if h.backendPID() != pid {
		t.Fatal("cancellation replaced the physical connection")
	}
	cancel.RequestID = h.id()
	h.submit(cancel)
	if response := h.receive(); response.Type != "cancel.ack" || response.RequestID != cancel.RequestID || response.Status != "alreadyFinished" {
		t.Fatal("finished query accepted a late cancellation")
	}
}

func TestPostgresExecuteCancelRaceCannotCancelNextQuery(t *testing.T) {
	h := newSQLIntegrationSession(t, 30*time.Second)
	pid := h.backendPID()
	for attempt := 0; attempt < 20; attempt++ {
		query := h.start("SELECT pg_sleep(0.003)")
		cancel := protocol.Command{Type: "cancel", RequestID: h.id(), SessionID: h.sessionID, QueryID: query.QueryID}
		h.submit(cancel)
		seenCancel, seenTerminal := false, false
		for i := 0; i < 2; i++ {
			response := h.receive()
			if response.RequestID == cancel.RequestID {
				if seenCancel || response.Type != "cancel.ack" || (response.Status != "accepted" && response.Status != "alreadyFinished") {
					t.Fatal("cancel race produced an invalid acknowledgement")
				}
				seenCancel = true
			} else if response.RequestID == query.RequestID {
				if seenTerminal || response.QueryID != query.QueryID || (response.Type != "query.result" && (response.Type != "error" || response.Category != "cancelled" || !response.Connected || response.OutcomeUnknown)) {
					t.Fatal("cancel race produced an invalid terminal response")
				}
				seenTerminal = true
			} else {
				t.Fatal("cancel race produced an unrelated response")
			}
		}
		if !seenCancel || !seenTerminal {
			t.Fatal("cancel race lost a command's terminal response")
		}
		response := h.result("SELECT pg_sleep(0.003), 42::integer", "SELECT 1", "idle", 1)
		assertSQLCell(t, response, 0, 1, sqlText("42"))
	}
	if h.backendPID() != pid {
		t.Fatal("cancel race replaced the physical connection")
	}
}

func TestPostgresExecuteTimeoutKeepsConnection(t *testing.T) {
	h := newSQLIntegrationSession(t, 150*time.Millisecond)
	pid := h.backendPID()
	started := time.Now()
	response := h.execute("SELECT pg_sleep(20)")
	if response.Type != "error" || response.Category != "timeout" || response.SQLState != "57014" || !response.Connected || response.OutcomeUnknown || response.TransactionStatus != "idle" || time.Since(started) > 6*time.Second {
		t.Fatal("SQL timeout did not cancel promptly while preserving the session")
	}
	if h.backendPID() != pid {
		t.Fatal("timeout replaced the physical connection")
	}
}

func TestPostgresExecuteTimeoutDisconnectsWhenCancellationCannotRecover(t *testing.T) {
	var cancelDialBlocked atomic.Bool
	var failedCancelDials atomic.Int32
	connector := func(ctx context.Context, connection protocol.Connection) (*pgx.Conn, error) {
		config, err := connectionConfig(connection)
		if err != nil {
			return nil, err
		}
		dial := config.DialFunc
		config.DialFunc = func(ctx context.Context, network, address string) (net.Conn, error) {
			if cancelDialBlocked.Load() {
				failedCancelDials.Add(1)
				return nil, errors.New("integration cancellation transport is unavailable")
			}
			return dial(ctx, network, address)
		}
		conn, err := pgx.ConnectConfig(ctx, config)
		if err == nil {
			cancelDialBlocked.Store(true)
		}
		return conn, err
	}
	h := newSQLIntegrationSessionWithConnector(t, 100*time.Millisecond, connector)
	pid := h.backendPID()
	t.Cleanup(func() {
		// A server running pg_sleep may notice the closed client socket only
		// when its query finishes. End this disposable backend promptly.
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_, _ = h.observer.Exec(ctx, "SELECT pg_terminate_backend($1) WHERE EXISTS (SELECT 1 FROM pg_stat_activity WHERE pid=$1)", pid)
	})
	started := time.Now()
	response := h.execute("SELECT pg_sleep(10)")
	elapsed := time.Since(started)
	if failedCancelDials.Load() == 0 {
		t.Fatal("test did not exercise a failed cancellation connection")
	}
	if response.Type != "error" || response.Category != "timeout" || response.Connected || !response.OutcomeUnknown || elapsed < 4500*time.Millisecond || elapsed > 8*time.Second {
		t.Fatal("failed server cancellation did not invalidate the session after the bounded recovery period")
	}
	stale := protocol.Command{Type: "execute", RequestID: h.id(), SessionID: h.sessionID, QueryID: h.id(), SQL: "SELECT 1"}
	h.submit(stale)
	response = h.receive()
	if response.Type != "error" || response.RequestID != stale.RequestID || response.Category != "connection" || response.Connected || response.OutcomeUnknown {
		t.Fatal("unrecovered timeout left the old session usable")
	}
}

func TestPostgresExecuteRejectsUnsupportedCopyWithoutEnteringCopyMode(t *testing.T) {
	h := newSQLIntegrationSession(t, 150*time.Millisecond)
	pid := h.backendPID()
	h.result("CREATE TEMP TABLE dbeer_copy_values (value text)", "CREATE TABLE", "idle", 0)
	for _, sql := range []string{
		"COPY dbeer_copy_values FROM STDIN",
		"-- leading comment\rCOPY dbeer_copy_values FROM STDIN",
		"-- leading comment\r\nCOPY dbeer_copy_values FROM STDIN",
		" \n -- leading comment\n /* outer /* nested */ comment */ COPY dbeer_copy_values FROM STDIN",
		"; /* empty statements */ ; COPY dbeer_copy_values FROM STDIN",
		"COPY (SELECT 1) TO STDOUT",
	} {
		response := h.execute(sql)
		if response.Type != "error" || response.Category != "sql" || !response.Connected || response.OutcomeUnknown || response.TransactionStatus != "idle" {
			t.Fatal("unsupported COPY was not rejected with the session intact")
		}
	}
	response := h.result("SELECT 'COPY'::text, count(*) FROM dbeer_copy_values", "SELECT 1", "idle", 1)
	assertSQLCell(t, response, 0, 0, sqlText("COPY"))
	assertSQLCell(t, response, 0, 1, sqlText("0"))
	if h.backendPID() != pid {
		t.Fatal("COPY rejection replaced the physical connection")
	}
}

func TestPostgresExecuteShutdownAndEOFReleaseActiveBackend(t *testing.T) {
	for _, closeViaEOF := range []bool{false, true} {
		name := "shutdown"
		if closeViaEOF {
			name = "stdin EOF"
		}
		t.Run(name, func(t *testing.T) {
			h := newSQLIntegrationSession(t, 30*time.Second)
			pid := h.backendPID()
			query := h.start("SELECT pg_sleep(20)")
			h.waitBackend(pid, true, true)
			if closeViaEOF {
				done := make(chan struct{})
				go func() { h.owner.Close(); close(done) }()
				select {
				case <-done:
				case <-time.After(6 * time.Second):
					t.Fatal("stdin EOF did not stop active SQL and its owner")
				}
			} else {
				shutdown := protocol.Command{Type: "shutdown", RequestID: h.id()}
				h.submit(shutdown)
				response := h.finish(query)
				if response.Type != "error" || response.Category != "cancelled" {
					t.Fatal("shutdown did not terminate the active execute command")
				}
				response = h.receive()
				if response.Type != "shutdown.ack" || response.RequestID != shutdown.RequestID {
					t.Fatal("shutdown was not acknowledged after active SQL completed")
				}
			}
			h.waitBackend(pid, false, false)
		})
	}
}

func TestPostgresExecuteConnectionLossInvalidatesSession(t *testing.T) {
	for _, selfTermination := range []bool{false, true} {
		name := "external termination"
		if selfTermination {
			name = "self termination"
		}
		t.Run(name, func(t *testing.T) {
			h := newSQLIntegrationSession(t, 30*time.Second)
			pid := h.backendPID()
			sql := "SELECT pg_sleep(20)"
			if selfTermination {
				sql = "SELECT pg_terminate_backend(pg_backend_pid())"
			}
			query := h.start(sql)
			if !selfTermination {
				h.waitSleeping(pid)
				ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
				defer cancel()
				var terminated bool
				if h.observer.QueryRow(ctx, "SELECT pg_terminate_backend($1)", pid).Scan(&terminated) != nil || !terminated {
					t.Fatal("integration observer could not terminate the active test backend")
				}
			}
			response := h.finish(query)
			if response.Type != "error" || response.Category != "connection" || response.Connected || !response.OutcomeUnknown {
				t.Fatalf("lost connection did not invalidate the session with an unknown SQL outcome: type=%q category=%q sqlState=%q connected=%t outcomeUnknown=%t", response.Type, response.Category, response.SQLState, response.Connected, response.OutcomeUnknown)
			}
			h.waitBackend(pid, false, false)
			stale := protocol.Command{Type: "execute", RequestID: h.id(), SessionID: h.sessionID, QueryID: h.id(), SQL: "SELECT 1"}
			h.submit(stale)
			response = h.receive()
			if response.Type != "error" || response.RequestID != stale.RequestID || response.Category != "connection" || response.Connected || response.OutcomeUnknown {
				t.Fatal("lost session was automatically reconnected or reused")
			}
			previousSession := h.sessionID
			reconnect := protocol.Command{Type: "connect", RequestID: h.id(), Connection: &h.connection}
			h.submit(reconnect)
			response = h.receive()
			if response.Type != "connect.result" || response.RequestID != reconnect.RequestID || response.SessionID == previousSession || !protocol.ValidID(response.SessionID) {
				t.Fatal("explicit reconnect did not create a fresh session")
			}
			h.sessionID = response.SessionID
			if h.backendPID() == pid {
				t.Fatal("explicit reconnect retained the terminated PostgreSQL backend")
			}
		})
	}
}
