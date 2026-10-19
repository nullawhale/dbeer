package mysql

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"dbeer/helper/internal/adapter"
	"dbeer/helper/internal/exportfile"
	"dbeer/helper/internal/protocol"
)

type countingSink struct {
	rows         int
	begins, ends []int
	failAt       int
	wait         context.Context
}

func (sink *countingSink) Begin(index int, _ []protocol.Column) error {
	sink.begins = append(sink.begins, index)
	return nil
}
func (sink *countingSink) Row(_ int, _ []*string) error {
	sink.rows++
	if sink.wait != nil {
		<-sink.wait.Done()
		return sink.wait.Err()
	}
	if sink.failAt > 0 && sink.rows == sink.failAt {
		return errors.New("fixture write failure")
	}
	return nil
}
func (sink *countingSink) End(index int, _ protocol.ResultSet) error {
	sink.ends = append(sink.ends, index)
	return nil
}

var _ adapter.StreamingSession = (*Session)(nil)

func TestMySQLSinkReceivesAllRowsBeforePreviewTruncation(t *testing.T) {
	session := integrationSession(t)
	sink := &countingSink{}
	query := "WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<1000) SELECT n FROM seq CROSS JOIN (SELECT 1 AS pair UNION ALL SELECT 2) pairs LIMIT 1301"
	response := session.ExecuteWithSink(context.Background(), protocol.Command{RequestID: "stream", SQL: query}, sink)
	if response.Type != "query.result" || len(response.Rows) != 1000 || !response.Truncated || sink.rows != 1301 || len(sink.begins) != 1 || len(sink.ends) != 1 {
		t.Fatal("sink did not receive exactly one full execution")
	}
	failure := &countingSink{failAt: 2}
	response = session.ExecuteWithSink(context.Background(), protocol.Command{RequestID: "failure", SQL: query}, failure)
	if response.Type != "query.result" || response.RowCount != 1301 || failure.rows != 2 {
		t.Fatal("sink failure changed or interrupted the server outcome")
	}
	run(t, session, "SELECT 1")
}

func TestMySQLJSONExportIsCompleteAndRunsVolatileSQLOnce(t *testing.T) {
	session := integrationSession(t)
	path := filepath.Join(t.TempDir(), "result.json")
	writer, err := exportfile.New(protocol.ExportRequest{Path: path, Format: "json"})
	if err != nil {
		t.Fatal("cannot create export fixture")
	}
	defer writer.Abort()
	query := "WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<1000) SELECT n,CAST('18446744073709551615' AS UNSIGNED) AS x,NULL AS x,X'00FF80' AS x FROM seq CROSS JOIN (SELECT 1 AS pair UNION ALL SELECT 2) pairs LIMIT 1301"
	response := session.ExecuteWithSink(context.Background(), protocol.Command{RequestID: "export", SQL: query}, writer)
	if response.Type != "query.result" || !response.Truncated || writer.Commit() != nil || writer.RowCount() != 1301 {
		t.Fatal("full export was truncated")
	}
	var document struct {
		Version int `json:"version"`
		Sets    []struct {
			Rows     [][]*string `json:"rows"`
			Metadata struct {
				Columns   []protocol.Column `json:"columns"`
				Truncated bool              `json:"truncated"`
			} `json:"metadata"`
		} `json:"resultSets"`
	}
	data, _ := os.ReadFile(path)
	if json.Unmarshal(data, &document) != nil || document.Version != 1 || len(document.Sets) != 1 || len(document.Sets[0].Rows) != 1301 || document.Sets[0].Metadata.Truncated {
		t.Fatal("JSON export schema or row count changed")
	}
	row := document.Sets[0].Rows[0]
	if *row[1] != "18446744073709551615" || row[2] != nil || *row[3] != "AP+A" || document.Sets[0].Metadata.Columns[3].Encoding != "base64" {
		t.Fatal("export lost typed values")
	}
	table, procedure := QuoteIdentifier(fmt.Sprintf("dbeer_once_%x", session.connectionID)), QuoteIdentifier(fmt.Sprintf("dbeer_once_proc_%x", session.connectionID))
	t.Cleanup(func() {
		session.Execute(context.Background(), protocol.Command{RequestID: "cleanup", SQL: "DROP PROCEDURE IF EXISTS " + procedure})
		session.Execute(context.Background(), protocol.Command{RequestID: "cleanup", SQL: "DROP TABLE IF EXISTS " + table})
	})
	run(t, session, "CREATE TABLE "+table+" (counter INT)")
	run(t, session, "INSERT INTO "+table+" VALUES(0)")
	run(t, session, "CREATE PROCEDURE "+procedure+"() BEGIN UPDATE "+table+" SET counter=counter+1; SELECT counter FROM "+table+"; SELECT 'κόσμος' AS x; END")
	writer, err = exportfile.New(protocol.ExportRequest{Path: path, Format: "json"})
	if err != nil {
		t.Fatal("cannot create CALL export")
	}
	defer writer.Abort()
	response = session.ExecuteWithSink(context.Background(), protocol.Command{RequestID: "call", SQL: "CALL " + procedure + "()"}, writer)
	if response.Type != "query.result" || writer.Commit() != nil || writer.RowCount() != 2 || *run(t, session, "SELECT counter FROM "+table).Rows[0][0] != "1" {
		t.Fatal("CALL export repeated volatile SQL or missed result sets")
	}
	writer, err = exportfile.New(protocol.ExportRequest{Path: path, Format: "csv"})
	if err != nil {
		t.Fatal("cannot create CSV fixture")
	}
	defer writer.Abort()
	before, _ := os.ReadFile(path)
	response = session.ExecuteWithSink(context.Background(), protocol.Command{RequestID: "csv", SQL: "CALL " + procedure + "()"}, writer)
	if response.Type != "query.result" || !errors.Is(writer.Commit(), exportfile.ErrMultipleResults) || *run(t, session, "SELECT counter FROM "+table).Rows[0][0] != "2" {
		t.Fatal("CSV multi-result rejection replayed SQL or changed SQL outcome")
	}
	after, _ := os.ReadFile(path)
	if string(before) != string(after) {
		t.Fatal("failed CSV export replaced the existing target")
	}
}

func TestMySQLExportCollisionAndCancellationPreserveExistingTarget(t *testing.T) {
	session := integrationSession(t)
	path := filepath.Join(t.TempDir(), "existing.csv")
	if os.WriteFile(path, []byte("existing"), 0600) != nil {
		t.Fatal("cannot prepare existing target")
	}
	marker := "NULL"
	writer, err := exportfile.New(protocol.ExportRequest{Path: path, Format: "csv", NullMarker: &marker})
	if err != nil {
		t.Fatal("cannot create collision writer")
	}
	defer writer.Abort()
	run(t, session, "SET @dbeer_collision_count=0")
	response := session.ExecuteWithSink(context.Background(), protocol.Command{RequestID: "collision", SQL: "SELECT @dbeer_collision_count:=@dbeer_collision_count+1,'NULL',NULL"}, writer)
	if response.Type != "query.result" || !errors.Is(writer.Commit(), exportfile.ErrNullCollision) || *run(t, session, "SELECT @dbeer_collision_count").Rows[0][0] != "1" {
		t.Fatal("collision changed SQL outcome or executed SQL twice")
	}
	data, _ := os.ReadFile(path)
	if string(data) != "existing" {
		t.Fatal("CSV collision replaced target")
	}
	writer, err = exportfile.New(protocol.ExportRequest{Path: path, Format: "json"})
	if err != nil {
		t.Fatal("cannot create cancellation writer")
	}
	defer writer.Abort()
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	response = session.ExecuteWithSink(ctx, protocol.Command{RequestID: "cancel-export", SQL: "SELECT 1 FROM (SELECT 1 AS n UNION ALL SELECT 2) source_rows WHERE SLEEP(10)=0"}, writer)
	writer.Abort()
	if response.Category != "timeout" || !response.Connected {
		t.Fatal("export cancellation did not recover SQL session")
	}
	data, _ = os.ReadFile(path)
	if string(data) != "existing" {
		t.Fatal("cancelled export replaced target")
	}
	ctx, cancel = context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	blocked := &countingSink{wait: ctx}
	started := time.Now()
	session.ExecuteWithSink(ctx, protocol.Command{RequestID: "backpressure", SQL: "SELECT 1 UNION ALL SELECT 2"}, blocked)
	if time.Since(started) > 5*time.Second {
		t.Fatal("stalled sink prevented cancellation")
	}
	run(t, session, "SELECT 1")
}
