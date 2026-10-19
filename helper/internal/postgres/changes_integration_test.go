package postgres

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

var changeFixtureSequence atomic.Uint64

type changeFixture struct {
	t        *testing.T
	conn     *pgx.Conn
	observer *pgx.Conn
	settings protocol.Connection
	schema   string
}

func newChangeFixture(t *testing.T) *changeFixture {
	t.Helper()
	dsn := os.Getenv("DBEER_TEST_DSN")
	if dsn == "" {
		if os.Getenv("DBEER_REQUIRE_POSTGRES") == "1" {
			t.Fatal("PostgreSQL changes checks require a disposable DBEER_TEST_DSN")
		}
		t.Skip("DBEER_TEST_DSN is not configured")
	}
	cleanEnvironment(t)
	config, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal("invalid PostgreSQL changes test configuration")
	}
	mode, ca := "disable", ""
	if parsed, err := url.Parse(dsn); err == nil {
		if value := parsed.Query().Get("sslmode"); value != "" {
			mode = value
		}
		ca = parsed.Query().Get("sslrootcert")
	}
	settings := protocol.Connection{Host: config.Host, Port: int(config.Port), Database: config.Database,
		User: config.User, Password: config.Password, SSLMode: mode, SSLRootCert: ca}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := connect(ctx, settings)
	if err != nil {
		t.Fatal("cannot connect PostgreSQL changes session")
	}
	observer, err := connect(ctx, settings)
	if err != nil {
		closeConnection(conn)
		t.Fatal("cannot connect PostgreSQL changes observer")
	}
	fixture := &changeFixture{t: t, conn: conn, observer: observer, settings: settings,
		schema: fmt.Sprintf("dbeer_changes_%d_%d", time.Now().UnixNano(), changeFixtureSequence.Add(1))}
	fixture.exec("CREATE SCHEMA " + pgx.Identifier{fixture.schema}.Sanitize())
	t.Cleanup(func() {
		closeConnection(conn)
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, _ = observer.Exec(ctx, "ROLLBACK")
		_, _ = observer.Exec(ctx, "DROP SCHEMA "+pgx.Identifier{fixture.schema}.Sanitize()+" CASCADE")
		closeConnection(observer)
	})
	return fixture
}

func (fixture *changeFixture) table(name string) string {
	return pgx.Identifier{fixture.schema, name}.Sanitize()
}

func (fixture *changeFixture) exec(sql string) {
	fixture.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := fixture.observer.Exec(ctx, sql); err != nil {
		var server *pgconn.PgError
		if errors.As(err, &server) {
			fixture.t.Fatal("PostgreSQL changes fixture setup failed (SQLSTATE " + server.Code + ")")
		}
		fixture.t.Fatal("PostgreSQL changes fixture setup failed")
	}
}

func (fixture *changeFixture) request(table string, changes ...protocol.RowChange) protocol.ChangesRequest {
	fixture.t.Helper()
	rows, err := fixture.observer.Query(context.Background(), `SELECT a.attname::text,pg_catalog.format_type(a.atttypid,a.atttypmod)
FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_class c ON c.oid=a.attrelid JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname=$1 AND c.relname=$2 AND a.attnum>0 AND NOT a.attisdropped ORDER BY a.attnum`, fixture.schema, table)
	if err != nil {
		fixture.t.Fatal("cannot read changes fixture metadata")
	}
	defer rows.Close()
	request := protocol.ChangesRequest{Schema: fixture.schema, Table: table, Changes: changes}
	for rows.Next() {
		var name, nativeType string
		if rows.Scan(&name, &nativeType) != nil {
			fixture.t.Fatal("cannot decode changes fixture metadata")
		}
		request.Columns = append(request.Columns, protocol.SnapshotColumn{Name: name, Engine: "postgresql", NativeType: nativeType})
	}
	if rows.Err() != nil {
		fixture.t.Fatal("cannot finish reading changes fixture metadata")
	}
	return request
}

func (fixture *changeFixture) snapshot(table, predicate string) []protocol.CellValue {
	fixture.t.Helper()
	response := execute(context.Background(), fixture.observer, protocol.Command{Type: "execute", RequestID: "snapshot", SessionID: "fixture", QueryID: "snapshot",
		SQL: "SELECT * FROM " + fixture.table(table) + " WHERE " + predicate})
	if response.Type != "query.result" || len(response.Rows) != 1 {
		fixture.t.Fatal("cannot read a unique changes fixture snapshot")
	}
	values := make([]protocol.CellValue, len(response.Columns))
	for index, value := range response.Rows[0] {
		values[index].Kind = "null"
		if value != nil {
			values[index].Kind, values[index].Value = "text", value
			if response.Columns[index].Encoding == "base64" {
				values[index].Kind = "binary"
			}
		}
	}
	return values
}

func (fixture *changeFixture) apply(request protocol.ChangesRequest) protocol.Response {
	fixture.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return changes(ctx, fixture.conn, protocol.Command{Type: "changes.apply", RequestID: "changes", SessionID: "fixture", QueryID: "apply", Changes: &request})
}

func (fixture *changeFixture) scalar(sql string) string {
	fixture.t.Helper()
	var value string
	if fixture.observer.QueryRow(context.Background(), sql).Scan(&value) != nil {
		fixture.t.Fatal("cannot inspect changes fixture outcome")
	}
	return value
}

func changeText(value string) protocol.CellValue {
	return protocol.CellValue{Kind: "text", Value: &value}
}
func changeBinary(value string) protocol.CellValue {
	return protocol.CellValue{Kind: "binary", Value: &value}
}
func changeAssign(column string, value protocol.CellValue) protocol.ColumnAssignment {
	return protocol.ColumnAssignment{Column: column, Value: value}
}

func TestChangesCompositePrimaryKeyDefaultsGeneratedBinaryNullAndExactNumeric(t *testing.T) {
	fixture := newChangeFixture(t)
	table := fixture.table("values")
	fixture.exec(`CREATE TABLE ` + table + ` (
 tenant integer,id integer,value text NOT NULL DEFAULT 'server',optional text,bytes bytea,
 amount numeric(30,19) NOT NULL DEFAULT 1.1234567890123456789,version integer NOT NULL DEFAULT 7,
 total integer GENERATED ALWAYS AS(id+version) STORED,PRIMARY KEY(tenant,id))`)
	fixture.exec(`INSERT INTO ` + table + `(tenant,id,value,bytes,amount,version) VALUES (1,1,'before',decode('00ff','hex'),9.0000000000000000001,3),(2,1,'delete',NULL,2,4)`)
	first := fixture.snapshot("values", "tenant=1 AND id=1")
	deleted := fixture.snapshot("values", "tenant=2 AND id=1")
	precise := "90071992547.1234567890123456789"
	request := fixture.request("values",
		protocol.RowChange{Kind: "update", Original: first, Values: []protocol.ColumnAssignment{
			changeAssign("value", changeText("")), changeAssign("optional", changeText("NULL")),
			changeAssign("bytes", changeBinary("AAH/")), changeAssign("amount", changeText(precise)),
			changeAssign("version", protocol.CellValue{Kind: "default"})}},
		protocol.RowChange{Kind: "insert", Values: []protocol.ColumnAssignment{
			changeAssign("tenant", changeText("1")), changeAssign("id", changeText("2")),
			changeAssign("value", protocol.CellValue{Kind: "default"}), changeAssign("optional", protocol.CellValue{Kind: "null"}),
			changeAssign("bytes", changeBinary(""))}},
		protocol.RowChange{Kind: "delete", Original: deleted})
	preview := changes(context.Background(), fixture.conn, protocol.Command{Type: "changes.preview", RequestID: "preview", SessionID: "fixture", QueryID: "preview", Changes: &request})
	if preview.Type != "query.result" || len(preview.Rows) != 3 || strings.Contains(*preview.Rows[0][1], precise) || !strings.Contains(*preview.Rows[0][2], precise) {
		t.Fatal("preview must show parameterized SQL and exact typed bindings for every change")
	}
	if fixture.scalar("SELECT count(*)::text FROM "+table) != "2" {
		t.Fatal("preview must not mutate rows")
	}
	fixture.exec("BEGIN")
	response := fixture.apply(request)
	if response.Type != "query.result" || response.CommandTag != "APPLY 3" || response.RowCount != 3 || transactionStatus(fixture.conn) != "idle" {
		t.Fatal("the entire composite-key batch must apply in one separate transaction")
	}
	if transactionStatus(fixture.observer) != "transaction" {
		t.Fatal("Apply must not finish the data-view session's transaction")
	}
	fixture.exec("ROLLBACK")
	updated := fixture.snapshot("values", "tenant=1 AND id=1")
	inserted := fixture.snapshot("values", "tenant=1 AND id=2")
	if !sameChangeCell(updated[2], changeText("")) || !sameChangeCell(updated[3], changeText("NULL")) ||
		!sameChangeCell(updated[4], changeBinary("AAH/")) || !sameChangeCell(updated[5], changeText(precise)) ||
		!sameChangeCell(updated[6], changeText("7")) || !sameChangeCell(updated[7], changeText("8")) {
		t.Fatal("Apply must preserve exact numbers, binary, empty text and server-generated values")
	}
	if !sameChangeCell(inserted[2], changeText("server")) || inserted[3].Kind != "null" ||
		!sameChangeCell(inserted[4], changeBinary("")) || !sameChangeCell(inserted[7], changeText("9")) ||
		fixture.scalar("SELECT count(*)::text FROM "+table+" WHERE tenant=2") != "0" {
		t.Fatal("INSERT defaults, generated columns and DELETE must retain their server semantics")
	}
}

func TestChangesConflictAndMissingRowRollBackEarlierOperations(t *testing.T) {
	fixture := newChangeFixture(t)
	table := fixture.table("conflict")
	fixture.exec("CREATE TABLE " + table + " (id integer PRIMARY KEY,value text)")
	fixture.exec("INSERT INTO " + table + " VALUES (1,'original')")
	original := fixture.snapshot("conflict", "id=1")
	request := fixture.request("conflict", protocol.RowChange{Kind: "insert", Values: []protocol.ColumnAssignment{
		changeAssign("id", changeText("2")), changeAssign("value", changeText("must roll back"))}},
		protocol.RowChange{Kind: "update", Original: original, Values: []protocol.ColumnAssignment{changeAssign("value", changeText("local"))}})
	fixture.exec("UPDATE " + table + " SET value='another client' WHERE id=1")
	response := fixture.apply(request)
	if response.Category != "conflict" || !response.Connected || response.OutcomeUnknown || response.TransactionStatus != "idle" ||
		fixture.scalar("SELECT count(*)::text FROM "+table+" WHERE id=2") != "0" || fixture.scalar("SELECT value FROM "+table+" WHERE id=1") != "another client" {
		t.Fatal("a concurrent update must roll back the whole batch and preserve the other client's row")
	}
	fixture.exec("DELETE FROM " + table + " WHERE id=1")
	response = fixture.apply(request)
	if response.Category != "conflict" || fixture.scalar("SELECT count(*)::text FROM "+table) != "0" {
		t.Fatal("a disappeared row must roll back all earlier changes")
	}
}

func TestChangesConstraintFailureGeneratedColumnsAndReadOnlyReasons(t *testing.T) {
	fixture := newChangeFixture(t)
	table := fixture.table("checked")
	fixture.exec("CREATE TABLE " + table + " (id integer PRIMARY KEY,n integer CHECK(n>0),generated integer GENERATED ALWAYS AS(n+1) STORED)")
	fixture.exec("INSERT INTO " + table + "(id,n) VALUES (1,1)")
	original := fixture.snapshot("checked", "id=1")
	request := fixture.request("checked", protocol.RowChange{Kind: "insert", Values: []protocol.ColumnAssignment{changeAssign("id", changeText("2")), changeAssign("n", changeText("2"))}},
		protocol.RowChange{Kind: "update", Original: original, Values: []protocol.ColumnAssignment{changeAssign("n", changeText("-1"))}})
	response := fixture.apply(request)
	if response.Category != "sql" || response.SQLState != "23514" || response.OutcomeUnknown || !response.Connected || response.TransactionStatus != "idle" ||
		fixture.scalar("SELECT count(*)::text FROM "+table) != "1" || fixture.scalar("SELECT n::text FROM "+table+" WHERE id=1") != "1" {
		t.Fatal("a constraint failure must roll back every row and leave the Apply session idle")
	}
	request.Changes = []protocol.RowChange{{Kind: "update", Original: original, Values: []protocol.ColumnAssignment{changeAssign("generated", changeText("100"))}}}
	if response = fixture.apply(request); response.Category != "validation" || !response.Connected {
		t.Fatal("generated columns must remain read only")
	}
	fixture.exec("CREATE TABLE " + fixture.table("unsupported") + " (id integer PRIMARY KEY,items integer[])")
	unsupported := fixture.request("unsupported", protocol.RowChange{Kind: "insert", Values: []protocol.ColumnAssignment{changeAssign("id", changeText("1"))}})
	if response = fixture.apply(unsupported); response.Category != "validation" || !strings.Contains(response.Message, "unsupported type") {
		t.Fatal("a table containing an unsupported type must explain why editing is unavailable")
	}
	catalog := catalog(context.Background(), fixture.conn, protocol.Command{Type: "catalog", RequestID: "metadata", SessionID: "fixture", QueryID: "metadata",
		Catalog: &protocol.CatalogRequest{Kind: "columns", Schema: fixture.schema, Object: "unsupported", ObjectKind: "table"}})
	if catalog.Type != "query.result" || len(catalog.Rows) != 2 {
		t.Fatal("unsupported table metadata must remain available")
	}
	for _, row := range catalog.Rows {
		if row[6] == nil || *row[6] != "false" || row[7] == nil || !strings.Contains(*row[7], "unsupported type") {
			t.Fatal("catalog editing reasons must agree with the Apply adapter")
		}
	}
	fixture.exec("CREATE TABLE " + fixture.table("no_key") + " (id integer)")
	noKey := fixture.request("no_key", protocol.RowChange{Kind: "insert", Values: []protocol.ColumnAssignment{changeAssign("id", changeText("1"))}})
	if response = fixture.apply(noKey); response.Category != "validation" || !strings.Contains(response.Message, "primary key") {
		t.Fatal("tables without a primary key must remain read only")
	}
	if _, err := fixture.conn.Exec(context.Background(), "BEGIN"); err != nil {
		t.Fatal("cannot start unrelated SQL transaction")
	}
	if response = fixture.apply(request); response.Category != "validation" || transactionStatus(fixture.conn) != "transaction" {
		t.Fatal("Apply must refuse to borrow or roll back an existing SQL transaction")
	}
}

func TestChangesQuotedIdentifiersAndValuesNeverBecomeSQL(t *testing.T) {
	fixture := newChangeFixture(t)
	name, column := `quoted";table`, `value";column`
	table := fixture.table(name)
	fixture.exec("CREATE TABLE " + table + " (id integer PRIMARY KEY," + pgx.Identifier{column}.Sanitize() + " text)")
	fixture.exec("INSERT INTO " + table + " VALUES (1,'original')")
	original := fixture.snapshot(name, "id=1")
	literal := `'; DROP SCHEMA public CASCADE; -- κόσμος`
	request := fixture.request(name, protocol.RowChange{Kind: "update", Original: original,
		Values: []protocol.ColumnAssignment{changeAssign(column, changeText(literal))}})
	response := fixture.apply(request)
	if response.Type != "query.result" || fixture.scalar("SELECT "+pgx.Identifier{column}.Sanitize()+" FROM "+table) != literal {
		t.Fatal("generated SQL must quote identifiers and bind all data values")
	}
}

func (fixture *changeFixture) watcher() *pgx.Conn {
	fixture.t.Helper()
	conn, err := connect(context.Background(), fixture.settings)
	if err != nil {
		fixture.t.Fatal("cannot connect changes lock observer")
	}
	fixture.t.Cleanup(func() { closeConnection(conn) })
	return conn
}

func waitForChangeLock(t *testing.T, watcher *pgx.Conn, pid uint32) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		var waiting bool
		if watcher.QueryRow(context.Background(), "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE pid=$1 AND wait_event_type='Lock')", int64(pid)).Scan(&waiting) != nil {
			t.Fatal("cannot observe the changes lock boundary")
		}
		if waiting {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("changes did not reach the expected lock boundary")
}

func TestChangesRevalidatesMetadataAfterWaitingForConcurrentDDL(t *testing.T) {
	fixture := newChangeFixture(t)
	table := fixture.table("ddl")
	fixture.exec("CREATE TABLE " + table + " (id integer PRIMARY KEY,value text)")
	fixture.exec("INSERT INTO " + table + " VALUES (1,'original')")
	request := fixture.request("ddl", protocol.RowChange{Kind: "update", Original: fixture.snapshot("ddl", "id=1"),
		Values: []protocol.ColumnAssignment{changeAssign("value", changeText("local"))}})
	fixture.exec("BEGIN")
	fixture.exec("ALTER TABLE " + table + " ADD COLUMN added integer DEFAULT 1")
	watcher := fixture.watcher()
	pid := fixture.conn.PgConn().PID()
	responses := make(chan protocol.Response, 1)
	go func() { responses <- fixture.apply(request) }()
	waitForChangeLock(t, watcher, pid)
	fixture.exec("COMMIT")
	response := <-responses
	if response.Category != "conflict" || response.TransactionStatus != "idle" || fixture.scalar("SELECT value FROM "+table) != "original" {
		t.Fatal("metadata must be revalidated under the Apply transaction's table lock")
	}
}

func TestChangesDeadlockRollsBackTheEntireApplyWithoutRetry(t *testing.T) {
	fixture := newChangeFixture(t)
	table := fixture.table("deadlock")
	fixture.exec("CREATE TABLE " + table + " (id integer PRIMARY KEY,value text)")
	fixture.exec("INSERT INTO " + table + " VALUES (1,'one'),(2,'two')")
	request := fixture.request("deadlock", protocol.RowChange{Kind: "update", Original: fixture.snapshot("deadlock", "id=1"), Values: []protocol.ColumnAssignment{changeAssign("value", changeText("local one"))}},
		protocol.RowChange{Kind: "update", Original: fixture.snapshot("deadlock", "id=2"), Values: []protocol.ColumnAssignment{changeAssign("value", changeText("local two"))}})
	if _, err := fixture.conn.Exec(context.Background(), "SET deadlock_timeout='500ms'"); err != nil {
		t.Fatal("disposable PostgreSQL changes test role needs permission to set deadlock_timeout")
	}
	fixture.exec("SET deadlock_timeout='5s'")
	fixture.exec("BEGIN")
	fixture.exec("SELECT * FROM " + table + " WHERE id=2 FOR UPDATE")
	watcher := fixture.watcher()
	pid := fixture.conn.PgConn().PID()
	responses := make(chan protocol.Response, 1)
	go func() { responses <- fixture.apply(request) }()
	waitForChangeLock(t, watcher, pid)
	otherDone := make(chan error, 1)
	go func() {
		_, err := fixture.observer.Exec(context.Background(), "UPDATE "+table+" SET value='other' WHERE id=1")
		otherDone <- err
	}()
	response := <-responses
	otherErr := <-otherDone
	if response.SQLState != "40P01" || response.OutcomeUnknown || !response.Connected || response.TransactionStatus != "idle" {
		t.Fatal("a deadlock victim must return a known rollback and an idle Apply session")
	}
	if otherErr != nil {
		t.Fatal("the competing transaction did not recover after the Apply rollback")
	}
	fixture.exec("ROLLBACK")
	if fixture.scalar("SELECT value FROM "+table+" WHERE id=1") != "one" || fixture.scalar("SELECT value FROM "+table+" WHERE id=2") != "two" {
		t.Fatal("deadlock handling must not retry or commit an earlier row change")
	}
}

func TestChangesCancellationRollsBackAndRecoversItsConnection(t *testing.T) {
	fixture := newChangeFixture(t)
	table := fixture.table("cancel")
	fixture.exec("CREATE TABLE " + table + " (id integer PRIMARY KEY,value text)")
	fixture.exec("INSERT INTO " + table + " VALUES (1,'original')")
	request := fixture.request("cancel", protocol.RowChange{Kind: "update", Original: fixture.snapshot("cancel", "id=1"), Values: []protocol.ColumnAssignment{changeAssign("value", changeText("local"))}})
	fixture.exec("BEGIN")
	fixture.exec("SELECT * FROM " + table + " WHERE id=1 FOR UPDATE")
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	response := changes(ctx, fixture.conn, protocol.Command{Type: "changes.apply", RequestID: "timeout", SessionID: "fixture", QueryID: "timeout", Changes: &request})
	if response.Category != "timeout" || response.OutcomeUnknown || !response.Connected || response.TransactionStatus != "idle" {
		t.Fatal("a cancelled Apply must recover its session and confirm that no changes were committed")
	}
	fixture.exec("ROLLBACK")
	if fixture.scalar("SELECT value FROM "+table) != "original" {
		t.Fatal("a cancelled Apply must leave all rows unchanged")
	}
	if response = fixture.apply(request); response.Type != "query.result" || fixture.scalar("SELECT value FROM "+table) != "local" {
		t.Fatal("an explicit new Apply must work after cancellation recovery")
	}
}

func TestChangesLostCommitAcknowledgementIsUnknownAndNeverRepeated(t *testing.T) {
	for name, lostAcknowledgement := range map[string]error{
		"transport":         io.ErrUnexpectedEOF,
		"completionUnknown": &pgconn.PgError{Severity: "ERROR", Code: "40003"},
	} {
		t.Run(name, func(t *testing.T) {
			fixture := newChangeFixture(t)
			table := fixture.table("unknown_commit")
			fixture.exec("CREATE TABLE " + table + " (id integer PRIMARY KEY,value text)")
			request := fixture.request("unknown_commit", protocol.RowChange{Kind: "insert", Values: []protocol.ColumnAssignment{changeAssign("id", changeText("1")), changeAssign("value", changeText("committed"))}})
			commits := 0
			response := changesWithCommit(context.Background(), fixture.conn, protocol.Command{Type: "changes.apply", RequestID: "unknown", SessionID: "fixture", QueryID: "unknown", Changes: &request},
				func(ctx context.Context, conn *pgx.Conn) error {
					commits++
					if _, err := conn.Exec(ctx, "COMMIT"); err != nil {
						return err
					}
					return lostAcknowledgement
				})
			if response.Type != "error" || !response.OutcomeUnknown || response.Connected || !fixture.conn.IsClosed() || commits != 1 ||
				fixture.scalar("SELECT count(*)::text FROM "+table) != "1" {
				t.Fatal("a lost COMMIT acknowledgement must close its session, preserve uncertainty and never repeat the transaction")
			}
		})
	}
}

func TestChangesDeferredConstraintFailureAtCommitIsAKnownRollback(t *testing.T) {
	fixture := newChangeFixture(t)
	table := fixture.table("deferred_constraint")
	fixture.exec("CREATE TABLE " + table + " (id integer PRIMARY KEY,value integer UNIQUE DEFERRABLE INITIALLY DEFERRED)")
	request := fixture.request("deferred_constraint",
		protocol.RowChange{Kind: "insert", Values: []protocol.ColumnAssignment{changeAssign("id", changeText("1")), changeAssign("value", changeText("7"))}},
		protocol.RowChange{Kind: "insert", Values: []protocol.ColumnAssignment{changeAssign("id", changeText("2")), changeAssign("value", changeText("7"))}})
	response := fixture.apply(request)
	if response.Type != "error" || response.SQLState != "23505" || response.OutcomeUnknown || !response.Connected ||
		response.TransactionStatus != "idle" || fixture.scalar("SELECT count(*)::text FROM "+table) != "0" {
		t.Fatal("a definitive deferred constraint error at COMMIT must preserve a known rollback and reusable idle session")
	}
}

func TestChangesGeneratedOnlyColumnsAllowDefaultInsertAndDeleteWithIncludedPrimaryKeyColumns(t *testing.T) {
	fixture := newChangeFixture(t)
	table := fixture.table("generated_only")
	fixture.exec("CREATE TABLE " + table + " (id integer GENERATED ALWAYS AS IDENTITY,computed integer GENERATED ALWAYS AS (id*2) STORED,PRIMARY KEY (id) INCLUDE (computed))")
	request := fixture.request("generated_only", protocol.RowChange{Kind: "insert", Values: []protocol.ColumnAssignment{}})
	if response := fixture.apply(request); response.Type != "query.result" || response.RowCount != 1 {
		t.Fatal("a table containing only generated columns must permit INSERT DEFAULT VALUES")
	}
	response := catalog(context.Background(), fixture.observer, protocol.Command{Type: "catalog", RequestID: "generated_catalog", Catalog: &protocol.CatalogRequest{Kind: "columns", Schema: fixture.schema, Object: "generated_only"}})
	if response.Type != "query.result" || len(response.Rows) != 2 || *response.Rows[0][5] != "1" || *response.Rows[1][5] != "0" {
		t.Fatal("primary key INCLUDE columns must not become key components")
	}
	request = fixture.request("generated_only", protocol.RowChange{Kind: "delete", Original: fixture.snapshot("generated_only", "id=1")})
	if response := fixture.apply(request); response.Type != "query.result" || fixture.scalar("SELECT count(*)::text FROM "+table) != "0" {
		t.Fatal("a generated primary key must still identify a row for safe deletion")
	}
}

func TestChangesTypedCellsAndBindEncodingPreserveNullEmptyAndBinary(t *testing.T) {
	if sameChangeCell(protocol.CellValue{Kind: "null"}, changeText("")) || sameChangeCell(changeBinary("AA=="), changeText("AA==")) ||
		!sameChangeCell(changeBinary("AA=="), changeBinary("AA==\n")) || sameChangeCell(changeText("9007199254740993"), changeText("9007199254740992")) {
		t.Fatal("typed snapshots must distinguish SQL NULL, empty text, binary and exact numeric text")
	}
	parameters, err := changeParameters([]protocol.CellValue{{Kind: "null"}, changeText(""), changeBinary(base64.StdEncoding.EncodeToString([]byte{0, 1, 255}))})
	if err != nil || parameters[0] != nil || parameters[1] == nil || len(parameters[1]) != 0 || string(parameters[2]) != "\\x0001ff" {
		t.Fatal("bound parameters must preserve null, empty text and binary bytes")
	}
}
