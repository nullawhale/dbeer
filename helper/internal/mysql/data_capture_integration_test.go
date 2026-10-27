package mysql

import (
	"context"
	tc "dbeer/helper/internal/tablecapture"
	"errors"
	wire "github.com/go-mysql-org/go-mysql/mysql"
	"testing"
	"time"
)

type dataCaptureTestSink struct {
	rows   [][]*string
	cancel context.CancelFunc
}

func (s *dataCaptureTestSink) Row(row []*string) error {
	s.rows = append(s.rows, row)
	if s.cancel != nil {
		s.cancel()
		return context.Canceled
	}
	return nil
}
func TestDataCaptureMySQLExactWireLimitsAndDrift(t *testing.T) {
	s := integrationSession(t)
	run(t, s, "DROP TABLE IF EXISTS data_capture_fixture")
	defer run(t, s, "DROP TABLE IF EXISTS data_capture_fixture")
	run(t, s, "CREATE TABLE data_capture_fixture(id bigint unsigned PRIMARY KEY, amount decimal(65,30), approximate double,note text,bytes blob, hidden int INVISIBLE DEFAULT 7) ENGINE=InnoDB")
	run(t, s, "INSERT INTO data_capture_fixture(id,amount,approximate,note,bytes) VALUES(18446744073709551615,9007199254740993.123456789012345678901234567890,1.2345678901234567,'',X'00ff'),(2,1.00,0,NULL,NULL),(3,NULL,NULL,'NULL',X'')")
	ctx := context.Background()
	reader := integrationSession(t)
	if e := reader.SetReadOnly(ctx, true); e != nil {
		t.Fatal("read-only setup failed")
	}
	table := tc.Table{Schema: integrationSettings(t).Database, Name: "data_capture_fixture"}
	d, e := reader.DescribeTable(ctx, table)
	if e != nil {
		t.Fatalf("describe failed: %T", e)
	}
	columns := []string{}
	for _, c := range d.Columns {
		columns = append(columns, c.Name)
	}
	if len(columns) != 6 {
		t.Fatal("invisible column omitted")
	}
	for _, limit := range []int{2, 3, 4} {
		sink := &dataCaptureTestSink{}
		_, out, e := reader.CaptureTable(ctx, tc.Spec{Table: table, DescriptorDigest: d.Digest, Columns: columns, Keys: []string{"id"}, ReadLimit: limit}, sink)
		if e != nil {
			var wireFailure *dataCaptureWireFailure
			if errors.As(e, &wireFailure) {
				var server *wire.MyError
				if errors.As(e, &server) {
					t.Fatalf("capture stage=%s SQL error code=%d", wireFailure.stage, server.Code)
				}
				t.Fatalf("capture failed at static stage: %s", wireFailure.stage)
			}
			t.Fatalf("capture failed: %T invalid=%v changed=%v unsupported=%v", e, errors.Is(e, tc.ErrInvalid), errors.Is(e, tc.ErrChanged), errors.Is(e, tc.ErrUnsupported))
		}
		if len(sink.rows) != min(limit, 3) || len(out.PartialReasons) > 0 != (limit == 2) {
			t.Fatal("limit completeness incorrect")
		}
		if limit >= 3 {
			last := sink.rows[2]
			if *last[0] != "18446744073709551615" || *last[1] != "9007199254740993.123456789012345678901234567890" || *last[2] != "1.2345678901234567" || *last[3] != "" || *last[4] != "AP8=" {
				t.Fatal("exact wire values changed")
			}
		}
	}
	cancelReader := integrationSession(t)
	if e = cancelReader.SetReadOnly(ctx, true); e != nil {
		t.Fatal("cancellation read-only setup failed")
	}
	readCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	started := time.Now()
	_, _, e = cancelReader.CaptureTable(readCtx, tc.Spec{Table: table, DescriptorDigest: d.Digest, Columns: []string{"id"}, Keys: []string{"id"}, ReadLimit: 10}, &dataCaptureTestSink{cancel: cancel})
	if !errors.Is(e, context.Canceled) || time.Since(started) > 6*time.Second {
		t.Fatal("cancelled capture did not stop within its cleanup budget")
	}
	run(t, s, "ALTER TABLE data_capture_fixture ADD COLUMN drift text")
	if _, _, e = reader.CaptureTable(ctx, tc.Spec{Table: table, DescriptorDigest: d.Digest, Columns: []string{"id"}, Keys: []string{"id"}, ReadLimit: 10}, &dataCaptureTestSink{}); e != tc.ErrChanged {
		t.Fatal("metadata drift admitted")
	}
}
