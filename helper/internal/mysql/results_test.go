package mysql

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"

	"dbeer/helper/internal/protocol"
)

func TestMySQLResultFramingRejectsMalformedPackets(t *testing.T) {
	for _, data := range [][]byte{nil, {0xfc}, {0xfd, 1}, {0xfe, 1, 2, 3}, {0xfb}, {0xff}} {
		if _, _, ok := lengthEncoded(data); ok {
			t.Fatal("invalid length accepted")
		}
	}
	for _, data := range [][]byte{nil, {0}, {0, 0}, {0, 0, 0, 1, 2, 3}} {
		if validOKPacket(data) {
			t.Fatal("invalid OK accepted")
		}
	}
	if !validOKPacket([]byte{0, 0, 0, 2, 0, 0, 0}) {
		t.Fatal("valid OK rejected")
	}
	for _, sql := range []string{"SOURCE file.sql", "DELIMITER $$", "\\! cat file", "/*comment*/ LOAD DATA LOW_PRIORITY LOCAL INFILE '/private/file' INTO TABLE t", "LOAD XML LOCAL INFILE 'x' INTO TABLE t", "COPY t FROM STDIN"} {
		if !unsupportedStatement(sql) {
			t.Fatal("unsupported command was not rejected")
		}
	}
	for _, sql := range []string{"SELECT 'LOAD DATA LOCAL'", "CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END", "LOAD DATA INFILE '/server/file' INTO TABLE t", "USE db"} {
		if unsupportedStatement(sql) {
			t.Fatal("valid server SQL rejected")
		}
	}
}

func TestMySQLProcedureMultipleResultsAndFinalStatus(t *testing.T) {
	session := integrationSession(t)
	name := fmt.Sprintf("dbeer_multi_%x", session.connectionID)
	procedure, table := QuoteIdentifier(name), QuoteIdentifier(name+"_table")
	t.Cleanup(func() {
		session.Execute(context.Background(), protocol.Command{RequestID: "cleanup", SQL: "DROP PROCEDURE IF EXISTS " + procedure})
		session.Execute(context.Background(), protocol.Command{RequestID: "cleanup", SQL: "DROP TABLE IF EXISTS " + table})
	})
	run(t, session, "CREATE TABLE "+table+" (id INT PRIMARY KEY) ENGINE=InnoDB")
	run(t, session, "CREATE PROCEDURE "+procedure+"() BEGIN SELECT 1 AS first_column; SELECT 'two' AS second_column, NULL AS second_column; INSERT INTO "+table+" VALUES (1); END")
	run(t, session, "BEGIN")
	response := run(t, session, "CALL "+procedure+"()")
	if len(response.ResultSets) != 3 || *response.ResultSets[0].Rows[0][0] != "1" || *response.ResultSets[1].Rows[0][0] != "two" || response.ResultSets[1].Rows[0][1] != nil || response.ResultSets[2].RowCount != 1 || response.TransactionStatus != "transaction" {
		t.Fatal("CALL did not expose all results and final transaction status")
	}
	if *response.Rows[0][0] != "1" {
		t.Fatal("primary result was not preserved")
	}
	if *run(t, session, "SELECT COUNT(*) FROM "+table).Rows[0][0] != "1" {
		t.Fatal("CALL final OK was not drained")
	}
	run(t, session, "ROLLBACK")
	if *run(t, session, "SELECT COUNT(*) FROM "+table).Rows[0][0] != "0" {
		t.Fatal("CALL transaction was not rolled back")
	}
	response = session.Execute(context.Background(), protocol.Command{RequestID: "multi", SQL: "SELECT 1; SELECT 2"})
	if response.Type != "error" || !response.Connected {
		t.Fatal("multiple user statements were enabled")
	}
	run(t, session, "SELECT 1")
}

func TestMySQLProcedureLateErrorPreservesCompletedResult(t *testing.T) {
	session := integrationSession(t)
	procedure := QuoteIdentifier(fmt.Sprintf("dbeer_late_%x", session.connectionID))
	t.Cleanup(func() {
		session.Execute(context.Background(), protocol.Command{RequestID: "cleanup", SQL: "DROP PROCEDURE IF EXISTS " + procedure})
	})
	run(t, session, "CREATE PROCEDURE "+procedure+"() BEGIN SELECT 7 AS before_error; SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='intentional fixture failure'; END")
	run(t, session, "BEGIN")
	response := session.Execute(context.Background(), protocol.Command{RequestID: "late", SQL: "CALL " + procedure + "()"})
	if response.Type != "error" || response.SQLState != "45000" || !response.Connected || response.OutcomeUnknown || response.TransactionStatus != "transaction" || len(response.ResultSets) != 1 || *response.ResultSets[0].Rows[0][0] != "7" {
		t.Fatal("late result error lost state or completed results")
	}
	run(t, session, "SELECT 1")
	run(t, session, "ROLLBACK")
}

func TestMySQLProcedureResultLimitsApplyAcrossAllSets(t *testing.T) {
	session := integrationSession(t)
	procedure := QuoteIdentifier(fmt.Sprintf("dbeer_limits_%x", session.connectionID))
	t.Cleanup(func() {
		session.Execute(context.Background(), protocol.Command{RequestID: "cleanup", SQL: "DROP PROCEDURE IF EXISTS " + procedure})
	})
	rows := "WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<700) SELECT n FROM seq"
	run(t, session, "CREATE PROCEDURE "+procedure+"() BEGIN "+rows+"; "+rows+"; SELECT REPEAT('x',1000000); END")
	response := run(t, session, "CALL "+procedure+"()")
	saved := 0
	for _, set := range response.ResultSets {
		saved += len(set.Rows)
	}
	encoded, _ := json.Marshal(response)
	if len(response.ResultSets) != 4 || saved > 1000 || len(encoded) > MaxResultBytes || !response.ResultSets[1].Truncated || response.ResultSets[1].RowCount != 700 {
		t.Fatal("CALL exceeded global display budget")
	}
	run(t, session, "SELECT 1")
	run(t, session, "DROP PROCEDURE "+procedure)
	run(t, session, "CREATE PROCEDURE "+procedure+"() BEGIN SELECT REPEAT('x',3000000); SELECT REPEAT('y',3000000); END")
	response = run(t, session, "CALL "+procedure+"()")
	encoded, _ = json.Marshal(response)
	if len(encoded) > MaxResultBytes || len(response.ResultSets) != 3 || !response.ResultSets[1].Truncated || response.ResultSets[1].RowCount != 1 {
		t.Fatal("CALL wire byte budget ignored the duplicated primary result")
	}
	run(t, session, "SELECT 1")
}
