package mysql

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"sync/atomic"
	"testing"

	"dbeer/helper/internal/protocol"
)

// Reconstruct Apply's canonical full original from query order. The native
// client uses the same server-supplied tableIndex mapping, not display labels.
func mysqlQueryChanges(t *testing.T, result protocol.Response, assignments ...protocol.ColumnAssignment) protocol.ChangesRequest {
	t.Helper()
	source := result.Source
	if source == nil || source.ReadOnlyReason != "" || len(result.Rows) != 1 || len(source.Columns) != len(result.Columns) {
		t.Fatal("editable query provenance missing")
	}
	request := protocol.ChangesRequest{Schema: source.Schema, Table: source.Table, Columns: make([]protocol.SnapshotColumn, len(source.Columns))}
	original := make([]protocol.CellValue, len(source.Columns))
	for index, column := range source.Columns {
		request.Columns[column.TableIndex] = protocol.SnapshotColumn{Name: column.Name, Engine: "mysql", NativeType: column.NativeType}
		cell := protocol.CellValue{Kind: "null"}
		if value := result.Rows[0][index]; value != nil {
			cell = protocol.CellValue{Kind: "text", Value: value}
			if result.Columns[index].Encoding == "base64" {
				cell.Kind = "binary"
			}
		}
		original[column.TableIndex] = cell
	}
	request.Changes = []protocol.RowChange{{Kind: "update", Original: original, Values: assignments}}
	return request
}

func TestMySQLResultSourceAliasedReorderedExactApplyAndConflict(t *testing.T) {
	reader, writer := integrationSession(t), integrationSession(t)
	name := fmt.Sprintf("dbeer_query_source_%x", reader.connectionID)
	quoted := QuoteIdentifier(name)
	run(t, reader, "CREATE TABLE "+quoted+"(id VARBINARY(8),part BIGINT UNSIGNED,label VARCHAR(40),amount DECIMAL(40,20),nullable VARCHAR(20),computed BIGINT UNSIGNED GENERATED ALWAYS AS (part-1) STORED,PRIMARY KEY(id,part)) ENGINE=InnoDB")
	t.Cleanup(func() { run(t, reader, "DROP TABLE IF EXISTS "+quoted) })
	run(t, reader, "INSERT INTO "+quoted+"(id,part,label,amount,nullable) VALUES(X'00FF80',18446744073709551615,'NULL',12345678901234567890.12345678901234567890,NULL)")
	sql := "SELECT r.label AS part,r.id AS repeated,r.computed,r.amount,r.part AS repeated,r.nullable FROM " + quoted + " AS r WHERE r.part=18446744073709551615"
	result := run(t, reader, sql)
	if result.Source == nil || result.Source.Schema != integrationSettings(t).Database || result.Source.Table != name || result.Source.ReadOnlyReason != "" || result.Source.Columns[0].Name != "label" || result.Source.Columns[1].PrimaryKey != 1 || result.Source.Columns[4].PrimaryKey != 2 || result.Source.Columns[2].Editable {
		t.Fatal("server origin did not preserve aliases, key order and generated columns")
	}
	request := mysqlQueryChanges(t, result, assign("label", typedText("")), assign("nullable", typedText("NULL")))
	if preview := executeChanges(writer, request, true); preview.Type != "query.result" || *run(t, reader, "SELECT label FROM "+quoted).Rows[0][0] != "NULL" {
		t.Fatal("query-result preview failed or wrote data")
	}
	if applied := executeChanges(writer, request, false); applied.Type != "query.result" {
		t.Fatalf("query-result Apply failed: category=%s state=%s diagnostic=%s", applied.Category, applied.SQLState, applied.Message)
	}
	after := run(t, reader, sql)
	if *after.Rows[0][0] != "" || *after.Rows[0][1] != "AP+A" || *after.Rows[0][3] != "12345678901234567890.12345678901234567890" || *after.Rows[0][5] != "NULL" {
		t.Fatal("query-result Apply changed exact, binary, NULL or empty values")
	}
	request = mysqlQueryChanges(t, after, assign("label", typedText("local")))
	run(t, reader, "UPDATE "+quoted+" SET nullable='concurrent'")
	if conflict := executeChanges(writer, request, false); conflict.Category != "conflict" || *run(t, reader, "SELECT label FROM "+quoted).Rows[0][0] != "" {
		t.Fatal("query original did not protect a concurrent nonedited column")
	}
}

func TestMySQLResultSourceProjectionAndReadonlyBoundaries(t *testing.T) {
	s := integrationSession(t)
	name := fmt.Sprintf("dbeer_query_limits_%x", s.connectionID)
	quoted := QuoteIdentifier(name)
	view := QuoteIdentifier(name + "_view")
	keyless := QuoteIdentifier(name + "_keyless")
	run(t, s, "CREATE TABLE "+quoted+"(id INT,part INT,value VARCHAR(30),PRIMARY KEY(id,part)) ENGINE=InnoDB")
	t.Cleanup(func() {
		run(t, s, "DROP VIEW IF EXISTS "+view)
		run(t, s, "DROP TABLE IF EXISTS "+keyless)
		run(t, s, "DROP TABLE IF EXISTS "+quoted)
	})
	run(t, s, "INSERT INTO "+quoted+" VALUES(1,2,'original')")
	run(t, s, "CREATE VIEW "+view+" AS SELECT * FROM "+quoted)
	run(t, s, "CREATE TABLE "+keyless+"(id INT,value VARCHAR(30)) ENGINE=InnoDB")
	projection := run(t, s, "SELECT part AS x,id AS x FROM "+quoted)
	if projection.Source == nil || projection.Source.Table != name || projection.Source.ReadOnlyReason == "" || len(projection.Source.Columns) != 2 {
		t.Fatal("exact complete-key projection did not retain source navigation")
	}
	run(t, s, "BEGIN")
	transactional := run(t, s, "SELECT * FROM "+quoted)
	if transactional.Source == nil || transactional.Source.Table != "" || transactional.Source.ReadOnlyReason == "" || s.TransactionStatus() != "transaction" {
		t.Fatal("transactional result gained a separate source-row session or lost transaction state")
	}
	run(t, s, "ROLLBACK")
	for _, sql := range []string{
		"SELECT value FROM " + quoted,
		"SELECT id FROM " + quoted,
		"SELECT a.* FROM " + quoted + " a JOIN " + quoted + " b ON a.id=b.id",
		"WITH source_cte AS (SELECT * FROM " + quoted + ") SELECT * FROM source_cte",
		"SELECT DISTINCT * FROM " + quoted,
		"SELECT id+0 AS id,part,value FROM " + quoted,
		"SELECT id,id,part,value FROM " + quoted,
		"SELECT * FROM " + quoted + " UNION ALL SELECT * FROM " + quoted,
		"SELECT * FROM " + view,
		"SELECT * FROM " + keyless,
	} {
		result := run(t, s, sql)
		if result.Source == nil || result.Source.Table != "" || result.Source.ReadOnlyReason == "" {
			t.Fatal("unsupported query or incomplete key gained source navigation")
		}
	}
	// The same wire schema/table/name can describe a temporary table that
	// shadows a permanent table. It must never target the permanent row.
	run(t, s, "CREATE TEMPORARY TABLE "+quoted+"(id INT,part INT,value VARCHAR(30),PRIMARY KEY(id,part)) ENGINE=InnoDB")
	run(t, s, "INSERT INTO "+quoted+" VALUES(1,2,'temporary')")
	shadow := run(t, s, "SELECT * FROM "+quoted)
	if shadow.Source == nil || shadow.Source.Table != "" || shadow.Source.ReadOnlyReason == "" {
		t.Fatal("temporary shadow gained source-row access to a permanent table")
	}
	run(t, s, "DROP TEMPORARY TABLE "+quoted)
}

func TestMySQLResultSourceLossyTypesKeepOnlyExactKeyNavigation(t *testing.T) {
	s := integrationSession(t)
	name := fmt.Sprintf("dbeer_query_types_%x", s.connectionID)
	quoted := QuoteIdentifier(name)
	run(t, s, "CREATE TABLE "+quoted+"(id INT PRIMARY KEY,score FLOAT,instant TIMESTAMP(6),choice ENUM('','x'),note VARCHAR(20)) ENGINE=InnoDB")
	t.Cleanup(func() { run(t, s, "DROP TABLE IF EXISTS "+quoted) })
	run(t, s, "INSERT INTO "+quoted+" VALUES(1,0.12345671,'2020-01-02 03:04:05','','original')")
	result := run(t, s, "SELECT * FROM "+quoted)
	if result.Source == nil || result.Source.Table != name || result.Source.ReadOnlyReason == "" {
		t.Fatal("unsafe raw storage representation was editable or hid exact-key navigation")
	}
	run(t, s, "SET NAMES latin1")
	converted := run(t, s, "SELECT * FROM "+quoted)
	if converted.Source == nil || converted.Source.ReadOnlyReason == "" {
		t.Fatal("lossy charset output was editable")
	}
	run(t, s, "SET NAMES utf8mb4")
}

func TestMySQLResultSourceLostCommitAckRetainsExistingUnknownHandling(t *testing.T) {
	reader, writer := integrationSession(t), integrationSession(t)
	name := fmt.Sprintf("dbeer_query_commit_%x", reader.connectionID)
	quoted := QuoteIdentifier(name)
	run(t, reader, "CREATE TABLE "+quoted+"(id INT PRIMARY KEY,value VARCHAR(30)) ENGINE=InnoDB")
	t.Cleanup(func() { run(t, reader, "DROP TABLE IF EXISTS "+quoted) })
	run(t, reader, "INSERT INTO "+quoted+" VALUES(1,'original')")
	request := mysqlQueryChanges(t, run(t, reader, "SELECT * FROM "+quoted), assign("value", typedText("committed")))
	var attempts atomic.Int32
	writer.commitOverride = func(commit func() error) error {
		attempts.Add(1)
		if err := commit(); err != nil {
			return err
		}
		return io.EOF
	}
	response := executeChanges(writer, request, false)
	if !response.OutcomeUnknown || attempts.Load() != 1 || *run(t, reader, "SELECT value FROM "+quoted).Rows[0][0] != "committed" {
		t.Fatal("query-result write lost uncertain-COMMIT protection")
	}
	response = writer.Execute(context.Background(), protocol.Command{Type: "changes.apply", Changes: &request})
	if !response.OutcomeUnknown || attempts.Load() != 1 {
		t.Fatal("query-result write was retried after uncertain COMMIT")
	}
}

func TestMySQLResultSourceMetadataSurvivesDriverPacketReuse(t *testing.T) {
	reader, writer := integrationSession(t), integrationSession(t)
	name := fmt.Sprintf("dbeer_query_lifetime_%x", reader.connectionID)
	quoted, churn := QuoteIdentifier(name), QuoteIdentifier(name+"_churn")
	run(t, reader, "CREATE TABLE "+quoted+"(id INT PRIMARY KEY,label VARCHAR(40),amount DECIMAL(40,20)) ENGINE=InnoDB")
	run(t, reader, "CREATE TABLE "+churn+"(key_id BIGINT PRIMARY KEY,other_text CHAR(80),total DECIMAL(30,10)) ENGINE=InnoDB")
	t.Cleanup(func() {
		run(t, reader, "DROP TABLE IF EXISTS "+churn)
		run(t, reader, "DROP TABLE IF EXISTS "+quoted)
	})
	run(t, reader, "INSERT INTO "+quoted+" VALUES(1,'original',12345678901234567890.12345678901234567890)")
	result := run(t, reader, "SELECT label,amount,id FROM "+quoted)
	if result.Source == nil || result.Source.ReadOnlyReason != "" {
		t.Fatal("source fixture unavailable")
	}
	before, err := json.Marshal(result.Source)
	if err != nil {
		t.Fatal("source fixture serialization failed")
	}
	// go-mysql's GetString aliases packet buffers returned by Result.Close.
	// Repeatedly replace them with unrelated native names/types before Apply.
	for index := 0; index < 32; index++ {
		run(t, reader, "SELECT * FROM "+churn)
	}
	after, err := json.Marshal(result.Source)
	if err != nil || string(before) != string(after) {
		t.Fatal("query provenance retained the driver's reused packet storage")
	}
	request := mysqlQueryChanges(t, result, assign("label", typedText("changed")))
	if applied := executeChanges(writer, request, false); applied.Type != "query.result" || *run(t, reader, "SELECT label FROM "+quoted).Rows[0][0] != "changed" {
		t.Fatal("reused metadata packet invalidated a captured SQL-result Apply")
	}
}
