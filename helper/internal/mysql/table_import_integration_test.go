package mysql

import (
	"context"
	"fmt"
	"io"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
)

func myImportText(value string) protocol.CellValue {
	return protocol.CellValue{Kind: "text", Value: &value}
}
func myImportBinary(value string) protocol.CellValue {
	return protocol.CellValue{Kind: "binary", Value: &value}
}
func myDescribeImport(t *testing.T, s *Session, table string) protocol.TableImportRequest {
	t.Helper()
	request := protocol.TableImportRequest{Schema: integrationSettings(t).Database, Table: table}
	reply := s.Execute(context.Background(), protocol.Command{Type: "import.describe", TableImport: &request})
	if reply.Type != "import.describe.result" || !reply.Connected || reply.TransactionStatus != "idle" || reply.TableImport == nil {
		t.Fatalf("describe import failed category=%s state=%s", reply.Category, reply.SQLState)
	}
	request.Fingerprint = reply.TableImport.Fingerprint
	return request
}

func TestMySQLTableImportKeylessPreviewDefaultsAndAtomicRows(t *testing.T) {
	s, observer := integrationSession(t), integrationSession(t)
	name := fmt.Sprintf("dbeer_import_%d", s.connectionID)
	table := QuoteIdentifier(name)
	run(t, observer, "CREATE TABLE "+table+" (id BIGINT NOT NULL DEFAULT 7,label VARCHAR(40) NOT NULL UNIQUE,amount DECIMAL(40,20),payload BLOB,note VARCHAR(40) NOT NULL DEFAULT 'fallback',computed VARCHAR(40) GENERATED ALWAYS AS (upper(label)) STORED) ENGINE=InnoDB")
	t.Cleanup(func() { run(t, observer, "DROP TABLE IF EXISTS "+table) })
	request := myDescribeImport(t, s, name)
	request.Columns = []string{"label", "amount", "payload"}
	request.Rows = [][]protocol.CellValue{{myImportText("NULL"), myImportText("12345678901234567890.12345678901234567890"), myImportBinary("AP+A")}, {myImportText(""), {Kind: "null"}, myImportBinary("")}}
	preview := s.Execute(context.Background(), protocol.Command{Type: "import.preview", TableImport: &request})
	if preview.Type != "import.preview.result" || preview.TableImport.RowCount == nil || *preview.TableImport.RowCount != 2 || strings.Contains(preview.TableImport.SQL, "123456789") || *run(t, observer, "SELECT count(*) FROM "+table).Rows[0][0] != "0" {
		t.Fatal("preview wrote rows or exposed values")
	}
	apply := s.Execute(context.Background(), protocol.Command{Type: "import.apply", TableImport: &request})
	if apply.Type != "import.apply.result" || apply.TableImport.RowCount == nil || *apply.TableImport.RowCount != 2 {
		t.Fatalf("keyless import failed category=%s state=%s", apply.Category, apply.SQLState)
	}
	row := run(t, observer, "SELECT amount,HEX(payload),note,id FROM "+table+" WHERE label='NULL'").Rows[0]
	if *row[0] != "12345678901234567890.12345678901234567890" || *row[1] != "00FF80" || *row[2] != "fallback" || *row[3] != "7" {
		t.Fatal("precise, binary or omitted-default value changed")
	}
	request.Rows = [][]protocol.CellValue{{myImportText("rollback"), {Kind: "null"}, {Kind: "null"}}, {myImportText("NULL"), {Kind: "null"}, {Kind: "null"}}}
	failed := s.Execute(context.Background(), protocol.Command{Type: "import.apply", TableImport: &request})
	if failed.Type != "error" || failed.OutcomeUnknown || failed.SQLNotExecuted || failed.TableImport == nil || *failed.TableImport.Row != 2 || *run(t, observer, "SELECT count(*) FROM "+table).Rows[0][0] != "2" {
		t.Fatal("row failure committed a partial import")
	}
	run(t, observer, "ALTER TABLE "+table+" ALTER COLUMN note SET DEFAULT 'changed'")
	stale := s.Execute(context.Background(), protocol.Command{Type: "import.preview", TableImport: &request})
	if stale.Type != "error" || stale.Category != "conflict" || !stale.SQLNotExecuted {
		t.Fatal("changed default bypassed fingerprint")
	}
}

func TestMySQLTableImportReadonlyPreviewCancellationAndUnknownCommit(t *testing.T) {
	s, observer := integrationSession(t), integrationSession(t)
	name := fmt.Sprintf("dbeer_import_lifecycle_%d", s.connectionID)
	table := QuoteIdentifier(name)
	run(t, observer, "CREATE TABLE "+table+" (label VARCHAR(40) NOT NULL) ENGINE=InnoDB")
	t.Cleanup(func() { run(t, observer, "DROP TABLE IF EXISTS "+table) })
	request := myDescribeImport(t, s, name)
	request.Columns = []string{"label"}
	request.Rows = [][]protocol.CellValue{{myImportText("one")}}
	if s.SetReadOnly(context.Background(), true) != nil {
		t.Fatal("readonly setup")
	}
	_ = myDescribeImport(t, s, name)
	if reply := s.Execute(context.Background(), protocol.Command{Type: "import.preview", TableImport: &request}); reply.Type != "import.preview.result" {
		t.Fatal("readonly preview required a write lock")
	}
	if s.SetReadOnly(context.Background(), false) != nil {
		t.Fatal("readonly teardown")
	}
	trigger := QuoteIdentifier(name + "_pause")
	run(t, observer, "CREATE TRIGGER "+trigger+" BEFORE INSERT ON "+table+" FOR EACH ROW SET NEW.label=IF(SLEEP(5)=0,NEW.label,NEW.label)")
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	failed := s.Execute(ctx, protocol.Command{Type: "import.apply", TableImport: &request})
	if failed.Type != "error" || failed.Category != "timeout" || failed.OutcomeUnknown || !failed.Connected || failed.SQLNotExecuted || *run(t, observer, "SELECT count(*) FROM "+table).Rows[0][0] != "0" {
		t.Fatal("cancelled import did not roll back")
	}
	run(t, observer, "DROP TRIGGER "+trigger)
	s.commitOverride = func(commit func() error) error {
		if err := commit(); err != nil {
			return err
		}
		return io.ErrUnexpectedEOF
	}
	unknown := s.Execute(context.Background(), protocol.Command{Type: "import.apply", TableImport: &request})
	if unknown.Type != "error" || !unknown.OutcomeUnknown || unknown.Connected || *run(t, observer, "SELECT count(*) FROM "+table).Rows[0][0] != "1" {
		t.Fatal("lost commit acknowledgement was retried or claimed rolled back")
	}
}

func TestMySQLTableImportBatchExceedsResultGridDisplayLimit(t *testing.T) {
	s, observer := integrationSession(t), integrationSession(t)
	name := fmt.Sprintf("dbeer_import_many_%d", s.connectionID)
	table := QuoteIdentifier(name)
	run(t, observer, "CREATE TABLE "+table+" (label VARCHAR(40) NOT NULL) ENGINE=InnoDB")
	t.Cleanup(func() { run(t, observer, "DROP TABLE IF EXISTS "+table) })
	request := myDescribeImport(t, s, name)
	request.Columns = []string{"label"}
	request.Rows = make([][]protocol.CellValue, 1001)
	for i := range request.Rows {
		request.Rows[i] = []protocol.CellValue{myImportText("row")}
	}
	response := s.Execute(context.Background(), protocol.Command{Type: "import.apply", TableImport: &request})
	if response.Type != "import.apply.result" || response.TableImport.RowCount == nil || *response.TableImport.RowCount != 1001 || *run(t, observer, "SELECT count(*) FROM "+table).Rows[0][0] != "1001" {
		t.Fatal("import incorrectly inherited the result-grid row limit")
	}
}
