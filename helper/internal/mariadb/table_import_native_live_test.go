package mariadb

import (
	"context"
	"encoding/base64"
	"fmt"
	"strings"
	"testing"
	"time"

	"dbeer/helper/internal/protocol"
	"github.com/go-mysql-org/go-mysql/packet"
)

func importCommand(s *Session, kind string, request *protocol.TableImportRequest) protocol.Response {
	return s.executeTableImport(context.Background(), protocol.Command{Type: kind, RequestID: "import", SessionID: "owner", TableImport: request})
}

func TestMariaDBImportNativeLiveDefaultPreviewAndCommitLoss(t *testing.T) {
	s, observer := dataIntegrationSession(t), dataIntegrationSession(t)
	sequence := QuoteIdentifier(dataIntegrationSettings(t).Database) + "." + QuoteIdentifier(fmt.Sprintf("g1_import_sequence_%d", time.Now().UnixNano()))
	dataRun(t, observer, "CREATE SEQUENCE "+sequence+" START WITH 100 CACHE 1")
	t.Cleanup(func() { dataRun(t, observer, "DROP SEQUENCE "+sequence) })
	name, qualified := rowFixture(t, observer, "(id INT PRIMARY KEY,n BIGINT DEFAULT (NEXT VALUE FOR "+sequence+")) ENGINE=InnoDB")
	request := protocol.TableImportRequest{Schema: dataIntegrationSettings(t).Database, Table: name}
	description := importCommand(s, "import.describe", &request)
	if description.TableImport == nil {
		t.Fatal("native sequence-default table could not be described")
	}
	request.Fingerprint = description.TableImport.Fingerprint
	request.Columns = []string{"id"}
	request.Rows = [][]protocol.CellValue{{rowCell("1")}, {rowCell("2")}}
	before := *dataRun(t, observer, "SELECT next_not_cached_value FROM "+sequence).Rows[0][0]
	preview := importCommand(s, "import.preview", &request)
	if preview.Type != "import.preview.result" || *dataRun(t, observer, "SELECT next_not_cached_value FROM "+sequence).Rows[0][0] != before {
		t.Fatal("native import Preview evaluated an authored default expression")
	}
	tap := &rowNativePacketTap{Conn: s.work.client.Conn.Conn, loseCommit: true}
	s.work.client.Conn = packet.NewConn(tap)
	r := importCommand(s, "import.apply", &request)
	if r.Type != "error" || !r.OutcomeUnknown || r.Connected || tap.commits.Load() != 1 {
		t.Fatal("lost native import COMMIT acknowledgement was replayed or claimed complete")
	}
	actual := dataRun(t, observer, "SELECT n FROM "+qualified+" ORDER BY id")
	if len(actual.Rows) != 2 || *actual.Rows[0][0] != "100" || *actual.Rows[1][0] != "101" || *dataRun(t, observer, "SELECT next_not_cached_value FROM "+sequence).Rows[0][0] != "102" {
		t.Fatal("actual committed import did not evaluate each reviewed default exactly once")
	}
}

func TestMariaDBImportNativeLiveCancellationRollsBackEarlierRows(t *testing.T) {
	s, observer := dataIntegrationSession(t), dataIntegrationSession(t)
	name, qualified := rowFixture(t, observer, "(id INT PRIMARY KEY,n INT NOT NULL) ENGINE=InnoDB")
	trigger := QuoteIdentifier(dataIntegrationSettings(t).Database) + "." + QuoteIdentifier(fmt.Sprintf("g1_import_trigger_%d", time.Now().UnixNano()))
	dataRun(t, observer, "CREATE TRIGGER "+trigger+" BEFORE INSERT ON "+qualified+" FOR EACH ROW SET NEW.n=IF(NEW.id=2,SLEEP(10),NEW.n)")
	request := protocol.TableImportRequest{Schema: dataIntegrationSettings(t).Database, Table: name}
	description := importCommand(s, "import.describe", &request)
	if description.TableImport == nil {
		t.Fatal("native cancellation import metadata unavailable")
	}
	request.Fingerprint = description.TableImport.Fingerprint
	request.Columns = []string{"id", "n"}
	request.Rows = [][]protocol.CellValue{{rowCell("1"), rowCell("1")}, {rowCell("2"), rowCell("2")}}
	before := rowState(t, s)
	tap := &rowNativePacketTap{Conn: s.work.client.Conn.Conn, lockStarted: make(chan struct{}), watchSQL: " FOR INSERT INTO ", watchCount: 2}
	s.work.client.Conn = packet.NewConn(tap)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan protocol.Response, 1)
	go func() {
		done <- s.executeTableImport(ctx, protocol.Command{Type: "import.apply", TableImport: &request})
	}()
	select {
	case <-tap.lockStarted:
	case <-time.After(4 * time.Second):
		t.Fatal("native second import row did not dispatch")
	}
	cancel()
	select {
	case r := <-done:
		if r.Type != "error" || r.Category != "cancelled" || r.OutcomeUnknown || !r.Connected || r.TableImport == nil || r.TableImport.Row == nil || *r.TableImport.Row != 2 {
			t.Fatal("native import cancellation lost its acknowledged batch rollback or row boundary")
		}
	case <-time.After(8 * time.Second):
		t.Fatal("native import cancellation did not finish")
	}
	if *dataRun(t, observer, "SELECT COUNT(*) FROM "+qualified).Rows[0][0] != "0" || rowState(t, s) != before || s.TransactionStatus() != "idle" {
		t.Fatal("cancelled import retained an earlier inserted row or changed session state")
	}
	dataRun(t, s, "SELECT SLEEP(0.02)")
}

func TestMariaDBImportNativeLivePreviewExactRowsAndRollback(t *testing.T) {
	s := dataIntegrationSession(t)
	name, qualified := rowFixture(t, s, "(id BIGINT PRIMARY KEY,amount DECIMAL(65,38),payload LONGTEXT,j JSON,b VARBINARY(16),g BIGINT AS(id*2) PERSISTENT,n INT DEFAULT 7) ENGINE=InnoDB")
	dataRun(t, s, "SET SESSION sql_mode='',time_zone='Europe/Berlin'")
	before := rowState(t, s)
	request := protocol.TableImportRequest{Schema: dataIntegrationSettings(t).Database, Table: name}
	description := importCommand(s, "import.describe", &request)
	if description.Type != "import.describe.result" || description.TableImport == nil || len(description.TableImport.Columns) != 7 || !description.TableImport.Columns[5].Generated {
		t.Fatal("native import describe lost complete ordered metadata")
	}
	request.Fingerprint = description.TableImport.Fingerprint
	request.Columns = []string{"id", "amount", "payload", "j", "b"}
	binary := base64.StdEncoding.EncodeToString([]byte{0, 255})
	request.Rows = [][]protocol.CellValue{{rowCell("1"), rowCell("0.12345678901234567890123456789012345678"), rowCell("NULL"), rowCell("{\"a\":1, \"a\":2}"), {Kind: "binary", Value: &binary}}, {rowCell("2"), {Kind: "null"}, rowCell(""), {Kind: "null"}, {Kind: "binary", Value: text("")}}}
	preview := importCommand(s, "import.preview", &request)
	if preview.Type != "import.preview.result" || preview.TableImport == nil || preview.TableImport.RowCount == nil || *preview.TableImport.RowCount != 2 || !strings.HasPrefix(preview.TableImport.SQL, "SET STATEMENT sql_mode='") {
		t.Fatal("native import preview did not bind rows or disclose strict statement scope")
	}
	if *dataRun(t, s, "SELECT COUNT(*) FROM "+qualified).Rows[0][0] != "0" || rowState(t, s) != before {
		t.Fatal("native import Preview read default expressions or changed session state")
	}
	if r := importCommand(s, "import.apply", &request); r.Type != "import.apply.result" || r.TableImport == nil || *r.TableImport.RowCount != 2 || rowState(t, s) != before {
		t.Fatalf("native import apply failed: %s/%s", r.Category, r.SQLState)
	}
	actual := dataRun(t, s, "SELECT amount,payload,j,HEX(b),g,n FROM "+qualified+" ORDER BY id")
	if *actual.Rows[0][0] != "0.12345678901234567890123456789012345678" || *actual.Rows[0][1] != "NULL" || *actual.Rows[0][2] != "{\"a\":1, \"a\":2}" || *actual.Rows[0][3] != "00FF" || *actual.Rows[0][4] != "2" || *actual.Rows[0][5] != "7" || actual.Rows[1][0] != nil || *actual.Rows[1][1] != "" || actual.Rows[1][2] != nil || *actual.Rows[1][3] != "" {
		t.Fatal("native import changed exact numeric/JSON/NULL/empty/binary/default/generated values")
	}
	request.Rows = [][]protocol.CellValue{{rowCell("3"), {Kind: "null"}, rowCell("third"), {Kind: "null"}, {Kind: "binary", Value: text("")}}, {rowCell("1"), {Kind: "null"}, rowCell("duplicate"), {Kind: "null"}, {Kind: "binary", Value: text("")}}}
	failure := importCommand(s, "import.apply", &request)
	if failure.Type != "error" || failure.OutcomeUnknown || failure.TableImport == nil || failure.TableImport.Row == nil || *failure.TableImport.Row != 2 || *dataRun(t, s, "SELECT COUNT(*) FROM "+qualified).Rows[0][0] != "2" || rowState(t, s) != before {
		t.Fatal("native import late-row failure did not roll back the entire batch")
	}
	dataRun(t, s, "ALTER TABLE "+qualified+" ADD COLUMN late INT")
	if r := importCommand(s, "import.preview", &request); r.Category != "conflict" {
		t.Fatal("native stale import mapping remained authorized")
	}
}
