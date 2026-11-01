package postgres

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"dbeer/helper/internal/exportfile"
	"dbeer/helper/internal/protocol"
)

func pgParameter(name, kind, value string) protocol.QueryParameter {
	return protocol.QueryParameter{Name: name, Type: kind, Value: &value}
}

func TestPostgresQueryParametersAreTypedBoundAndTransactionLocal(t *testing.T) {
	f := newChangeFixture(t)
	ctx := context.Background()
	params := []protocol.QueryParameter{pgParameter("text", "text", "'; DELETE FROM nothing; --"), pgParameter("integer", "integer", "9223372036854775807"), pgParameter("amount", "decimal", "12345678901234567890.123456789"), pgParameter("enabled", "boolean", "true"), pgParameter("day", "date", "2024-02-29"), pgParameter("at", "timestamp", "2026-11-01 12:30:59.123456"), {Name: "nothing", Type: "integer"}, pgParameter("empty", "text", "")}
	sql := "SELECT :text,:integer,:amount,:enabled,:day,:at,:nothing,:empty,:text"
	r := execute(ctx, f.conn, protocol.Command{Type: "execute", SQL: sql, Parameters: params})
	if r.Type != "query.result" || len(r.Rows) != 1 || len(r.Rows[0]) != 9 {
		t.Fatal("bound query failed")
	}
	row := r.Rows[0]
	for i := 0; i < 6; i++ {
		expected := *params[i].Value
		if i == 3 {
			expected = "t"
		}
		if row[i] == nil || *row[i] != expected {
			t.Fatalf("typed parameter %d changed", i)
		}
	}
	if row[6] != nil || row[7] == nil || *row[7] != "" || *row[8] != *params[0].Value {
		t.Fatal("null, empty or repeated text changed")
	}
	if r.Source != nil && r.Source.Table != "" {
		t.Fatal("bound query inferred an editable source")
	}
	f.exec("CREATE TABLE " + f.table("bound_values") + " (id bigint)")
	if _, err := f.conn.Exec(ctx, "BEGIN"); err != nil {
		t.Fatal("begin owning transaction")
	}
	r = execute(ctx, f.conn, protocol.Command{Type: "execute", SQL: "INSERT INTO " + f.table("bound_values") + " VALUES (:integer)", Parameters: params})
	if r.Type != "query.result" || r.TransactionStatus != "transaction" {
		t.Fatal("binding lost active transaction")
	}
	if _, err := f.conn.Exec(ctx, "ROLLBACK"); err != nil {
		t.Fatal("rollback owning transaction")
	}
	var count int
	if f.conn.QueryRow(ctx, "SELECT count(*) FROM "+f.table("bound_values")).Scan(&count) != nil || count != 0 {
		t.Fatal("bound mutation escaped rollback")
	}
	r = execute(ctx, f.conn, protocol.Command{Type: "execute", SQL: "SELECT :integer +", Parameters: params})
	if r.Type != "error" || r.ErrorPosition != 0 {
		t.Fatal("rewritten error position escaped to original SQL")
	}
}

func TestPostgresQueryParametersStreamFullExportAndCancellation(t *testing.T) {
	f := newChangeFixture(t)
	params := []protocol.QueryParameter{pgParameter("limit", "integer", "1301")}
	writer, err := exportfile.New(protocol.ExportRequest{Path: filepath.Join(t.TempDir(), "parameters.json"), Format: "json"})
	if err != nil {
		t.Fatal("create export")
	}
	defer writer.Abort()
	r := executeNamedParameters(context.Background(), f.conn, protocol.Command{Type: "execute", SQL: "SELECT generate_series(1,:limit)", Parameters: params}, writer)
	if r.Type != "query.result" || !r.Truncated || writer.RowCount() != 1301 || writer.Commit() != nil {
		t.Fatal("bound export lost rows")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	r = execute(ctx, f.conn, protocol.Command{Type: "execute", SQL: "SELECT pg_sleep(:seconds)", Parameters: []protocol.QueryParameter{pgParameter("seconds", "integer", "10")}})
	if r.Type != "error" || r.Category != "timeout" || !r.Connected {
		t.Fatal("bound cancellation did not recover")
	}
	r = execute(context.Background(), f.conn, protocol.Command{Type: "execute", SQL: "SELECT :limit", Parameters: params})
	if r.Type != "query.result" {
		t.Fatal("cancelled bound session could not be reused")
	}
}
