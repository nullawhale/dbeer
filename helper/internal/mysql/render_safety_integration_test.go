package mysql

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"dbeer/helper/internal/protocol"
	tc "dbeer/helper/internal/tablecapture"
)

func TestMySQLFloatTimezoneAndCharsetRenderCollisionsStayUncertain(t *testing.T) {
	s := integrationSession(t)
	name := fmt.Sprintf("dbeer_render_collision_%x", s.connectionID)
	quoted := QuoteIdentifier(name)
	run(t, s, "SET SESSION time_zone='+00:00'")
	run(t, s, "CREATE TABLE "+quoted+"(id INT PRIMARY KEY,f FLOAT,d DOUBLE,fixed DOUBLE(20,8),instant TIMESTAMP(6),words VARCHAR(8) CHARACTER SET utf8mb4) ENGINE=InnoDB")
	defer run(t, s, "DROP TABLE IF EXISTS "+quoted)
	run(t, s, "INSERT INTO "+quoted+" VALUES(1,0.12345671,1.2345678901234567,1.23456789,'2020-01-02 03:04:05','Ā'),(2,0.12345672,1.2345678901234565,1.23456788,'2020-01-02 04:04:05','ā')")
	result := run(t, s, "SELECT f,CAST(f AS DOUBLE),d,fixed FROM "+quoted+" ORDER BY id")
	if *result.Rows[0][0] != *result.Rows[1][0] || *result.Rows[0][1] == *result.Rows[1][1] {
		t.Fatal("FLOAT collision fixture did not expose text precision loss")
	}
	if !strings.HasPrefix(result.Columns[0].TypeIdentity, "unresolved:") || !strings.HasPrefix(result.Columns[3].TypeIdentity, "unresolved:") {
		t.Fatal("lossy approximate output gained exact comparison identity")
	}
	if strings.HasPrefix(result.Columns[2].TypeIdentity, "unresolved:") || *result.Rows[0][2] == *result.Rows[1][2] {
		t.Fatal("roundtrip DOUBLE output was lost")
	}
	first := run(t, s, "SELECT instant FROM "+quoted+" WHERE id=1")
	run(t, s, "SET SESSION time_zone='-01:00'")
	second := run(t, s, "SELECT instant FROM "+quoted+" WHERE id=2")
	if *first.Rows[0][0] != *second.Rows[0][0] || !strings.HasPrefix(first.Columns[0].TypeIdentity, "unresolved:") || !strings.HasPrefix(second.Columns[0].TypeIdentity, "unresolved:") {
		t.Fatal("different TIMESTAMP instants gained equality through wall time")
	}
	run(t, s, "SET NAMES latin1")
	converted := run(t, s, "SELECT words FROM "+quoted+" ORDER BY id")
	if *converted.Rows[0][0] != *converted.Rows[1][0] || !strings.HasPrefix(converted.Columns[0].TypeIdentity, "unresolved:") {
		t.Fatal("lossy output charset gained equality")
	}
	run(t, s, "SET NAMES utf8mb4")
	unicode := run(t, s, "SELECT words FROM "+quoted+" ORDER BY id")
	if *unicode.Rows[0][0] == *unicode.Rows[1][0] || strings.HasPrefix(unicode.Columns[0].TypeIdentity, "unresolved:") {
		t.Fatal("Unicode wire output was not preserved as known")
	}
	reader := integrationSession(t)
	if err := reader.SetReadOnly(context.Background(), true); err != nil {
		t.Fatal("capture read-only setup failed")
	}
	table := tc.Table{Schema: integrationSettings(t).Database, Name: name}
	d, err := reader.DescribeTable(context.Background(), table)
	if err != nil {
		t.Fatal("precise FLOAT descriptor failed")
	}
	sink := &dataCaptureTestSink{}
	_, out, err := reader.CaptureTable(context.Background(), tc.Spec{Table: table, DescriptorDigest: d.Digest, Columns: []string{"id", "f"}, Keys: []string{"id"}, ReadLimit: 10}, sink)
	if err != nil || len(sink.rows) != 2 || *sink.rows[0][1] == *sink.rows[1][1] || out.Rendering != "mysqlTextUTCUTF8v3" {
		t.Fatal("table capture collapsed distinct FLOAT storage")
	}
}

func TestMySQLCanonicalBrowseStorageEvidenceProtectsFloatsAndTimestamps(t *testing.T) {
	s, writer := integrationSession(t), integrationSession(t)
	name := fmt.Sprintf("dbeer_render_tokens_%x", s.connectionID)
	quoted := QuoteIdentifier(name)
	run(t, s, "SET SESSION time_zone='+00:00'")
	run(t, s, "CREATE TABLE "+quoted+"(id INT PRIMARY KEY,f FLOAT,instant TIMESTAMP(6),note VARCHAR(30)) ENGINE=InnoDB")
	defer run(t, s, "DROP TABLE IF EXISTS "+quoted)
	run(t, s, "INSERT INTO "+quoted+" VALUES(1,0.12345671,'2020-01-02 03:04:05','original')")
	request := editingRequest(t, s, name)
	run(t, s, "SET SESSION time_zone='+03:00'")
	browse := catalogRequest(t, s, protocol.CatalogRequest{Kind: "browse", Schema: request.Schema, Object: name, ObjectKind: "table"})
	if len(browse.StorageTokens) != 1 || len(browse.Columns) != 4 || *browse.Rows[0][2] != "2020-01-02 03:04:05.000000" {
		t.Fatal("canonical UTC browse evidence missing")
	}
	row := make([]protocol.CellValue, 4)
	for i, value := range browse.Rows[0] {
		row[i] = protocol.CellValue{Kind: "text", Value: value}
	}
	request.Changes = []protocol.RowChange{{Kind: "update", Original: row, StorageToken: browse.StorageTokens[0], Values: []protocol.ColumnAssignment{assign("note", typedText("changed"))}}}
	run(t, writer, "SET SESSION time_zone='-04:00'")
	if response := executeChanges(writer, request, false); response.Type != "query.result" {
		t.Fatalf("exact canonical original was rejected: category=%s state=%s", response.Category, response.SQLState)
	}
	request.Changes[0].Original[3] = typedText("changed")
	run(t, s, "UPDATE "+quoted+" SET f=0.12345672 WHERE id=1")
	if response := executeChanges(writer, request, false); response.Category != "conflict" {
		t.Fatal("FLOAT change hidden by text rounding was overwritten")
	}
	request.Changes[0].StorageToken = ""
	response := writer.ExecuteChanges(context.Background(), protocol.Command{Type: "changes.apply", Changes: &request})
	if response.Category != "conflict" {
		t.Fatal("tokenless approximate/timezone-sensitive originals were trusted")
	}
}

func TestMySQLCanonicalTimestampKeepsLegacyZeroSeparateFromNull(t *testing.T) {
	s := integrationSession(t)
	name := fmt.Sprintf("dbeer_zero_timestamp_%x", s.connectionID)
	quoted := QuoteIdentifier(name)
	run(t, s, "SET SESSION sql_mode='',time_zone='+00:00'")
	run(t, s, "CREATE TABLE "+quoted+"(id INT PRIMARY KEY,instant TIMESTAMP(6) NULL) ENGINE=InnoDB")
	defer run(t, s, "DROP TABLE IF EXISTS "+quoted)
	run(t, s, "INSERT INTO "+quoted+" VALUES(1,'0000-00-00 00:00:00'),(2,NULL),(3,'0000-00-00 00:00:00.123456')")
	run(t, s, "SET SESSION time_zone='+03:00'")
	stored := run(t, s, "SELECT CAST(instant AS CHAR) FROM "+quoted+" ORDER BY id")
	response := catalogRequest(t, s, protocol.CatalogRequest{Kind: "browse", Schema: integrationSettings(t).Database, Object: name, ObjectKind: "table"})
	if len(response.Rows) != 3 || response.Rows[0][1] == nil || *response.Rows[0][1] != "0000-00-00 00:00:00.000000" || response.Rows[1][1] != nil || len(response.StorageTokens) != 3 || response.StorageTokens[0] == response.StorageTokens[1] {
		t.Fatal("legacy zero TIMESTAMP collapsed with SQL NULL")
	}
	if stored.Rows[2][0] == nil || response.Rows[2][1] == nil || *stored.Rows[2][0] != *response.Rows[2][1] {
		t.Fatal("legacy fractional zero TIMESTAMP lost its stored fraction")
	}
	// MySQL can normalize this invalid fractional zero on insertion. Compare
	// exactly with the stored representation, rather than inventing a fraction.
	if *stored.Rows[2][0] != *stored.Rows[0][0] && response.StorageTokens[0] == response.StorageTokens[2] {
		t.Fatal("distinct legacy zero TIMESTAMP storage tokens collapsed")
	}
}

func TestMySQLDuplicateChoiceLabelsNeedStorageEvidence(t *testing.T) {
	s, writer := integrationSession(t), integrationSession(t)
	name := fmt.Sprintf("dbeer_choice_ambiguity_%x", s.connectionID)
	quoted := QuoteIdentifier(name)
	run(t, s, "SET SESSION sql_mode=''")
	run(t, s, "CREATE TABLE "+quoted+"(id INT PRIMARY KEY,e ENUM('a','a'),s SET('a','a'),note VARCHAR(20)) ENGINE=InnoDB")
	defer run(t, s, "DROP TABLE IF EXISTS "+quoted)
	run(t, s, "INSERT INTO "+quoted+" VALUES(1,1,1,'original'),(2,2,2,'other')")
	response := run(t, s, "SELECT e,s FROM "+quoted+" ORDER BY id")
	if *response.Rows[0][0] != *response.Rows[1][0] || *response.Rows[0][1] != *response.Rows[1][1] {
		t.Fatal("noninjective choice fixture did not expose storage ambiguity")
	}
	request := editingRequest(t, s, name)
	request.Changes = []protocol.RowChange{{Kind: "update", Original: originalRow(t, s, name, "id=1"), Values: []protocol.ColumnAssignment{assign("note", typedText("changed"))}}}
	// Use the direct adapter entry point to model a legacy snapshot with no
	// generated browse token, bypassing the fixture's token-aware convenience.
	legacy := writer.ExecuteChanges(context.Background(), protocol.Command{Type: "changes.apply", Changes: &request})
	if legacy.Category != "conflict" {
		t.Fatal("ambiguous tokenless choice labels were trusted")
	}
	browse := catalogRequest(t, s, protocol.CatalogRequest{Kind: "browse", Schema: request.Schema, Object: name, ObjectKind: "table"})
	if len(browse.StorageTokens) != 2 || browse.StorageTokens[0] == browse.StorageTokens[1] {
		t.Fatal("choice evidence collapsed duplicate labels")
	}
	request.Changes[0].StorageToken = browse.StorageTokens[0]
	if applied := executeChanges(writer, request, false); applied.Type != "query.result" {
		t.Fatal("exact choice storage evidence did not allow unchanged row")
	}
}
