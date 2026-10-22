package postgres

import (
	"context"
	tc "dbeer/helper/internal/tablecapture"
	"errors"
	"github.com/jackc/pgx/v5"
	"os"
	"testing"
	"time"
)

type dataTestSink struct {
	rows   [][]*string
	cancel context.CancelFunc
}

func (s *dataTestSink) Row(row []*string) error {
	s.rows = append(s.rows, row)
	if s.cancel != nil {
		s.cancel()
		return context.Canceled
	}
	return nil
}
func TestDataCapturePostgresExactLimitsDriftAndRLS(t *testing.T) {
	dsn := os.Getenv("DBEER_TEST_DSN")
	if dsn == "" {
		t.Skip("disposable PostgreSQL fixture required")
	}
	ctx := context.Background()
	conn, e := pgx.Connect(ctx, dsn)
	if e != nil {
		t.Fatal("fixture connection failed")
	}
	defer conn.Close(ctx)
	schema := "data_猫." + time.Now().Format("150405000000")
	q := pgx.Identifier{schema}.Sanitize()
	if _, e = conn.Exec(ctx, "CREATE SCHEMA "+q+"; CREATE TABLE "+q+".records(id bigint,amount numeric(40,20),note text,bytes bytea); INSERT INTO "+q+".records VALUES(1,9007199254740993.12345678901234567890,'',decode('00ff','hex')),(2,1.00,NULL,NULL),(3,NULL,'NULL',decode('','hex'))"); e != nil {
		t.Fatal("fixture creation failed")
	}
	defer conn.Exec(ctx, "DROP SCHEMA "+q+" CASCADE")
	read, e := pgx.Connect(ctx, dsn)
	if e != nil {
		t.Fatal("reader open failed")
	}
	s := &Session{conn: read}
	defer s.Close()
	table := tc.Table{Schema: schema, Name: "records"}
	d, e := s.DescribeTable(ctx, table)
	if e != nil {
		t.Fatalf("describe failed: %T", e)
	}
	for _, limit := range []int{2, 3, 4} {
		sink := &dataTestSink{}
		_, out, e := s.CaptureTable(ctx, tc.Spec{Table: table, DescriptorDigest: d.Digest, Columns: []string{"id", "amount", "note", "bytes"}, Keys: []string{"id"}, ReadLimit: limit}, sink)
		if e != nil {
			t.Fatalf("capture failed: %T", e)
		}
		if len(sink.rows) != min(limit, 3) || len(out.PartialReasons) > 0 != (limit == 2) {
			t.Fatal("sentinel completeness incorrect")
		}
		if *sink.rows[0][1] != "9007199254740993.12345678901234567890" || *sink.rows[0][2] != "" || *sink.rows[0][3] != "AP8=" || sink.rows[1][2] != nil {
			t.Fatal("exact values changed")
		}
	}
	cancelConn, e := pgx.Connect(ctx, dsn)
	if e != nil {
		t.Fatal("cancellation reader open failed")
	}
	cancelReader := &Session{conn: cancelConn}
	defer cancelReader.Close()
	readCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	started := time.Now()
	_, _, e = cancelReader.CaptureTable(readCtx, tc.Spec{Table: table, DescriptorDigest: d.Digest, Columns: []string{"id"}, Keys: []string{"id"}, ReadLimit: 10}, &dataTestSink{cancel: cancel})
	if !errors.Is(e, context.Canceled) || time.Since(started) > 6*time.Second {
		t.Fatal("cancelled capture did not stop within its cleanup budget")
	}
	if _, e = conn.Exec(ctx, "ALTER TABLE "+q+".records ADD COLUMN extra text"); e != nil {
		t.Fatal("fixture alteration failed")
	}
	if _, _, e = s.CaptureTable(ctx, tc.Spec{Table: table, DescriptorDigest: d.Digest, Columns: []string{"id"}, Keys: []string{"id"}, ReadLimit: 10}, &dataTestSink{}); e != tc.ErrChanged {
		t.Fatal("descriptor drift was accepted")
	}
	if _, e = conn.Exec(ctx, "ALTER TABLE "+q+".records ENABLE ROW LEVEL SECURITY"); e != nil {
		t.Fatal("RLS setup failed")
	}
	if _, e = s.DescribeTable(ctx, table); e != tc.ErrUnsupported {
		t.Fatal("RLS table accepted")
	}
}
