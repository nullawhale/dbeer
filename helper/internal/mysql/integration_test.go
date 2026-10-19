package mysql

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strconv"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

func integrationSettings(t *testing.T) protocol.Connection {
	t.Helper()
	port, err := strconv.Atoi(os.Getenv("DBEER_TEST_MYSQL_PORT"))
	if err != nil || port < 1 {
		if os.Getenv("DBEER_REQUIRE_MYSQL") == "1" {
			t.Fatal("required MySQL fixture is missing")
		}
		t.Skip("DBEER_TEST_MYSQL_PORT is not configured")
	}
	host := os.Getenv("DBEER_TEST_MYSQL_HOST")
	if host == "" {
		host = "localhost"
	}
	mode := os.Getenv("DBEER_TEST_MYSQL_SSLMODE")
	if mode == "" {
		mode = "disable"
	}
	return protocol.Connection{Engine: "mysql", Host: host, Port: port, User: os.Getenv("DBEER_TEST_MYSQL_USER"),
		Database: os.Getenv("DBEER_TEST_MYSQL_DATABASE"), Password: os.Getenv("DBEER_TEST_MYSQL_PASSWORD"),
		SSLMode: mode, SSLRootCert: os.Getenv("DBEER_TEST_MYSQL_CA_FILE")}
}

func integrationSession(t *testing.T) *Session {
	t.Helper()
	opened, err := Open(context.Background(), integrationSettings(t))
	if err != nil {
		t.Fatal("cannot open MySQL integration session")
	}
	session := opened.(*Session)
	t.Cleanup(session.Close)
	return session
}

func run(t *testing.T, session *Session, sql string) protocol.Response {
	t.Helper()
	response := session.Execute(context.Background(), protocol.Command{RequestID: "test", SessionID: "session", QueryID: "query", SQL: sql})
	if response.Type != "query.result" {
		t.Fatalf("MySQL test command failed: category=%s SQLSTATE=%s", response.Category, response.SQLState)
	}
	return response
}

func waitRunning(t *testing.T, session *Session) {
	t.Helper()
	observer, err := session.openControl(context.Background())
	if err != nil {
		t.Fatal("cannot open MySQL test observer")
	}
	defer observer.transport.Close()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		result, err := observer.client.Execute(fmt.Sprintf("SELECT ID FROM information_schema.PROCESSLIST WHERE ID = %d AND COMMAND = 'Query'", session.connectionID))
		if err != nil {
			t.Fatal("cannot inspect MySQL test execution")
		}
		active := result.RowNumber() == 1
		result.Close()
		if active {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("MySQL test query did not start")
}

func TestMySQLIndependentTransactionsTemporaryTablesAndValues(t *testing.T) {
	first, second := integrationSession(t), integrationSession(t)
	if first.connectionID == second.connectionID {
		t.Fatal("sessions share a physical connection")
	}
	for _, session := range []*Session{first, second} {
		run(t, session, "CREATE TEMPORARY TABLE dbeer_session_values (id INT PRIMARY KEY) ENGINE=InnoDB")
	}
	run(t, first, "BEGIN")
	run(t, first, "INSERT INTO dbeer_session_values VALUES (1)")
	if first.TransactionStatus() != "transaction" || second.TransactionStatus() != "idle" {
		t.Fatal("transaction state leaked")
	}
	if *run(t, second, "SELECT COUNT(*) FROM dbeer_session_values").Rows[0][0] != "0" {
		t.Fatal("temporary table leaked")
	}
	run(t, first, "ROLLBACK")
	if *run(t, first, "SELECT COUNT(*) FROM dbeer_session_values").Rows[0][0] != "0" {
		t.Fatal("transaction did not roll back")
	}
	response := run(t, first, "SELECT CAST('12345678901234567890.12345678901234567890' AS DECIMAL(40,20)) AS x, CAST('18446744073709551615' AS UNSIGNED) AS x, NULL AS x, '' AS x, 'NULL' AS x, 'κόσμος 🍺' AS x, X'00FF80' AS x")
	row := response.Rows[0]
	if *row[0] != "12345678901234567890.12345678901234567890" || *row[1] != "18446744073709551615" || row[2] != nil ||
		*row[3] != "" || *row[4] != "NULL" || *row[5] != "κόσμος 🍺" || *row[6] != "AP+A" || response.Columns[6].Encoding != "base64" {
		t.Fatal("MySQL values changed")
	}
	for _, column := range response.Columns {
		if column.Name != "x" || column.Engine != "mysql" {
			t.Fatal("column metadata changed")
		}
	}
}

func TestMySQLErrorRecoveryReportsImplicitCommit(t *testing.T) {
	session := integrationSession(t)
	table := fmt.Sprintf("dbeer_implicit_%d", time.Now().UnixNano())
	run(t, session, "CREATE TABLE `"+table+"` (id INT PRIMARY KEY) ENGINE=InnoDB")
	defer run(t, session, "DROP TABLE IF EXISTS `"+table+"`")
	run(t, session, "BEGIN")
	run(t, session, "INSERT INTO `"+table+"` VALUES (1)")
	response := session.Execute(context.Background(), protocol.Command{RequestID: "error", SQL: "CREATE TABLE `" + table + "` (id INT)"})
	if response.Type != "error" || !response.Connected || response.TransactionStatus != "idle" {
		t.Fatal("failed DDL implicit commit retained stale transaction flags")
	}
	run(t, session, "ROLLBACK")
	if *run(t, session, "SELECT COUNT(*) FROM `"+table+"`").Rows[0][0] != "1" {
		t.Fatal("server did not preserve implicit commit")
	}
	run(t, session, "BEGIN")
	response = session.Execute(context.Background(), protocol.Command{RequestID: "syntax", SQL: "SELEC invalid"})
	if !response.Connected || response.TransactionStatus != "transaction" || response.Category != "sql" {
		t.Fatal("SQL error failed to recover actual open transaction")
	}
	run(t, session, "ROLLBACK")
}

func TestMySQLCancelAndTimeoutPreserveNextQuery(t *testing.T) {
	for _, timeout := range []bool{false, true} {
		t.Run(fmt.Sprint(timeout), func(t *testing.T) {
			session, other := integrationSession(t), integrationSession(t)
			run(t, session, "BEGIN")
			ctx, cancel := context.WithCancel(context.Background())
			if timeout {
				ctx, cancel = context.WithTimeout(context.Background(), 200*time.Millisecond)
			}
			defer cancel()
			finished := make(chan protocol.Response, 1)
			go func() {
				finished <- session.Execute(ctx, protocol.Command{RequestID: "cancel", SQL: "SELECT 1 FROM (SELECT 1 AS n UNION ALL SELECT 2) source_rows WHERE SLEEP(10) = 0"})
			}()
			waitRunning(t, session)
			if !timeout {
				cancel()
			}
			select {
			case response := <-finished:
				category := "cancelled"
				if timeout {
					category = "timeout"
				}
				if response.Category != category || !response.Connected || response.TransactionStatus != "transaction" || response.OutcomeUnknown {
					t.Fatalf("MySQL cancellation state was not recovered: type=%s category=%s SQLSTATE=%s connected=%t transaction=%s unknown=%t", response.Type, response.Category, response.SQLState, response.Connected, response.TransactionStatus, response.OutcomeUnknown)
				}
			case <-time.After(6 * time.Second):
				t.Fatal("MySQL cancellation exceeded recovery bound")
			}
			if *run(t, session, "SELECT SLEEP(0.05), 1").Rows[0][0] != "0" {
				t.Fatal("late cancellation hit next query")
			}
			if *run(t, other, "SELECT 1").Rows[0][0] != "1" {
				t.Fatal("cancellation affected another session")
			}
			run(t, session, "ROLLBACK")
		})
	}
}

func TestMySQLFailedControlAndServerMismatchCloseSession(t *testing.T) {
	for _, mismatch := range []bool{false, true} {
		t.Run(fmt.Sprint(mismatch), func(t *testing.T) {
			session := integrationSession(t)
			if mismatch {
				session.serverUUID = "different-server"
			} else {
				session.openControl = func(context.Context) (*connection, error) { return nil, errors.New("unavailable control") }
			}
			ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
			defer cancel()
			started := time.Now()
			response := session.Execute(ctx, protocol.Command{RequestID: "failure", SQL: "SELECT SLEEP(10)"})
			if response.Connected || !response.OutcomeUnknown || !session.closed.Load() || time.Since(started) > 6*time.Second {
				t.Fatal("unsafe cancellation did not close session promptly")
			}
			if response = session.Execute(context.Background(), protocol.Command{RequestID: "next", SQL: "SELECT 1"}); response.Connected || !response.OutcomeUnknown {
				t.Fatal("closed session accepted next query")
			}
		})
	}
}

func TestMySQLLateControlNeverCancelsNextExecution(t *testing.T) {
	session := integrationSession(t)
	openControl := session.openControl
	entered, release := make(chan struct{}), make(chan struct{})
	session.openControl = func(ctx context.Context) (*connection, error) { close(entered); <-release; return openControl(ctx) }
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Millisecond)
	defer cancel()
	first := make(chan protocol.Response, 1)
	go func() { first <- session.Execute(ctx, protocol.Command{RequestID: "first", SQL: "SELECT SLEEP(0.1)"}) }()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("cancellation control did not start")
	}
	next := make(chan protocol.Response, 1)
	go func() {
		next <- session.Execute(context.Background(), protocol.Command{RequestID: "second", SQL: "SELECT SLEEP(0.2)"})
	}()
	select {
	case <-next:
		t.Fatal("next execution started during cancellation recovery")
	case <-time.After(150 * time.Millisecond):
	}
	close(release)
	select {
	case <-first:
	case <-time.After(time.Second):
		t.Fatal("first execution did not finish")
	}
	select {
	case response := <-next:
		if response.Type != "query.result" || *response.Rows[0][0] != "0" {
			t.Fatal("late KILL cancelled next query")
		}
	case <-time.After(time.Second):
		t.Fatal("next query stalled")
	}
}

func TestMySQLTLS(t *testing.T) {
	settings := integrationSettings(t)
	ca, untrusted := os.Getenv("DBEER_TEST_MYSQL_CA_FILE"), os.Getenv("DBEER_TEST_MYSQL_UNTRUSTED_CA_FILE")
	if ca == "" || untrusted == "" {
		if os.Getenv("DBEER_REQUIRE_MYSQL_TLS") == "1" {
			t.Fatal("required MySQL TLS fixture missing")
		}
		t.Skip("MySQL TLS fixture is not configured")
	}
	for _, scenario := range []struct {
		name, mode, host, ca string
		accepted             bool
	}{
		{"disabled", "disable", "localhost", "", true}, {"encryption", "require", "localhost", "", true},
		{"trusted", "verify-full", "localhost", ca, true}, {"chainOnly", "verify-ca", "127.0.0.1", ca, true},
		{"wrongHostname", "verify-full", "127.0.0.1", ca, false}, {"untrusted", "verify-full", "localhost", untrusted, false},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			settings.SSLMode, settings.Host, settings.SSLRootCert = scenario.mode, scenario.host, scenario.ca
			opened, err := Open(context.Background(), settings)
			if scenario.accepted {
				if err != nil {
					t.Fatal("expected MySQL TLS connection failed")
				}
				defer opened.Close()
				response := opened.Execute(context.Background(), protocol.Command{RequestID: "tls", SQL: "SHOW SESSION STATUS LIKE 'Ssl_cipher'"})
				if response.Type != "query.result" || len(response.Rows) != 1 {
					t.Fatal("TLS query failed")
				}
				if scenario.mode != "disable" && *response.Rows[0][1] == "" {
					t.Fatal("TLS silently fell back to plaintext")
				}
				if scenario.mode == "disable" && *response.Rows[0][1] != "" {
					t.Fatal("disable unexpectedly used TLS")
				}
			} else if err == nil {
				opened.Close()
				t.Fatal("invalid MySQL server certificate accepted")
			}
		})
	}
}

func TestMySQLStreamingLimitsDrainBeforeNextExecution(t *testing.T) {
	session := integrationSession(t)
	response := run(t, session, "WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<1000) SELECT n FROM seq CROSS JOIN (SELECT 1 AS x UNION ALL SELECT 2) pairs LIMIT 1101")
	if !response.Truncated || len(response.Rows) != 1000 || response.RowCount != 1101 {
		t.Fatal("streaming row limit/count incorrect")
	}
	response = run(t, session, "WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<12) SELECT REPEAT('x', 1000000) FROM seq")
	encoded, _ := json.Marshal(response)
	if !response.Truncated || len(encoded) > MaxResultBytes || response.RowCount != 12 {
		t.Fatal("streaming byte limit/count incorrect")
	}
	if *run(t, session, "SELECT 1").Rows[0][0] != "1" {
		t.Fatal("truncated stream was not drained")
	}
}

func TestMySQLConnectionLossReportsUnknownOutcome(t *testing.T) {
	session := integrationSession(t)
	observer, err := dial(context.Background(), integrationSettings(t))
	if err != nil {
		t.Fatal("cannot open MySQL failure observer")
	}
	defer observer.transport.Close()
	finished := make(chan protocol.Response, 1)
	go func() {
		finished <- session.Execute(context.Background(), protocol.Command{RequestID: "lost", SQL: "SELECT SLEEP(10)"})
	}()
	waitRunning(t, session)
	result, err := observer.client.Execute(fmt.Sprintf("KILL CONNECTION %d", session.connectionID))
	if err != nil {
		t.Fatal("cannot terminate test MySQL connection")
	}
	result.Close()
	select {
	case response := <-finished:
		if response.Connected || !response.OutcomeUnknown {
			t.Fatal("lost connection did not mark unknown outcome")
		}
	case <-time.After(time.Second):
		t.Fatal("lost connection did not finish promptly")
	}
}

func TestMySQLCompletedStatementRemainsSuccessfulAfterCancelRequest(t *testing.T) {
	session := integrationSession(t)
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	// MySQL defines interrupted standalone SLEEP as a successful result of 1.
	// Successful OK/EOF responses also win a completion/KILL race for writes.
	response := session.Execute(ctx, protocol.Command{RequestID: "completed", SQL: "SELECT SLEEP(10)"})
	if response.Type != "query.result" || *response.Rows[0][0] != "1" || response.DisplayNotice == "" {
		t.Fatal("a completed server response was incorrectly changed to cancelled")
	}
	if *run(t, session, "SELECT 1").Rows[0][0] != "1" {
		t.Fatal("completed cancellation left an unusable session")
	}
}
