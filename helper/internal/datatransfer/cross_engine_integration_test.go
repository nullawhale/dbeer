package datatransfer_test

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"strconv"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	dt "dbeer/helper/internal/datatransfer"
	"dbeer/helper/internal/mysql"
	"dbeer/helper/internal/postgres"
	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
)

func crossConnections(t *testing.T) (protocol.Connection, protocol.Connection) {
	t.Helper()
	dsn := os.Getenv("DBEER_TEST_DSN")
	port, err := strconv.Atoi(os.Getenv("DBEER_TEST_MYSQL_PORT"))
	if dsn == "" || err != nil {
		t.Skip("cross-engine transfer requires both disposable PostgreSQL and MySQL fixtures")
	}
	config, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal("invalid disposable PostgreSQL fixture")
	}
	mode := "disable"
	if parsed, e := url.Parse(dsn); e == nil && parsed.Query().Get("sslmode") != "" {
		mode = parsed.Query().Get("sslmode")
	}
	pg := protocol.Connection{Engine: "postgresql", Host: config.Host, Port: int(config.Port), Database: config.Database, User: config.User, Password: config.Password, SSLMode: mode}
	my := protocol.Connection{Engine: "mysql", Host: os.Getenv("DBEER_TEST_MYSQL_HOST"), Port: port, Database: os.Getenv("DBEER_TEST_MYSQL_DATABASE"), User: os.Getenv("DBEER_TEST_MYSQL_USER"), Password: os.Getenv("DBEER_TEST_MYSQL_PASSWORD"), SSLMode: "disable"}
	if my.Host == "" {
		my.Host = "localhost"
	}
	return pg, my
}
func crossOpen(ctx context.Context, c protocol.Connection) (adapter.Session, error) {
	if c.DatabaseEngine() == "mysql" {
		return mysql.Open(ctx, c)
	}
	return postgres.Open(ctx, c)
}
func execute(t *testing.T, s adapter.Session, sql string) protocol.Response {
	t.Helper()
	r := s.Execute(context.Background(), protocol.Command{Type: "execute", SQL: sql})
	if r.Type != "query.result" {
		t.Fatalf("disposable transfer fixture statement failed: category=%s SQLSTATE=%s", r.Category, r.SQLState)
	}
	return r
}
func wait(t *testing.T, m *dt.Manager, id string) protocol.TransferReply {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		r := m.Handle(protocol.Command{Type: "transfer.status", RequestID: "status", Transfer: &protocol.TransferRequest{JobID: id}})
		if r.Transfer == nil {
			t.Fatal("live transfer job disappeared")
		}
		if r.Transfer.State != "pending" && r.Transfer.State != "running" {
			return *r.Transfer
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("live transfer job timed out")
	return protocol.TransferReply{}
}
func TestTransferCrossEngineImmutableTypedTableCopy(t *testing.T) {
	pg, my := crossConnections(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	pgSession, err := crossOpen(ctx, pg)
	if err != nil {
		t.Fatal("cannot open PostgreSQL fixture")
	}
	defer pgSession.Close()
	mySession, err := crossOpen(ctx, my)
	if err != nil {
		t.Fatal("cannot open MySQL fixture")
	}
	defer mySession.Close()
	suffix := fmt.Sprint(time.Now().UnixNano())
	schema := "dbeer_transfer_" + suffix
	mySource := "xfer_source_" + suffix
	myTarget := "xfer_target_" + suffix
	execute(t, pgSession, "CREATE SCHEMA "+pgx.Identifier{schema}.Sanitize())
	defer execute(t, pgSession, "DROP SCHEMA "+pgx.Identifier{schema}.Sanitize()+" CASCADE")
	defer execute(t, mySession, "DROP TABLE IF EXISTS "+mysql.QuoteIdentifier(mySource))
	defer execute(t, mySession, "DROP TABLE IF EXISTS "+mysql.QuoteIdentifier(myTarget))
	jsonText := ` { "n": 9007199254740993.1234567890001, "label": "exact" } `
	name := pgx.Identifier{schema, "source"}.Sanitize()
	execute(t, pgSession, "CREATE TABLE "+name+" (id bigint,amount numeric(30,10),payload bytea,note text,doc json)")
	execute(t, pgSession, "INSERT INTO "+name+" VALUES (9007199254740993,9007199254740993.1234567890,decode('00ff','hex'),'NULL',"+"'"+jsonText+"'::json),(NULL,NULL,NULL,'',NULL)")
	execute(t, mySession, "CREATE TABLE "+mysql.QuoteIdentifier(mySource)+" (id BIGINT UNSIGNED,note LONGTEXT,created TIMESTAMP(6),payload LONGBLOB) ENGINE=InnoDB")
	execute(t, mySession, "INSERT INTO "+mysql.QuoteIdentifier(mySource)+" VALUES (18446744073709551615,'NULL','2026-01-01 12:00:00.123456',X'00FF'),(NULL,'',NULL,NULL)")
	m, err := dt.New(crossOpen, dt.Options{Root: t.TempDir()})
	if err != nil {
		t.Fatal("cannot create live transfer manager")
	}
	defer m.Close()
	copyTable := func(source, target protocol.TransferEndpoint) protocol.TransferReply {
		t.Helper()
		describe := protocol.TransferRequest{Mode: "table", Source: &source, Target: &target}
		r := m.Handle(protocol.Command{Type: "transfer.describe", RequestID: "describe", Transfer: &describe})
		if r.Transfer == nil {
			t.Fatal("live descriptor request rejected")
		}
		described := wait(t, m, r.Transfer.JobID)
		if described.State != "described" {
			t.Fatalf("live descriptor failed: code=%s", described.Code)
		}
		m.Handle(protocol.Command{Type: "transfer.close", RequestID: "close-description", Transfer: &protocol.TransferRequest{JobID: described.JobID}})
		preview := describe
		preview.Columns = described.Columns
		preview.SourceDigest = described.SourceDigest
		r = m.Handle(protocol.Command{Type: "transfer.preview", RequestID: "preview", Transfer: &preview})
		if r.Transfer == nil {
			t.Fatal("live preview request rejected")
		}
		ready := wait(t, m, r.Transfer.JobID)
		if ready.State != "ready" || ready.RowsRead != 2 || ready.PlanDigest == "" {
			t.Fatalf("live immutable preview failed: state=%s code=%s diagnostics=%d", ready.State, ready.Code, len(ready.Diagnostics))
		}
		if source.Connection.DatabaseEngine() == "postgresql" {
			execute(t, pgSession, "UPDATE "+pgx.Identifier{source.Schema, source.Table}.Sanitize()+" SET note='changed after preview'")
		} else {
			execute(t, mySession, "UPDATE "+mysql.QuoteIdentifier(source.Schema)+"."+mysql.QuoteIdentifier(source.Table)+" SET note='changed after preview'")
		}
		m.Handle(protocol.Command{Type: "transfer.apply", RequestID: "apply", Transfer: &protocol.TransferRequest{JobID: ready.JobID, PlanDigest: ready.PlanDigest, Confirmed: true}})
		done := wait(t, m, ready.JobID)
		if done.State != "completed" || done.RowsWritten != 2 || !done.TableCreated || done.OutcomeUnknown {
			t.Fatalf("live copy failed: state=%s code=%s", done.State, done.Code)
		}
		m.Handle(protocol.Command{Type: "transfer.close", RequestID: "close", Transfer: &protocol.TransferRequest{JobID: done.JobID}})
		return done
	}
	copyTable(protocol.TransferEndpoint{Connection: pg, Schema: schema, Table: "source"}, protocol.TransferEndpoint{Connection: my, Schema: my.Database, Table: myTarget})
	result := execute(t, mySession, "SELECT CAST(id AS CHAR),CAST(amount AS CHAR),HEX(payload),note,doc FROM "+mysql.QuoteIdentifier(myTarget)+" WHERE id IS NOT NULL")
	if len(result.Rows) != 1 || result.Rows[0][0] == nil || *result.Rows[0][0] != "9007199254740993" || *result.Rows[0][1] != "9007199254740993.1234567890" || *result.Rows[0][2] != "00FF" || *result.Rows[0][3] != "NULL" || *result.Rows[0][4] != jsonText {
		t.Fatal("PostgreSQL to MySQL changed typed values or JSON spelling")
	}
	copyTable(protocol.TransferEndpoint{Connection: my, Schema: my.Database, Table: mySource}, protocol.TransferEndpoint{Connection: pg, Schema: schema, Table: "from_mysql"})
	result = execute(t, pgSession, "SELECT id::text,note,to_char(created AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI:SS.US'),encode(payload,'hex') FROM "+pgx.Identifier{schema, "from_mysql"}.Sanitize()+" WHERE id IS NOT NULL")
	if len(result.Rows) != 1 || *result.Rows[0][0] != "18446744073709551615" || *result.Rows[0][1] != "NULL" || *result.Rows[0][2] != "2026-01-01 12:00:00.123456" || *result.Rows[0][3] != "00ff" {
		t.Fatal("MySQL to PostgreSQL changed unsigned integer, UTC timestamp or binary data")
	}
}
