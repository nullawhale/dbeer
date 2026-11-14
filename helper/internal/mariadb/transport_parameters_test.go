package mariadb

import (
	"context"
	"fmt"
	"io"
	"net"
	"path/filepath"
	"testing"
	"time"

	"dbeer/helper/internal/exportfile"
	"dbeer/helper/internal/protocol"
	wire "github.com/go-mysql-org/go-mysql/mysql"
)

func myParameter(name, kind, value string) protocol.QueryParameter {
	return protocol.QueryParameter{Name: name, Type: kind, Value: &value}
}

type failPreparedCloseTransport struct{ net.Conn }

func (transport failPreparedCloseTransport) Write(packet []byte) (int, error) {
	if len(packet) >= 5 && packet[4] == wire.COM_STMT_CLOSE {
		return 0, io.ErrClosedPipe
	}
	return transport.Conn.Write(packet)
}

func TestMariaDBDataQueryParametersCleanupFailureRetainsAcknowledgedMutation(t *testing.T) {
	s, observer := dataIntegrationSession(t), dataIntegrationSession(t)
	table := dataQuoteIdentifier(fmt.Sprintf("dbeer_parameter_close_%d", s.connectionID))
	dataRun(t, observer, "CREATE TABLE "+table+" (id BIGINT PRIMARY KEY) ENGINE=InnoDB")
	t.Cleanup(func() { dataRun(t, observer, "DROP TABLE IF EXISTS "+table) })
	s.work.client.Conn.Conn = failPreparedCloseTransport{s.work.client.Conn.Conn}
	r := s.Execute(context.Background(), protocol.Command{Type: "execute", SQL: "INSERT INTO " + table + " VALUES (:id)", Parameters: []protocol.QueryParameter{myParameter("id", "integer", "42")}})
	if r.Type != "error" || !r.SQLCompleted || r.OutcomeUnknown || r.Connected || !s.closed.Load() || len(r.ResultSets) != 1 || r.ResultSets[0].RowCount != 1 {
		t.Fatal("statement cleanup erased acknowledged SQL completion")
	}
	observed := dataRun(t, observer, "SELECT count(*) FROM "+table)
	if len(observed.Rows) != 1 || *observed.Rows[0][0] != "1" {
		t.Fatal("acknowledged mutation changed during statement cleanup")
	}
}

func TestMariaDBDataQueryParametersArePreparedTypedAndTransactionLocal(t *testing.T) {
	s := dataIntegrationSession(t)
	params := []protocol.QueryParameter{myParameter("text", "text", "'; DELETE FROM nothing; --"), myParameter("integer", "integer", "9223372036854775807"), myParameter("amount", "decimal", "12345678901234567890.123456789"), myParameter("enabled", "boolean", "true"), myParameter("day", "date", "2024-02-29"), myParameter("at", "timestamp", "2026-11-01 12:30:59.123456"), {Name: "nothing", Type: "integer"}, myParameter("empty", "text", "")}
	r := s.Execute(context.Background(), protocol.Command{Type: "execute", SQL: "SELECT :text,:integer,:amount,:enabled,:day,:at,:nothing,:empty,:text", Parameters: params})
	if r.Type != "query.result" || len(r.Rows) != 1 || len(r.Rows[0]) != 9 {
		t.Fatal("prepared query failed")
	}
	row := r.Rows[0]
	for i := 0; i < 6; i++ {
		expected := *params[i].Value
		if i == 3 {
			expected = "1"
		}
		if row[i] == nil || *row[i] != expected {
			t.Fatalf("typed parameter %d changed", i)
		}
	}
	if row[6] != nil || row[7] == nil || *row[7] != "" || *row[8] != *params[0].Value {
		t.Fatal("null, empty or repeated text changed")
	}
	dataRun(t, s, "CREATE TEMPORARY TABLE bound_values (id BIGINT) ENGINE=InnoDB")
	dataRun(t, s, "BEGIN")
	r = s.Execute(context.Background(), protocol.Command{Type: "execute", SQL: "INSERT INTO bound_values VALUES (:integer)", Parameters: params})
	if r.Type != "query.result" || r.TransactionStatus != "transaction" {
		t.Fatal("binding lost transaction")
	}
	dataRun(t, s, "ROLLBACK")
	r = dataRun(t, s, "SELECT count(*) FROM bound_values")
	if len(r.Rows) != 1 || *r.Rows[0][0] != "0" {
		t.Fatal("prepared mutation escaped rollback")
	}
}

func TestMariaDBDataQueryParametersStreamFullExportAndCancellation(t *testing.T) {
	s := dataIntegrationSession(t)
	params := []protocol.QueryParameter{myParameter("limit", "integer", "1301")}
	writer, err := exportfile.New(protocol.ExportRequest{Path: filepath.Join(t.TempDir(), "parameters.json"), Format: "json"})
	if err != nil {
		t.Fatal("create export")
	}
	defer writer.Abort()
	sql := "WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<1000) SELECT n FROM seq CROSS JOIN (SELECT 1 AS pair UNION ALL SELECT 2) pairs LIMIT :limit"
	r := s.ExecuteWithSink(context.Background(), protocol.Command{Type: "execute", SQL: sql, Parameters: params}, writer)
	if r.Type != "query.result" || !r.Truncated || writer.RowCount() != 1301 || writer.Commit() != nil {
		t.Fatal("prepared export lost rows")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	r = s.Execute(ctx, protocol.Command{Type: "execute", SQL: "SELECT 1 FROM (SELECT 1 AS n UNION ALL SELECT 2) source_rows WHERE SLEEP(:seconds) = 0", Parameters: []protocol.QueryParameter{myParameter("seconds", "integer", "10")}})
	if r.Type != "error" || r.Category != "timeout" || !r.Connected {
		t.Fatal("prepared cancellation did not recover")
	}
	r = s.Execute(context.Background(), protocol.Command{Type: "execute", SQL: "SELECT :limit", Parameters: params})
	if r.Type != "query.result" {
		t.Fatal("cancelled prepared session could not be reused")
	}
}
