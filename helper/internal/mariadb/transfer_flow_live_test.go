package mariadb

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	dt "dbeer/helper/internal/datatransfer"
	"dbeer/helper/internal/protocol"
	"dbeer/helper/internal/syncplan"
	tc "dbeer/helper/internal/tablecapture"
	"github.com/go-mysql-org/go-mysql/packet"
)

type flowRows struct {
	rows  [][]*string
	onRow func() error
}

func (s *flowRows) Row(row []*string) error {
	s.rows = append(s.rows, row)
	if s.onRow != nil {
		return s.onRow()
	}
	return nil
}
func flowSpec(d tc.Descriptor, limit int) tc.Spec {
	names := []string{}
	for _, c := range d.Columns {
		names = append(names, c.Name)
	}
	return tc.Spec{Table: d.Table, DescriptorDigest: d.Digest, Columns: names, Keys: []string{names[0]}, ReadLimit: limit}
}
func flowRead(rows [][]protocol.CellValue) dt.RowReader {
	i := 0
	return func() ([]protocol.CellValue, error) {
		if i == len(rows) {
			return nil, io.EOF
		}
		r := rows[i]
		i++
		return r, nil
	}
}
func TestMariaDBFlowNativeCaptureExactLimitsStorageAndOwner(t *testing.T) {
	owner, reader := dataIntegrationSession(t), dataIntegrationSession(t)
	name, q := rowFixture(t, owner, "(id BIGINT UNSIGNED PRIMARY KEY,n DECIMAL(65,38),j LONGTEXT,b BLOB,f FLOAT(20,4),d DOUBLE(20,4),stamp TIMESTAMP(6) NULL,e ENUM('','a'),s SET('','a'),hidden INT INVISIBLE DEFAULT 7) ENGINE=InnoDB")
	exact := "9007199254740993.12345678901234567890123456789012345678"
	dataRun(t, owner, "SET STATEMENT sql_mode='' FOR INSERT INTO "+q+"(id,n,j,b,f,d,stamp,e,s) VALUES(18446744073709551615,"+exact+",'{ \"k\":1,\"k\":2 }',x'00ff',1.2345,2.3456,'2024-01-02 03:04:05.123456',1,1),(2,NULL,'',x'',NULL,NULL,NULL,0,0),(3,1,'NULL',NULL,1,1,'0000-00-00 00:00:00',2,2)")
	dataRun(t, reader, "SET SESSION time_zone='+03:00'")
	before := rowState(t, reader)
	if e := reader.SetReadOnly(context.Background(), true); e != nil {
		t.Fatal("readonly source setup failed")
	}
	d, e := reader.DescribeTable(context.Background(), tc.Table{Schema: dataIntegrationSettings(t).Database, Name: name})
	if e != nil || len(d.Columns) != 10 {
		t.Fatalf("native capture describe failed: %T", e)
	}
	for _, limit := range []int{2, 3, 4} {
		sink := &flowRows{}
		_, out, e := reader.CaptureTable(context.Background(), flowSpec(d, limit), sink)
		if e != nil || len(sink.rows) != min(limit, 3) || (len(out.PartialReasons) > 0) != (limit == 2) {
			t.Fatalf("native capture exact/limit failed: %T", e)
		}
		if limit >= 3 {
			last := sink.rows[2]
			if *last[0] != "18446744073709551615" || *last[1] != exact || *last[2] != "{ \"k\":1,\"k\":2 }" || *last[3] != "AP8=" || *last[6] != "2024-01-02 03:04:05.123456" || *last[9] != "7" {
				t.Fatal("capture changed numeric/JSON/binary/UTC/invisible values")
			}
			var choice []any
			if json.Unmarshal([]byte(*last[7]), &choice) != nil || len(choice) != 2 {
				t.Fatal("enum ordinal/label pair missing")
			}
			if *sink.rows[0][7] == *last[7] || *sink.rows[0][8] == *last[8] {
				t.Fatal("empty ENUM/SET storage state was collapsed")
			}
		}
	}
	if reader.connectionID == owner.connectionID || reader.TransactionStatus() != "idle" || rowState(t, reader) != before {
		t.Fatal("capture changed owning session context")
	}
	dataRun(t, owner, "ALTER TABLE "+q+" ADD COLUMN drift INT")
	if _, _, e = reader.CaptureTable(context.Background(), flowSpec(d, 10), &flowRows{}); !errors.Is(e, tc.ErrChanged) {
		t.Fatal("stale descriptor admitted")
	}
}
func TestMariaDBFlowNativeCaptureCancellationAndTxnGuard(t *testing.T) {
	owner, reader := dataIntegrationSession(t), dataIntegrationSession(t)
	name, q := rowFixture(t, owner, "(id INT PRIMARY KEY,v TEXT) ENGINE=InnoDB")
	dataRun(t, owner, "INSERT INTO "+q+" VALUES(1,'a'),(2,'b')")
	d, e := reader.DescribeTable(context.Background(), tc.Table{Schema: dataIntegrationSettings(t).Database, Name: name})
	if e != nil {
		t.Fatal("capture fixture describe failed")
	}
	dataRun(t, reader, "BEGIN")
	if _, e = reader.DescribeTable(context.Background(), d.Table); e == nil || reader.TransactionStatus() != "transaction" {
		t.Fatal("active owner transaction changed")
	}
	dataRun(t, reader, "ROLLBACK")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	started := time.Now()
	_, _, e = reader.CaptureTable(ctx, flowSpec(d, 10), &flowRows{onRow: func() error { cancel(); return context.Canceled }})
	if !errors.Is(e, context.Canceled) || time.Since(started) > RecoveryTimeout+time.Second || !reader.closed.Load() {
		t.Fatal("undrained capture was reused or cancellation exceeded cleanup budget")
	}
}
func TestMariaDBFlowNativeSynchronizationExactRows(t *testing.T) {
	s := dataIntegrationSession(t)
	name, q := rowFixture(t, s, "(id INT PRIMARY KEY,n DECIMAL(65,38),v LONGTEXT,b BLOB) ENGINE=InnoDB")
	dataRun(t, s, "INSERT INTO "+q+" VALUES(1,1,'',x'00ff')")
	d, e := s.DescribeTable(context.Background(), tc.Table{Schema: dataIntegrationSettings(t).Database, Name: name})
	if e != nil {
		t.Fatal("sync native descriptor failed")
	}
	sink := &flowRows{}
	if _, _, e = s.CaptureTable(context.Background(), flowSpec(d, 10), sink); e != nil {
		t.Fatal("sync native originals failed")
	}
	source := append([]*string(nil), sink.rows[0]...)
	exact := "9007199254740993.12345678901234567890123456789012345678"
	source[1] = &exact
	text := "{ \"a\":1,\"a\":2 }"
	source[2] = &text
	source[3] = nil
	op := syncplan.DataOperation{Kind: "update", Descriptor: d, Source: source, Target: sink.rows[0], Mappings: []syncplan.DataMapping{{SourceIndex: 0, TargetIndex: 0, Key: true}, {SourceIndex: 1, TargetIndex: 1}, {SourceIndex: 2, TargetIndex: 2}, {SourceIndex: 3, TargetIndex: 3}}}
	sql, e := RenderDataSynchronization(op)
	if e != nil {
		t.Fatalf("sync render failed: %T", e)
	}
	dataRun(t, s, sql)
	r := dataRun(t, s, "SELECT CAST(n AS CHAR),v,b FROM "+q)
	if *r.Rows[0][0] != exact || *r.Rows[0][1] != text || r.Rows[0][2] != nil {
		t.Fatal("native sync changed exact values")
	}
	dataRun(t, s, "UPDATE "+q+" SET v='external'")
	dataRun(t, s, sql)
	if *dataRun(t, s, "SELECT v FROM "+q).Rows[0][0] != "external" {
		t.Fatal("stale original sync guard updated changed row")
	}
}
func TestMariaDBFlowNativeTransferExactCommitRollbackAndUnknown(t *testing.T) {
	target, observer := dataIntegrationSession(t), dataIntegrationSession(t)
	schema := dataIntegrationSettings(t).Database
	cols := []protocol.TransferColumn{{Name: "id", Type: "integer"}, {SourceIndex: 1, Name: "n", Type: "decimal", Precision: 65, Scale: 38}, {SourceIndex: 2, Name: "j", Type: "json", Nullable: true}, {SourceIndex: 3, Name: "b", Type: "binary", Nullable: true}}
	exact := "9007199254740993.12345678901234567890123456789012345678"
	j := "{ \"a\":1,\"a\":2 }"
	b := "AP8="
	rows := [][]protocol.CellValue{{rowCell("1"), rowCell(exact), rowCell(j), {Kind: "binary", Value: &b}}, {rowCell("2"), rowCell("1"), {Kind: "null"}, {Kind: "null"}}}
	for _, mode := range []string{"commit", "rollback", "unknown"} {
		t.Run(mode, func(t *testing.T) {
			s := target
			if mode != "commit" {
				s = dataIntegrationSession(t)
			}
			name := fmt.Sprintf("g1_flow_%s_%d", mode, time.Now().UnixNano())
			q := QuoteIdentifier(schema) + "." + QuoteIdentifier(name)
			t.Cleanup(func() { dataRun(t, observer, "DROP TABLE IF EXISTS "+q) })
			sql, identity, e := s.TransferPreview(context.Background(), schema, name, cols)
			if e != nil || !strings.Contains(sql, "DECIMAL(65,38)") {
				t.Fatal("typed native transfer preview failed")
			}
			input := rows
			if mode == "rollback" {
				input = append([][]protocol.CellValue(nil), rows...)
				input[1] = append([]protocol.CellValue(nil), rows[1]...)
				input[1][0] = rowCell("bad")
			}
			var tap *flowNativeCommitTap
			if mode == "unknown" {
				tap = &flowNativeCommitTap{Conn: s.work.client.Conn.Conn, loseCommit: true}
				s.work.client.Conn = packet.NewConn(tap)
			}
			out, e := s.TransferApply(context.Background(), schema, name, identity, cols, flowRead(input), nil)
			if mode == "commit" {
				if e != nil || !out.TableCreated || out.Rows != 2 || out.OutcomeUnknown {
					t.Fatalf("native transfer commit failed: %T", e)
				}
				r := dataRun(t, observer, "SELECT CAST(n AS CHAR),j,HEX(b) FROM "+q+" WHERE id=1")
				if *r.Rows[0][0] != exact || *r.Rows[0][1] != j || *r.Rows[0][2] != "00FF" {
					t.Fatal("transfer lost exact native values")
				}
				if _, _, e = s.TransferPreview(context.Background(), schema, name, cols); !errors.Is(e, dt.ErrExists) {
					t.Fatal("existing target overwrite admitted")
				}
			}
			if mode == "rollback" {
				if e == nil || !out.TableCreated || out.OutcomeUnknown || out.Rows != 0 {
					t.Fatal("known transfer failure outcome incorrect")
				}
				if *dataRun(t, observer, "SELECT COUNT(*) FROM "+q).Rows[0][0] != "0" {
					t.Fatal("failed transfer committed earlier rows")
				}
			}
			if mode == "unknown" {
				if e == nil || !out.OutcomeUnknown || !out.TableCreated || out.Rows != 2 || !s.closed.Load() || tap.commits.Load() != 1 {
					t.Fatal("actual lost transfer COMMIT ACK was retried or claimed known")
				}
				if *dataRun(t, observer, "SELECT COUNT(*) FROM "+q).Rows[0][0] != "2" {
					t.Fatal("unknown committed native rows not reached")
				}
			}
		})
	}
}
func TestMariaDBFlowNativeTransferCaptureStorageAndHistoryNotice(t *testing.T) {
	owner, source := dataIntegrationSession(t), dataIntegrationSession(t)
	name, q := rowFixture(t, owner, "(id BIGINT UNSIGNED PRIMARY KEY,j LONGTEXT,b BLOB,stamp TIMESTAMP(6),e ENUM('','a')) ENGINE=InnoDB WITH SYSTEM VERSIONING")
	dataRun(t, owner, "INSERT INTO "+q+" VALUES(18446744073709551615,'{ \"k\":1,\"k\":2 }',x'00ff','2024-01-02 03:04:05.123456',1)")
	dataRun(t, owner, "UPDATE "+q+" SET j='{ \"k\":2,\"k\":3 }'")
	before := rowState(t, source)
	d, e := source.TransferDescribe(context.Background(), dataIntegrationSettings(t).Database, name)
	if e != nil || !strings.Contains(strings.Join(d.Notices, " "), "history") {
		t.Fatalf("system history source scope not explicit: %T", e)
	}
	rows := [][]protocol.CellValue{}
	_, e = source.TransferCapture(context.Background(), dataIntegrationSettings(t).Database, name, d.Digest, func(row []protocol.CellValue) error { rows = append(rows, row); return nil })
	if e != nil || len(rows) != 1 || *rows[0][0].Value != "18446744073709551615" || *rows[0][1].Value != "{ \"k\":2,\"k\":3 }" || *rows[0][2].Value != "AP8=" || *rows[0][3].Value != "2024-01-02T03:04:05.123456Z" || !reflect.DeepEqual(rowState(t, source), before) {
		t.Fatalf("current native source values/scope changed: %T", e)
	}
}

func TestMariaDBFlowNativeTransferReadonlyReviewAndCancellation(t *testing.T) {
	preview, target, observer := dataIntegrationSession(t), dataIntegrationSession(t), dataIntegrationSession(t)
	schema := dataIntegrationSettings(t).Database
	columns := []protocol.TransferColumn{{Name: "v", Type: "text", Nullable: true}}
	if e := preview.SetReadOnly(context.Background(), true); e != nil {
		t.Fatal("readonly preview owner failed")
	}
	for _, cancelled := range []bool{false, true} {
		name := fmt.Sprintf("g1_flow_owner_%d", time.Now().UnixNano())
		q := QuoteIdentifier(schema) + "." + QuoteIdentifier(name)
		t.Cleanup(func() { dataRun(t, observer, "DROP TABLE IF EXISTS "+q) })
		_, identity, e := preview.TransferPreview(context.Background(), schema, name, columns)
		if e != nil {
			t.Fatal("readonly review failed")
		}
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		i := 0
		read := func() ([]protocol.CellValue, error) {
			i++
			if i == 1 {
				return []protocol.CellValue{rowCell("")}, nil
			}
			if cancelled {
				cancel()
				return []protocol.CellValue{rowCell("NULL")}, nil
			}
			if i == 2 {
				return []protocol.CellValue{{Kind: "null"}}, nil
			}
			if i == 3 {
				return []protocol.CellValue{rowCell("NULL")}, nil
			}
			return nil, io.EOF
		}
		before := rowState(t, target)
		out, e := target.TransferApply(ctx, schema, name, identity, columns, read, nil)
		if cancelled {
			if !errors.Is(e, context.Canceled) || !out.TableCreated || out.OutcomeUnknown || *dataRun(t, observer, "SELECT COUNT(*) FROM "+q).Rows[0][0] != "0" {
				t.Fatal("cancelled transfer committed earlier rows or misreported known empty table")
			}
		}
		if !cancelled {
			if e != nil || out.Rows != 3 || out.OutcomeUnknown {
				t.Fatalf("readonly review did not authorize independent writable owner: %T", e)
			}
			rows := dataRun(t, observer, "SELECT v FROM "+q).Rows
			if len(rows) != 3 || rows[0][0] == nil || *rows[0][0] != "" || rows[1][0] != nil || rows[2][0] == nil || *rows[2][0] != "NULL" {
				t.Fatal("transfer confused SQL NULL/empty/text NULL")
			}
		}
		if target.closed.Load() || target.TransactionStatus() != "idle" || rowState(t, target) != before {
			t.Fatal("transfer failed to restore exact writable-owner context")
		}
	}
	dataRun(t, target, "SET SESSION sql_mode=CONCAT_WS(',',@@sql_mode,'EMPTY_STRING_IS_NULL')")
	name := fmt.Sprintf("g1_flow_mode_%d", time.Now().UnixNano())
	if _, _, e := target.TransferPreview(context.Background(), schema, name, columns); e == nil {
		t.Fatal("coercing empty-parameter mode authorized transfer")
	}
	if target.closed.Load() {
		t.Fatal("local mode refusal closed owning session")
	}
}

func TestMariaDBFlowNativeNontransactionalCaptureIsExplicit(t *testing.T) {
	for _, engine := range []string{"MyISAM", "Aria"} {
		t.Run(engine, func(t *testing.T) {
			s := dataIntegrationSession(t)
			name, q := rowFixture(t, s, "(id INT PRIMARY KEY,v VARCHAR(8)) ENGINE="+engine)
			dataRun(t, s, "INSERT INTO "+q+" VALUES(1,'value')")
			table := tc.Table{Schema: dataIntegrationSettings(t).Database, Name: name}
			d, e := s.DescribeTable(context.Background(), table)
			if e != nil {
				t.Fatal("native nontransactional source describe failed")
			}
			sink := &flowRows{}
			_, out, e := s.CaptureTable(context.Background(), flowSpec(d, 10), sink)
			if e != nil || out.Consistency != "bestEffortNontransactionalMetadataAndRows" || len(sink.rows) != 1 || *sink.rows[0][1] != "value" {
				t.Fatal("native nontransactional capture falsely claimed snapshot isolation")
			}
			description, e := s.TransferDescribe(context.Background(), table.Schema, table.Name)
			if e != nil || !strings.Contains(strings.Join(description.Notices, " "), engine+" source is nontransactional") {
				t.Fatal("review lost nontransactional source notice")
			}
		})
	}
}
func TestMariaDBFlowNativeScalarAndInternalBinaryCapture(t *testing.T) {
	s := dataIntegrationSession(t)
	name, q := rowFixture(t, s, "(id INT PRIMARY KEY,u UUID,i4 INET4,i6 INET6,g POINT,e ENUM(x'ff',x'00') CHARACTER SET binary) ENGINE=InnoDB")
	dataRun(t, s, "INSERT INTO "+q+" VALUES(1,'12345678-1234-1234-1234-123456789abc','192.0.2.9','2001:db8::9',ST_GeomFromText('POINT(1 2)',4326),x'ff')")
	original := dataRun(t, s, "SELECT HEX(g),HEX(e) FROM "+q).Rows[0]
	description, e := s.TransferDescribe(context.Background(), dataIntegrationSettings(t).Database, name)
	if e != nil {
		t.Fatalf("native scalar/binary source describe failed: %T", e)
	}
	rows := [][]protocol.CellValue{}
	_, e = s.TransferCapture(context.Background(), dataIntegrationSettings(t).Database, name, description.Digest, func(row []protocol.CellValue) error { rows = append(rows, row); return nil })
	if e != nil || len(rows) != 1 || *rows[0][1].Value != "12345678-1234-1234-1234-123456789abc" || *rows[0][2].Value != "192.0.2.9" || *rows[0][3].Value != "2001:db8::9" {
		t.Fatalf("native UUID/INET string identity changed: %T", e)
	}
	for i, column := range []int{4, 5} {
		b, e := base64.StdEncoding.DecodeString(*rows[0][column].Value)
		if e != nil || strings.ToUpper(hex.EncodeToString(b)) != *original[i] {
			t.Fatal("native SRID-prefixed geometry or binary ENUM bytes changed")
		}
	}
	if !strings.Contains(strings.Join(description.Notices, " "), "not WKB") {
		t.Fatal("internal geometry storage was mislabeled portable WKB")
	}
}

// Lose only the actual fixed COMMIT response after it has reached the server.
type flowNativeCommitTap struct {
	net.Conn
	loseCommit bool
	armed      atomic.Bool
	commits    atomic.Int32
}

func (t *flowNativeCommitTap) Write(p []byte) (int, error) {
	if len(p) >= 5 && p[3] == 0 && p[4] == 3 && string(p[5:]) == "COMMIT AND NO CHAIN NO RELEASE" {
		t.commits.Add(1)
		t.armed.Store(t.loseCommit)
	}
	return t.Conn.Write(p)
}
func (t *flowNativeCommitTap) Read(p []byte) (int, error) {
	n, e := t.Conn.Read(p)
	if n > 0 && t.armed.Swap(false) {
		t.Conn.Close()
		return 0, io.ErrUnexpectedEOF
	}
	return n, e
}
func TestMariaDBFlowNativeCompletionModePreserved(t *testing.T) {
	for _, mode := range []string{"1", "2"} {
		t.Run(mode, func(t *testing.T) {
			s := dataIntegrationSession(t)
			name, q := rowFixture(t, s, "(id INT PRIMARY KEY) ENGINE=InnoDB")
			dataRun(t, s, "INSERT INTO "+q+" VALUES(1)")
			dataRun(t, s, "SET SESSION completion_type="+mode)
			completion := *dataRun(t, s, "SELECT @@SESSION.completion_type").Rows[0][0]
			d, e := s.DescribeTable(context.Background(), tc.Table{Schema: dataIntegrationSettings(t).Database, Name: name})
			if e != nil {
				t.Fatal("completion mode source describe failed")
			}
			if _, _, e = s.CaptureTable(context.Background(), flowSpec(d, 10), &flowRows{}); e != nil || s.closed.Load() || s.TransactionStatus() != "idle" {
				t.Fatal("capture chained or released its owner")
			}
			target := fmt.Sprintf("g1_flow_completion_%d", time.Now().UnixNano())
			t.Cleanup(func() { dataRun(t, s, "DROP TABLE IF EXISTS "+QuoteIdentifier(target)) })
			columns := []protocol.TransferColumn{{Name: "id", Type: "integer"}}
			_, identity, e := s.TransferPreview(context.Background(), dataIntegrationSettings(t).Database, target, columns)
			if e != nil {
				t.Fatal("completion mode preview failed")
			}
			out, e := s.TransferApply(context.Background(), dataIntegrationSettings(t).Database, target, identity, columns, flowRead([][]protocol.CellValue{{rowCell("1")}}), nil)
			if e != nil || out.Rows != 1 || s.closed.Load() || s.TransactionStatus() != "idle" || *dataRun(t, s, "SELECT @@SESSION.completion_type").Rows[0][0] != completion {
				t.Fatal("transfer chained/released or changed its owner's native completion mode")
			}
		})
	}
}

func TestMariaDBFlowNativeTransferZeroTimestampRemainsText(t *testing.T) {
	s := dataIntegrationSession(t)
	name, q := rowFixture(t, s, "(id INT PRIMARY KEY,stamp TIMESTAMP(6) NULL) ENGINE=InnoDB")
	dataRun(t, s, "SET STATEMENT sql_mode='' FOR INSERT INTO "+q+" VALUES(1,'0000-00-00 00:00:00'),(2,NULL)")
	expected := dataRun(t, s, "SELECT CAST(stamp AS CHAR) FROM "+q+" WHERE id=1").Rows[0][0]
	d, e := s.TransferDescribe(context.Background(), dataIntegrationSettings(t).Database, name)
	if e != nil {
		t.Fatal("zero timestamp describe failed")
	}
	rows := [][]protocol.CellValue{}
	_, e = s.TransferCapture(context.Background(), dataIntegrationSettings(t).Database, name, d.Digest, func(row []protocol.CellValue) error { rows = append(rows, row); return nil })
	if e != nil || len(rows) != 2 || rows[0][1].Value == nil || *rows[0][1].Value != *expected || rows[1][1].Kind != "null" {
		t.Fatal("zero timestamp was confused with NULL or silently coerced")
	}
	text := protocol.TransferColumn{Name: "stamp", Type: "text", Nullable: true}
	if _, e := dt.Normalize(rows[0][1], text, "mariadb"); e != nil {
		t.Fatal("exact zero temporal text could not be preserved as TEXT")
	}
	if _, e := dt.Normalize(rows[0][1], d.Columns[1], "mariadb"); e == nil {
		t.Fatal("invalid zero instant gained temporal target authority")
	}
}
