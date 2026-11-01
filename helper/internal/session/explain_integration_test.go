package session_test

import (
	"os"
	"strconv"
	"testing"
	"time"

	"dbeer/helper/internal/mysql"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/session"
)

func TestVisualExplainPostgresLive(t *testing.T) {
	h := newPGHarness(t)
	exerciseVisualExplain(t, h.manager, h.connection, "postgresql")
}
func TestVisualExplainMySQLLive(t *testing.T) {
	port, err := strconv.Atoi(os.Getenv("DBEER_TEST_MYSQL_PORT"))
	if err != nil || port < 1 {
		t.Skip("MySQL disposable fixture missing")
	}
	c := protocol.Connection{Engine: "mysql", Host: "localhost", Port: port, Database: os.Getenv("DBEER_TEST_MYSQL_DATABASE"), User: os.Getenv("DBEER_TEST_MYSQL_USER"), Password: os.Getenv("DBEER_TEST_MYSQL_PASSWORD"), SSLMode: os.Getenv("DBEER_TEST_MYSQL_SSLMODE"), SSLRootCert: os.Getenv("DBEER_TEST_MYSQL_CA_FILE")}
	if c.SSLMode == "" {
		c.SSLMode = "disable"
	}
	m := session.New(mysql.Open)
	defer m.Close()
	exerciseVisualExplain(t, m, c, "mysql")
}
func exerciseVisualExplain(t *testing.T, m *session.Manager, c protocol.Connection, engine string) {
	t.Helper()
	sequence := 0
	id := func() string { sequence++; return "explain-live-" + strconv.Itoa(sequence) }
	send := func(c protocol.Command) {
		if !m.Submit(c) {
			t.Fatal("manager stopped")
		}
	}
	receive := func() protocol.Response {
		select {
		case r := <-m.Responses():
			return r
		case <-time.After(10 * time.Second):
			t.Fatal("response timeout")
			return protocol.Response{}
		}
	}
	send(protocol.Command{Type: "connect", RequestID: id(), Connection: &c})
	connected := receive()
	if connected.Type != "connect.result" || connected.ExplainSupport == nil || len(connected.ExplainSupport.Modes) == 0 {
		t.Fatal("explain support missing")
	}
	sessionID := connected.SessionID
	t.Logf("Visual Explain live engine %s server %s", engine, connected.ExplainSupport.ServerVersion)
	execute := func(sql string) protocol.Response {
		q := id()
		send(protocol.Command{Type: "execute", RequestID: q, SessionID: sessionID, QueryID: q, SQL: sql})
		r := receive()
		if r.Type == "query.started" {
			r = receive()
		}
		if r.Type != "query.result" {
			t.Fatal("fixture statement failed")
		}
		return r
	}
	grant := func(sql, mode string) string {
		q := id()
		send(protocol.Command{Type: "operation.assess", RequestID: q, SessionID: sessionID, QueryID: q, Operations: []protocol.OperationRequest{{Type: "explain.run", Explain: &protocol.ExplainRequest{SQL: sql, Mode: mode}}}})
		r := receive()
		if r.Assessment == nil {
			t.Fatal("assessment failed")
		}
		if mode == "analyze" && r.Assessment.Decision != "confirm" {
			t.Fatal("analyze was not explicitly confirmed")
		}
		if r.Assessment.Operations[0].Explain == nil {
			t.Fatal("prepared wrapper missing")
		}
		return r.Assessment.Authorization
	}
	execute("CREATE TEMPORARY TABLE dbeer_explain_fixture (id integer)")
	execute("INSERT INTO dbeer_explain_fixture VALUES (1), (2)")
	execute("BEGIN")
	execute("INSERT INTO dbeer_explain_fixture VALUES (3)")
	for _, mode := range []string{"plan", "analyze"} {
		sql := "SELECT * FROM dbeer_explain_fixture WHERE id > 0"
		q := id()
		send(protocol.Command{Type: "explain.run", RequestID: q, SessionID: sessionID, QueryID: q, Explain: &protocol.ExplainRequest{SQL: sql, Mode: mode}, Authorization: grant(sql, mode)})
		if r := receive(); r.Type != "query.started" {
			t.Fatal("missing started")
		}
		r := receive()
		if r.Type != "explain.result" || !r.SQLCompleted || r.Explain == nil || !r.Explain.Valid() || r.Explain.Status != "tree" || r.TransactionStatus != "transaction" || len(r.Rows) != 0 || r.Source != nil {
			t.Fatal("same-session plan failed")
		}
		if mode == "analyze" && r.Explain.Nodes[0].Metrics["actualRows"].Value == nil {
			t.Fatal("actual measurements absent")
		}
	}
	if execute("SELECT count(*) FROM dbeer_explain_fixture").Rows[0][0] == nil {
		t.Fatal("working session lost")
	}
	execute("ROLLBACK")
	// An ungranted Analyze is rejected before SQL dispatch even on development.
	q := id()
	send(protocol.Command{Type: "explain.run", RequestID: q, SessionID: sessionID, QueryID: q, Explain: &protocol.ExplainRequest{SQL: "SELECT 1", Mode: "analyze"}})
	if r := receive(); r.Type != "error" || !r.SQLNotExecuted || r.Category != "policy" {
		t.Fatal("ungranted analyze")
	}
	// Stop is out-of-band; the terminal response, rather than acknowledgement,
	// proves cancellation recovery completed before the next statement.
	sql := "SELECT pg_sleep(5)"
	if engine == "mysql" {
		sql = "SELECT SLEEP(5)"
	}
	q = id()
	send(protocol.Command{Type: "explain.run", RequestID: q, SessionID: sessionID, QueryID: q, Explain: &protocol.ExplainRequest{SQL: sql, Mode: "analyze"}, Authorization: grant(sql, "analyze")})
	if r := receive(); r.Type != "query.started" {
		t.Fatal("cancel started")
	}
	time.Sleep(150 * time.Millisecond)
	ack := m.Control(protocol.Command{Type: "cancel", RequestID: id(), SessionID: sessionID, QueryID: q})
	if ack == nil || ack.Status != "accepted" {
		t.Fatal("cancel ack")
	}
	r := receive()
	if r.Type == "error" {
		if r.OutcomeUnknown {
			if r.Connected || r.SQLCompleted || r.SQLNotExecuted {
				t.Fatal("unknown cancellation outcome has contradictory evidence")
			}
			t.Log("Stop recovery closed the physical session; the dispatched SQL outcome remains explicitly unknown and is not retried.")
			return
		}
		if !r.Connected {
			t.Fatal("cancel recovery lost session without outcome evidence")
		}
	} else if r.Type != "explain.result" || !r.SQLCompleted || r.Explain == nil || !r.Explain.Valid() {
		t.Fatal("cancel terminal lacks authoritative completion")
	}
	execute("SELECT 1")

}
