package mysql

import (
	"context"
	"fmt"
	"io"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

func typedText(value string) protocol.CellValue {
	return protocol.CellValue{Kind: "text", Value: text(value)}
}
func typedBinary(value string) protocol.CellValue {
	return protocol.CellValue{Kind: "binary", Value: text(value)}
}
func assign(column string, value protocol.CellValue) protocol.ColumnAssignment {
	return protocol.ColumnAssignment{Column: column, Value: value}
}

func editingRequest(t *testing.T, session *Session, table string) protocol.ChangesRequest {
	t.Helper()
	schema := integrationSettings(t).Database
	metadata := catalogRequest(t, session, protocol.CatalogRequest{Kind: "columns", Schema: schema, Object: table, ObjectKind: "table"})
	request := protocol.ChangesRequest{Schema: schema, Table: table}
	for _, row := range metadata.Rows {
		request.Columns = append(request.Columns, protocol.SnapshotColumn{Name: *row[0], Engine: "mysql", NativeType: *row[1]})
	}
	return request
}

func originalRow(t *testing.T, session *Session, table, where string) []protocol.CellValue {
	t.Helper()
	response := run(t, session, "SELECT * FROM "+QuoteIdentifier(table)+" WHERE "+where)
	if len(response.Rows) != 1 {
		t.Fatal("snapshot row missing")
	}
	values := make([]protocol.CellValue, len(response.Columns))
	for index, column := range response.Columns {
		value := response.Rows[0][index]
		if value == nil {
			values[index] = protocol.CellValue{Kind: "null"}
		} else if column.Encoding == "base64" {
			values[index] = typedBinary(*value)
		} else {
			values[index] = typedText(*value)
		}
	}
	return values
}

func executeChanges(session *Session, request protocol.ChangesRequest, preview bool) protocol.Response {
	kind := "changes.apply"
	if preview {
		kind = "changes.preview"
	}
	return session.Execute(context.Background(), protocol.Command{Type: kind, RequestID: "changes-r", SessionID: "changes-s", QueryID: "changes-q", Changes: &request})
}

func TestMySQLChangesCompositeDefaultsGeneratedAndTypedSnapshot(t *testing.T) {
	reader, writer := integrationSession(t), integrationSession(t)
	table := fmt.Sprintf("dbeer_edit_%x", reader.connectionID)
	quoted := QuoteIdentifier(table)
	t.Cleanup(func() {
		reader.Execute(context.Background(), protocol.Command{RequestID: "cleanup", SQL: "DROP TABLE IF EXISTS " + quoted})
	})
	run(t, reader, "CREATE TABLE "+quoted+" (id INT,part INT,label VARCHAR(80) DEFAULT 'base',nullable VARCHAR(20),bytes VARBINARY(8),quantity DECIMAL(40,20) DEFAULT 1.25,moment DATETIME(3),score FLOAT DEFAULT 0.1,document JSON,computed INT GENERATED ALWAYS AS (id+part) STORED,PRIMARY KEY(id,part)) ENGINE=InnoDB")
	run(t, reader, "INSERT INTO "+quoted+" (id,part,label,bytes,moment,document) VALUES (1,1,'first',X'00FF80','2020-01-02 03:04:05.000',JSON_OBJECT('x',1)),(3,1,'delete',NULL,NULL,NULL)")
	request := editingRequest(t, reader, table)
	request.Changes = []protocol.RowChange{
		{Kind: "update", Original: originalRow(t, reader, table, "id=1 AND part=1"), Values: []protocol.ColumnAssignment{assign("label", typedText("")), assign("nullable", protocol.CellValue{Kind: "null"}), assign("bytes", typedBinary("")), assign("quantity", protocol.CellValue{Kind: "default"})}},
		{Kind: "insert", Values: []protocol.ColumnAssignment{assign("id", typedText("2")), assign("part", typedText("1")), assign("label", protocol.CellValue{Kind: "default"}), assign("nullable", typedText("")), assign("bytes", typedBinary("AP+A")), assign("quantity", typedText("12345678901234567890.12345678901234567890"))}},
		{Kind: "delete", Original: originalRow(t, reader, table, "id=3 AND part=1")},
	}
	preview := executeChanges(writer, request, true)
	if preview.Type != "query.result" || len(preview.Rows) != 3 || !strings.Contains(*preview.Rows[0][1], "DEFAULT") || !strings.Contains(*preview.Rows[0][1], "?") {
		t.Fatal("parameterized preview missing")
	}
	if *run(t, reader, "SELECT label FROM "+quoted+" WHERE id=1").Rows[0][0] != "first" {
		t.Fatal("preview changed data")
	}
	run(t, reader, "BEGIN")
	response := executeChanges(writer, request, false)
	if response.Type != "query.result" || response.RowCount != 3 || response.TransactionStatus != "idle" || reader.TransactionStatus() != "transaction" {
		t.Fatalf("atomic apply failed: category=%s state=%s", response.Category, response.SQLState)
	}
	run(t, reader, "ROLLBACK")
	rows := run(t, reader, "SELECT id,label,nullable,bytes,quantity,computed FROM "+quoted+" ORDER BY id").Rows
	if len(rows) != 2 || *rows[0][1] != "" || rows[0][2] != nil || *rows[0][3] != "" || *rows[1][1] != "base" || *rows[1][2] != "" || *rows[1][3] != "AP+A" || *rows[1][4] != "12345678901234567890.12345678901234567890" || *rows[1][5] != "3" {
		t.Fatal("typed/default values changed")
	}
	request = editingRequest(t, reader, table)
	request.Changes = []protocol.RowChange{{Kind: "update", Original: originalRow(t, reader, table, "id=1"), Values: []protocol.ColumnAssignment{assign("computed", typedText("9"))}}}
	if response := executeChanges(writer, request, false); response.Category != "validation" || !response.Connected {
		t.Fatal("generated assignment was accepted")
	}
	request.Changes[0].Values = []protocol.ColumnAssignment{assign("document", typedText("{}"))}
	if response := executeChanges(writer, request, false); response.Category != "validation" {
		t.Fatal("unsupported type was editable")
	}
}

func TestMySQLChangesConflictMissingAndConstraintRollback(t *testing.T) {
	reader, writer := integrationSession(t), integrationSession(t)
	table := fmt.Sprintf("dbeer_conflict_%x", reader.connectionID)
	quoted := QuoteIdentifier(table)
	t.Cleanup(func() {
		reader.Execute(context.Background(), protocol.Command{RequestID: "cleanup", SQL: "DROP TABLE IF EXISTS " + quoted})
	})
	run(t, reader, "CREATE TABLE "+quoted+" (id INT PRIMARY KEY,label VARCHAR(40) NOT NULL UNIQUE) ENGINE=InnoDB")
	run(t, reader, "INSERT INTO "+quoted+" VALUES(1,'first'),(2,'second')")
	request := editingRequest(t, reader, table)
	request.Changes = []protocol.RowChange{{Kind: "update", Original: originalRow(t, reader, table, "id=1"), Values: []protocol.ColumnAssignment{assign("label", typedText("changed"))}}, {Kind: "insert", Values: []protocol.ColumnAssignment{assign("id", typedText("2")), assign("label", typedText("duplicate"))}}}
	response := executeChanges(writer, request, false)
	if response.Type != "error" || response.SQLState != "23000" || !response.Connected || response.TransactionStatus != "idle" || *run(t, reader, "SELECT label FROM "+quoted+" WHERE id=1").Rows[0][0] != "first" {
		t.Fatal("constraint failure did not roll back the complete batch")
	}
	request.Changes = request.Changes[:1]
	literal := "safe'); DELETE FROM anything; --"
	request.Changes[0].Values = []protocol.ColumnAssignment{assign("label", typedText(literal))}
	preview := executeChanges(writer, request, true)
	if preview.Type != "query.result" || strings.Contains(*preview.Rows[0][1], literal) || !strings.Contains(*preview.Rows[0][2], literal) {
		t.Fatal("assignment value entered SQL syntax")
	}
	if response = executeChanges(writer, request, false); response.Type != "query.result" || *run(t, reader, "SELECT label FROM "+quoted+" WHERE id=1").Rows[0][0] != literal {
		t.Fatal("parameterized text assignment changed data or SQL syntax")
	}
	request.Changes[0].Original = originalRow(t, reader, table, "id=1")
	request.Changes[0].Values = []protocol.ColumnAssignment{assign("label", typedText("changed"))}
	run(t, reader, "UPDATE "+quoted+" SET label='other client' WHERE id=1")
	if response = executeChanges(writer, request, false); response.Category != "conflict" || !response.Connected {
		t.Fatal("another client's change was not detected")
	}
	request.Changes[0].Kind = "delete"
	request.Changes[0].Values = nil
	run(t, reader, "DELETE FROM "+quoted+" WHERE id=1")
	if response = executeChanges(writer, request, false); response.Category != "conflict" || !response.Connected {
		t.Fatal("missing original row was not detected")
	}
	request.Columns[0].NativeType = "bigint"
	if response = executeChanges(writer, request, false); response.Category != "validation" {
		t.Fatal("changed native type was not detected")
	}
}

func TestMySQLChangesRejectReadOnlyTablesAndActiveSQLTransaction(t *testing.T) {
	session := integrationSession(t)
	for _, fixture := range []struct{ suffix, definition string }{{"nopk", "(id INT) ENGINE=InnoDB"}, {"myisam", "(id INT PRIMARY KEY) ENGINE=MyISAM"}} {
		table := fmt.Sprintf("dbeer_readonly_edit_%x_%s", session.connectionID, fixture.suffix)
		run(t, session, "CREATE TABLE "+QuoteIdentifier(table)+" "+fixture.definition)
		request := editingRequest(t, session, table)
		request.Changes = []protocol.RowChange{{Kind: "insert", Values: []protocol.ColumnAssignment{assign("id", typedText("1"))}}}
		response := executeChanges(session, request, false)
		if response.Category != "validation" || !response.Connected || *run(t, session, "SELECT COUNT(*) FROM "+QuoteIdentifier(table)).Rows[0][0] != "0" {
			t.Fatal("read-only table accepted changes")
		}
		run(t, session, "DROP TABLE "+QuoteIdentifier(table))
	}
	request := protocol.ChangesRequest{Schema: integrationSettings(t).Database, Table: "unused", Columns: []protocol.SnapshotColumn{{Name: "id", Engine: "mysql", NativeType: "int"}}, Changes: []protocol.RowChange{{Kind: "insert"}}}
	run(t, session, "BEGIN")
	response := executeChanges(session, request, false)
	if response.Category != "validation" || session.TransactionStatus() != "transaction" {
		t.Fatal("Apply disturbed a SQL tab transaction")
	}
	run(t, session, "ROLLBACK")
}

func TestMySQLChangesDeadlockRollsBackOneCompleteBatch(t *testing.T) {
	reader, left, right := integrationSession(t), integrationSession(t), integrationSession(t)
	table := fmt.Sprintf("dbeer_deadlock_%x", reader.connectionID)
	quoted := QuoteIdentifier(table)
	t.Cleanup(func() {
		reader.Execute(context.Background(), protocol.Command{RequestID: "cleanup", SQL: "DROP TABLE IF EXISTS " + quoted})
	})
	run(t, reader, "CREATE TABLE "+quoted+" (id INT PRIMARY KEY,label VARCHAR(20)) ENGINE=InnoDB")
	run(t, reader, "INSERT INTO "+quoted+" VALUES(1,'old'),(2,'old')")
	base := editingRequest(t, reader, table)
	one, two := originalRow(t, reader, table, "id=1"), originalRow(t, reader, table, "id=2")
	a, b := base, base
	a.Changes = []protocol.RowChange{{Kind: "update", Original: one, Values: []protocol.ColumnAssignment{assign("label", typedText("left"))}}, {Kind: "update", Original: two, Values: []protocol.ColumnAssignment{assign("label", typedText("left"))}}}
	b.Changes = []protocol.RowChange{{Kind: "update", Original: two, Values: []protocol.ColumnAssignment{assign("label", typedText("right"))}}, {Kind: "update", Original: one, Values: []protocol.ColumnAssignment{assign("label", typedText("right"))}}}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	ready, release := make(chan struct{}, 2), make(chan struct{})
	hook := func(index int) {
		if index == 0 {
			ready <- struct{}{}
			select {
			case <-release:
			case <-ctx.Done():
			}
		}
	}
	left.afterRowLock, right.afterRowLock = hook, hook
	results := make(chan protocol.Response, 2)
	for _, task := range []struct {
		session *Session
		request protocol.ChangesRequest
	}{{left, a}, {right, b}} {
		go func(session *Session, request protocol.ChangesRequest) {
			results <- session.ExecuteChanges(ctx, protocol.Command{Type: "changes.apply", RequestID: "deadlock", Changes: &request})
		}(task.session, task.request)
	}
	for range 2 {
		select {
		case <-ready:
		case <-ctx.Done():
			t.Fatal("deadlock lock barrier stalled")
		}
	}
	close(release)
	success, failure := 0, 0
	for range 2 {
		select {
		case response := <-results:
			if response.Type == "query.result" {
				success++
			} else if response.SQLState == "40001" && response.Connected && !response.OutcomeUnknown {
				failure++
			} else {
				t.Fatalf("unexpected deadlock outcome: %s/%s", response.Category, response.SQLState)
			}
		case <-ctx.Done():
			t.Fatal("deadlock did not resolve")
		}
	}
	if success != 1 || failure != 1 {
		t.Fatal("deadlock did not roll back one entire batch")
	}
	rows := run(t, reader, "SELECT label FROM "+quoted+" ORDER BY id").Rows
	if *rows[0][0] != *rows[1][0] || *rows[0][0] == "old" {
		t.Fatal("deadlock left a partial batch")
	}
}

func TestMySQLChangesLostCommitAckIsUnknownAndNeverRepeated(t *testing.T) {
	reader, writer := integrationSession(t), integrationSession(t)
	table := fmt.Sprintf("dbeer_commit_%x", reader.connectionID)
	quoted := QuoteIdentifier(table)
	t.Cleanup(func() {
		reader.Execute(context.Background(), protocol.Command{RequestID: "cleanup", SQL: "DROP TABLE IF EXISTS " + quoted})
	})
	run(t, reader, "CREATE TABLE "+quoted+" (id INT PRIMARY KEY,label VARCHAR(20)) ENGINE=InnoDB")
	run(t, reader, "INSERT INTO "+quoted+" VALUES(1,'old')")
	request := editingRequest(t, reader, table)
	request.Changes = []protocol.RowChange{{Kind: "update", Original: originalRow(t, reader, table, "id=1"), Values: []protocol.ColumnAssignment{assign("label", typedText("committed"))}}}
	var attempts atomic.Int32
	writer.commitOverride = func(commit func() error) error {
		attempts.Add(1)
		if err := commit(); err != nil {
			return err
		}
		return io.EOF
	}
	response := executeChanges(writer, request, false)
	if response.Connected || !response.OutcomeUnknown || attempts.Load() != 1 || *run(t, reader, "SELECT label FROM "+quoted).Rows[0][0] != "committed" {
		t.Fatal("lost COMMIT confirmation was not treated as unknown")
	}
	response = executeChanges(writer, request, false)
	if !response.OutcomeUnknown || attempts.Load() != 1 {
		t.Fatal("unknown Apply was automatically repeated")
	}
}

func TestMySQLChangesCancellationRollsBackBeforeReturning(t *testing.T) {
	reader, writer := integrationSession(t), integrationSession(t)
	table := fmt.Sprintf("dbeer_cancel_edit_%x", reader.connectionID)
	quoted := QuoteIdentifier(table)
	t.Cleanup(func() {
		reader.Execute(context.Background(), protocol.Command{RequestID: "cleanup", SQL: "ROLLBACK"})
		reader.Execute(context.Background(), protocol.Command{RequestID: "cleanup", SQL: "DROP TABLE IF EXISTS " + quoted})
	})
	run(t, reader, "CREATE TABLE "+quoted+" (id INT PRIMARY KEY,label VARCHAR(20)) ENGINE=InnoDB")
	run(t, reader, "INSERT INTO "+quoted+" VALUES(1,'old')")
	request := editingRequest(t, reader, table)
	request.Changes = []protocol.RowChange{{Kind: "update", Original: originalRow(t, reader, table, "id=1"), Values: []protocol.ColumnAssignment{assign("label", typedText("changed"))}}}
	run(t, reader, "BEGIN")
	run(t, reader, "SELECT * FROM "+quoted+" FOR UPDATE")
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	response := writer.ExecuteChanges(ctx, protocol.Command{Type: "changes.apply", RequestID: "cancel", Changes: &request})
	if response.Category != "timeout" || !response.Connected || response.OutcomeUnknown || response.TransactionStatus != "idle" {
		t.Fatal("cancelled Apply did not confirm complete rollback")
	}
	run(t, reader, "ROLLBACK")
	if *run(t, reader, "SELECT label FROM "+quoted).Rows[0][0] != "old" {
		t.Fatal("cancelled Apply changed data")
	}
}
